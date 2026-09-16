import Foundation

// MARK: - ShellPipelineActions (Task 13)
// Thin adapters from the shell (Toolbar/Foldouts/Dialogs/Banners) to the
// Task-11 pipeline (`GitStore` + `AppStore+GitPipeline`). Views never call
// git directly — they call these helpers, which refresh through the pipeline
// so `RepositoryState` stays the single source of truth.
//
// Branch CRUD has no `GitService` requirement (parallel tasks code against
// the Task-1 contract), so it runs the static `BranchOperations`/`GitProcess`
// calls on the MainActor and then `refreshRepository` (the `GitStore` actor
// serialisation is bypassed here because those statics are MainActor-isolated
// under `-default-isolation=MainActor` and cannot run inside the actor's
// `@Sendable` work closure in Swift 6; the UI disables during ops so
// concurrent writes cannot interleave). Tag/worktree ops use the `GitService`
// methods via `performPipelineMutation` so `MockGitService` previews keep
// working. Sync ops go through `SyncOperations` with `performSyncOperation`
// error mapping so auth/push-needs-pull surface the right sheet.

@MainActor
public func repositoryForID(_ id: Int, in store: AppStore) -> Repository? {
    store.repositories.first { $0.id == id }
}

@MainActor
public func stateForRepositoryID(_ id: Int, in store: AppStore) -> RepositoryState? {
    guard let repo = repositoryForID(id, in: store) else { return nil }
    return store.repositoryStates[repo.hash]
}

/// Canonicalize a repository path for identity compares. Git reports
/// symlink-resolved paths (e.g. `/private/var/…` for a `/tmp/…` entry) while
/// stored repository paths keep the user's original spelling; plain string
/// compares would then miss and add duplicate entries (Task 16).
public func canonicalRepoPath(_ path: String) -> String {
    (path as NSString).resolvingSymlinksInPath
}

/// Bespoke popup for branch-checkout failures caused by dirty working-tree
/// conflicts. Nil for every other error — callers fall back to
/// `routeRefreshFailure` (Missing routing + generic `.error`) there.
public func checkoutConflictPopup(error: Error, repositoryID: Int) -> Popup? {
    guard let gitError = error as? GitError else { return nil }
    switch gitError.kind {
    case .localChangesOverwritten, .mergeWithLocalChanges, .rebaseWithLocalChanges:
        return .localChangesOverwritten(
            repositoryID: repositoryID,
            files: parseFilesToBeOverwritten(gitError.stderr))
    default:
        return nil
    }
}

// MARK: - Branch checkout / CRUD

/// Checkout `branch` (local or remote-tracking) then refresh.
/// Remote branches create a local branch (`checkout -b <short>`).
@MainActor
@discardableResult
public func shellCheckoutBranch(store: AppStore, repository: Repository, branch: Branch) async -> Bool {
    let path = repository.path
    let name = branch.name
    let isRemote = branch.type == .remote
    do {
        let args = UndoResetOperations.checkoutBranchArgs(branchName: name, isRemote: isRemote)
        let checkout = try await GitProcess.run(args, workingDirectory: path)
        if let error = classifyGitResult(checkout, args: args, successExitCodes: [0]) {
            throw error
        }
        // Best-effort submodule refresh (mirrors the reference post-checkout
        // step); failures must not fail the checkout itself.
        try? await UndoResetLiveOperations.updateSubmodulesAfterCheckout(repositoryPath: path)
        await store.refreshRepository(repository)
        return true
    } catch {
        if let popup = checkoutConflictPopup(error: error, repositoryID: repository.id) {
            // Dirty-WD conflicts surface the bespoke sheet (with the file
            // list) instead of a bare `.error`.
            store.showPopup(popup)
        } else {
            store.routeRefreshFailure(error, for: repository)
        }
        return false
    }
}

/// Create a branch from a `BranchStartPoint` choice (or a fixed SHA).
@MainActor
@discardableResult
public func shellCreateBranch(
    store: AppStore,
    repository: Repository,
    name: String,
    startPoint: BranchStartPoint,
    fixedTargetSHA: String?,
    currentBranchName: String?,
    defaultBranchName: String?
) async -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let path = repository.path
    let resolvedStart: String? = {
        if let fixedTargetSHA, !fixedTargetSHA.isEmpty { return fixedTargetSHA }
        switch startPoint {
        case .currentBranch: return currentBranchName
        case .defaultBranch: return defaultBranchName ?? currentBranchName
        case .head: return "HEAD"
        case .commit: return fixedTargetSHA
        }
    }()
    do {
        try await BranchOperations.createBranch(
            repositoryPath: path, name: trimmed,
            startPoint: resolvedStart, noTrack: false)
        await store.refreshRepository(repository)
        return true
    } catch {
        store.routeRefreshFailure(error, for: repository)
        return false
    }
}

/// Rename `branch`, retrying case-only renames with `-M` (mirrors
/// `lib/git/branch.ts`).
@MainActor
@discardableResult
public func shellRenameBranch(
    store: AppStore, repository: Repository, branch: Branch, newName: String
) async -> Bool {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != branch.name else { return false }
    let path = repository.path
    let oldName = branch.nameWithoutRemote
    let caseOnly = isCaseOnlyRename(from: branch.name, to: trimmed)
    do {
        do {
            try await BranchOperations.renameBranch(
                repositoryPath: path, oldName: oldName, newName: trimmed, force: false)
        } catch let error as GitError where error.kind == .branchAlreadyExists && caseOnly {
            // Case-only retry on case-insensitive filesystems.
            try await BranchOperations.renameBranch(
                repositoryPath: path, oldName: oldName, newName: trimmed, force: true)
        }
        await store.refreshRepository(repository)
        return true
    } catch {
        store.routeRefreshFailure(error, for: repository)
        return false
    }
}

/// Delete a local branch, optionally also deleting the remote branch
/// (`git push <remote> :<branch>` + `deleteRef` fallback).
@MainActor
@discardableResult
public func shellDeleteBranch(
    store: AppStore, repository: Repository, branch: Branch, deleteRemote: Bool
) async -> Bool {
    let path = repository.path
    let localName = branch.nameWithoutRemote
    let remoteName = branch.upstreamRemoteName
    do {
        try await BranchOperations.deleteLocalBranch(repositoryPath: path, branchName: localName)
        if deleteRemote, let remoteName {
            let service = await store.gitService(for: repository)
            let remotes = (try? await service.remotes()) ?? []
            let remote = remotes.first { $0.name == remoteName } ?? Remote(name: remoteName, url: "")
            let args = ["push", remoteName, ":\(localName)"]
            let push = try await GitProcess.run(
                args, workingDirectory: path,
                environment: envForRemoteOperation(remote.url))
            if let error = classifyGitResult(push, args: args, successExitCodes: [0]) {
                if error.kind == .branchDeletionFailed {
                    let ref = "refs/remotes/\(remoteName)/\(localName)"
                    _ = try? await GitProcess.run(
                        ["update-ref", "-d", ref], workingDirectory: path)
                } else {
                    throw error
                }
            }
        }
        await store.refreshRepository(repository)
        return true
    } catch {
        store.routeRefreshFailure(error, for: repository)
        return false
    }
}

// MARK: - Sync (fetch / pull / push)

@MainActor
private func syncService(
    store: AppStore, repository: Repository
) async -> (any SyncOperations)? {
    let service = await store.gitService(for: repository)
    if let sync = service as? any SyncOperations { return sync }
    store.showPopup(.error(message: "Sync is unavailable for this repository."))
    return nil
}

@MainActor
private func syncContext(repository: Repository, remoteURL: String?, operation: SyncOperationKind) -> SyncErrorContext {
    SyncErrorContext(
        repositoryID: repository.id, remoteURL: remoteURL,
        operation: operation, isBackgroundTask: false)
}

/// Fetch `remote`, refresh on success. Returns true on success.
@MainActor
@discardableResult
public func shellFetch(store: AppStore, repository: Repository, remote: Remote) async -> Bool {
    guard let sync = await syncService(store: store, repository: repository) else { return false }
    let context = syncContext(repository: repository, remoteURL: remote.url, operation: .fetch)
    let ok: Bool? = await store.performSyncOperation(context: context) {
        try await sync.fetch(remote: remote, progress: nil, isBackgroundTask: false)
        return true
    }
    guard ok == true else { return false }
    await store.refreshRepository(repository)
    return true
}

/// Pull `remote`, refresh on success.
@MainActor
@discardableResult
public func shellPull(store: AppStore, repository: Repository, remote: Remote) async -> Bool {
    guard let sync = await syncService(store: store, repository: repository) else { return false }
    let context = syncContext(repository: repository, remoteURL: remote.url, operation: .pull)
    let ok: Bool? = await store.performSyncOperation(context: context) {
        try await sync.pull(remote: remote, progress: nil, noVerify: false)
        return true
    }
    guard ok == true else { return false }
    await store.refreshRepository(repository)
    return true
}

/// Push the current branch. `remoteBranch == nil` pushes with
/// `--set-upstream`; `forceWithLease` adds `--force-with-lease`.
@MainActor
@discardableResult
public func shellPush(
    store: AppStore,
    repository: Repository,
    remote: Remote,
    localBranch: String,
    remoteBranch: String?,
    forceWithLease: Bool = false
) async -> Bool {
    guard let sync = await syncService(store: store, repository: repository) else { return false }
    let context = syncContext(repository: repository, remoteURL: remote.url, operation: .push)
    let ok: Bool? = await store.performSyncOperation(context: context) {
        try await sync.push(
            remote: remote, localBranch: localBranch,
            remoteBranch: remoteBranch, tagsToPush: [],
            forceWithLease: forceWithLease, noVerify: false, progress: nil)
        return true
    }
    guard ok == true else { return false }
    await store.refreshRepository(repository)
    return true
}

// MARK: - Tags / worktrees (via GitService so mocks work)

@MainActor
@discardableResult
public func shellCreateTag(store: AppStore, repository: Repository, name: String, targetSHA: String) async -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let result: String? = await store.performPipelineMutation(for: repository) { service in
        try await service.createTag(name: trimmed, targetCommitSha: targetSHA)
        return trimmed
    }
    return result != nil
}

@MainActor
@discardableResult
public func shellDeleteTag(store: AppStore, repository: Repository, name: String) async -> Bool {
    let result: Bool? = await store.performPipelineMutation(for: repository) { service in
        try await service.deleteTag(name: name)
        return true
    }
    return result ?? false
}

@MainActor
@discardableResult
public func shellAddWorktree(
    store: AppStore, repository: Repository,
    path: String, createBranch: String?, commitish: String?
) async -> Bool {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else { return false }
    let result: Bool? = await store.performPipelineMutation(for: repository) { service in
        try await service.addWorktree(path: trimmedPath, createBranch: createBranch, commitish: commitish)
        return true
    }
    return result ?? false
}

@MainActor
@discardableResult
public func shellRenameWorktree(
    store: AppStore, repository: Repository, oldPath: String, newPath: String
) async -> Bool {
    let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != oldPath else { return false }
    let result: Bool? = await store.performPipelineMutation(for: repository) { service in
        try await service.moveWorktree(oldPath: oldPath, newPath: trimmed)
        return true
    }
    return result ?? false
}

@MainActor
@discardableResult
public func shellRemoveWorktree(
    store: AppStore, repository: Repository, path: String, force: Bool
) async -> Bool {
    do {
        let service = await store.gitService(for: repository)
        try await service.removeWorktree(path: path, force: force)
        await store.refreshRepository(repository)
        return true
    } catch {
        // Surface the failed-delete sheet (Task 8) instead of a bare
        // `.error` so the shell can offer force-retry.
        if let gitError = error as? GitError {
            store.showPopup(.deleteWorktreeFailed(
                repositoryID: repository.id, worktreePath: path,
                message: gitError.displayMessage))
        } else {
            store.showPopup(.error(message: error.localizedDescription))
        }
        // Still refresh so the list reflects reality.
        await store.refreshRepository(repository)
        return false
    }
}

/// Switch to `worktree` by selecting (or adding) a repository at its path.
/// Transfers nothing but the selection — the pipeline refresh rebuilds state
/// for the new path (mirrors the reference state-transfer seam).
@MainActor
public func shellSwitchWorktree(store: AppStore, repository: Repository, worktree: WorktreeEntry) {
    // Compare canonical paths: `git worktree list` resolves symlinks while
    // the stored repository path may not (`/tmp/…` vs `/private/var/…`).
    if canonicalRepoPath(worktree.path) == canonicalRepoPath(repository.path) {
        store.closeFoldout()
        return
    }
    if let existing = store.repositories.first(where: {
        canonicalRepoPath($0.path) == canonicalRepoPath(worktree.path)
    }) {
        store.selectRepository(existing)
    } else {
        let nextID = (store.repositories.map(\.id).max() ?? 0) + 1
        let added = Repository(path: worktree.path, id: nextID)
        store.addRepositories([added], selectFirst: true)
        store.persistRepositories()
    }
    store.closeFoldout()
}

// MARK: - Merge (via LiveMergeService + banners)

/// Run a merge of `theirBranch` into the current branch, refresh, and post
/// the result banner. Conflict failures post `mergeConflictsFound` whose
/// popup reopens the merge dialog for `repository`.
@MainActor
public func shellMerge(
    store: AppStore, repository: Repository,
    ourBranchName: String, theirBranchName: String, squash: Bool = false
) async {
    let path = repository.path
    let service = LiveMergeService()
    do {
        let result = try await service.merge(
            repositoryPath: path, branch: theirBranchName,
            options: MergeOptions(squash: squash))
        await store.refreshRepository(repository)
        switch result {
        case .success:
            store.setBanner(.successfulMerge(ourBranch: ourBranchName, theirBranch: theirBranchName))
        case .alreadyUpToDate:
            store.setBanner(.branchAlreadyUpToDate(ourBranch: ourBranchName, theirBranch: theirBranchName))
        case .failed:
            store.setBanner(.mergeConflictsFound(
                ourBranch: ourBranchName,
                popup: .merge(repositoryID: repository.id)))
        }
    } catch {
        await store.refreshRepository(repository)
        if let gitError = error as? GitError {
            store.setBanner(.mergeConflictsFound(
                ourBranch: ourBranchName,
                popup: .merge(repositoryID: repository.id)))
            // Also surface non-conflict failures so silent merges never happen.
            if gitError.kind != .mergeConflicts {
                store.showPopup(.error(message: gitError.displayMessage))
            }
        } else {
            store.showPopup(.error(message: error.localizedDescription))
        }
    }
}

// MARK: - Banner undo (reset --hard to the recorded pre-op tip)

/// True undo for cherry-pick/squash/reorder success banners. Port of
/// `_undoMultiCommitOperation`: the pre-op tip recorded at completion is
/// validated (undo info → clean workdir → still on the branch → known SHA)
/// and the branch is `reset --hard` to it, then the `*Undone` banner posts
/// and the record is consumed. Guard trips and reset failures surface `.error`
/// sheets (never silent, never crashing); rebase/merge success banners just
/// clear (no undo in the reference either).
@MainActor
public func shellUndoBanner(store: AppStore, banner: Banner) async {
    guard let repository = store.selectedRepository else {
        store.clearBanner()
        return
    }
    let kind: MultiCommitOperationKind
    let undone: Banner
    switch banner {
    case .successfulCherryPick(let target, let count, _):
        kind = .cherryPick
        undone = .cherryPickUndone(targetBranchName: target, countCherryPicked: count)
    case .successfulSquash(let count, _):
        kind = .squash
        undone = .squashUndone(commitsCount: count)
    case .successfulReorder(let count, _):
        kind = .reorder
        undone = .reorderUndone(commitsCount: count)
    default:
        store.clearBanner()
        return
    }
    guard let state = store.repositoryStates[repository.hash] else {
        store.clearBanner()
        return
    }
    switch decideMultiCommitUndo(
        record: store.multiCommitUndoStates[repository.hash],
        expectedKind: kind,
        tip: state.tip,
        hasLocalChanges: !state.workingDirectory.files.isEmpty
    ) {
    case .refuse(let reason):
        store.showPopup(.error(message: reason.message))
        return
    case .proceed(let record):
        // No force-push bookkeeping: the Swift state has no
        // `forcePushBranches` map (the warn-force-push gate is settings-only).
        // No source-branch checkout either: our cherry-pick never leaves the
        // branch (and branch creation during cherry-pick is not ported).
        let reset: Void? = await store.performPipelineMutation(for: repository) { service in
            try await service.reset(mode: .hard, ref: record.undoSHA)
        }
        // `performPipelineMutation` already posted `.error` (or routed to
        // Missing) on failure — only acknowledge on success.
        guard reset != nil else { return }
        store.multiCommitUndoStates.removeValue(forKey: repository.hash)
        store.setBanner(undone)
    }
}
