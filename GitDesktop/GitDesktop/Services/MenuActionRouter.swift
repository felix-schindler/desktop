import Foundation

// MARK: - MenuActionRouter (Task 14)
// Central subscription point for every `GitDesktopMenuAction` that had no
// subscriber after Task 10: push/pull/fetch, stash-all, update-from-default,
// compare, merge, squash-and-merge, rebase, create-tag, rename/delete branch
// and discard-all — plus the shared toolbar code path.
//
// Wiring (per Docs/10-interactions.md §1–2):
// - Menus (`App/Commands.swift`) only POST notifications; they never run git.
// - This router SUBSCRIBES via `AppStore.handleMenuAction`, observed once in
//   `ContentView` (always mounted) and runs the real pipeline operations:
//   sync through `SyncOperations` + the `GitStore` actor, stash through
//   `GitService`, and destructive/branching flows through their confirm popups
//   (executed by the Tasks 5–8 dialogs, rendered bespoke by Task 13).
// - The toolbar calls the same `AppStore` methods directly
//   (`performToolbarPrimaryAction` → `menuPush`/`menuPull`/…) so menu and
//   button share one code path with no duplicate implementations.
//
// Reference: `electron/app/src/ui/app.tsx` (menu handlers) +
// `lib/menu-update.ts` (enable rules) + `lib/stores/app-store.ts`
// (`_createStashForCurrentBranch`, `mergeBranch`, `showRebaseDialog`).
// Scope deletions apply throughout: no GitHub publish dialog (publish with
// no remote routes to Repository Settings so the user can add a remote), no
// editor/shell items.

// MARK: - Pure routing taxonomy (no git, no AppStore)

/// Who owns a menu action. Every `GitDesktopMenuAction` maps to exactly one
/// owner — the inventory test asserts exhaustiveness so no action is silently
/// dropped when new cases are added (the switches below stay exhaustive).
public enum MenuActionOwner: String, Sendable, Equatable {
    /// Real pipeline op or its confirm popup, via `AppStore.handleMenuAction`.
    case router
    /// Tab navigation inside `RepositoryView` (Changes/History/compare).
    case repositoryView
    /// Focused-view text actions (mirrors the reference `select-all` /
    /// `find-text` custom events dispatched to the focused element):
    /// `TextDiffView` find + diff select-all, plus the Changes file-list
    /// select-all in `ChangesSidebarView`.
    case focusedView
    /// Foldouts, stash toggle, changes filter, pane resize — owned by Tasks
    /// 12–13 (shell composition). Listed explicitly so the inventory has no
    /// silent gaps.
    case deferred
}

public func ownerOfMenuAction(_ action: GitDesktopMenuAction) -> MenuActionOwner {
    switch action {
    case .push, .pull, .fetch,
         .stashAllChanges, .updateFromDefault,
         .mergeIntoCurrent, .squashAndMerge, .rebaseCurrent,
         .createTag, .createBranch, .renameBranch, .deleteBranch,
         .discardAllChanges:
        return .router
    case .showChanges, .showHistory, .goToCommitMessage, .compareToBranch:
        return .repositoryView
    case .findInDiff, .selectAll:
        return .focusedView
    case .chooseRepository, .showBranches, .showWorktrees,
         .toggleStashedChanges, .toggleChangesFilter,
         .increaseResizableWidth, .decreaseResizableWidth:
        return .deferred
    }
}

/// Whether a menu item is enabled. Mirrors the `Commands` disabled states
/// item-for-item: the Repository + Branch menus require a selected repository
/// and stay enabled otherwise; View/Edit items are never disabled. The finer
/// reference rules (unborn/detached/no-remote/has-changes in `menu-update.ts`)
/// are enforced as router guards with feedback instead — `Commands` only
/// knows the selection, not the state.
public func isMenuActionEnabled(_ action: GitDesktopMenuAction, hasSelection: Bool) -> Bool {
    if hasSelection { return true }
    switch action {
    case .push, .pull, .fetch,
         .createBranch, .renameBranch, .deleteBranch,
         .discardAllChanges, .stashAllChanges,
         .updateFromDefault, .compareToBranch,
         .mergeIntoCurrent, .squashAndMerge, .rebaseCurrent,
         .createTag:
        return false
    case .showChanges, .showHistory, .chooseRepository, .showBranches,
         .showWorktrees, .goToCommitMessage, .toggleStashedChanges,
         .toggleChangesFilter, .increaseResizableWidth, .decreaseResizableWidth,
         .findInDiff, .selectAll:
        return true
    }
}

// MARK: - Pure state resolvers (no git, fully unit-testable)

/// Resolved sync endpoint: the state's current remote (falling back to the
/// default remote like `GitStore.loadRemotes`) plus the current branch when
/// HEAD is on one. Nil when no remote is configured at all.
public struct MenuSyncTarget: Sendable, Equatable {
    public var remote: Remote
    public var branch: Branch?

    public init(remote: Remote, branch: Branch?) {
        self.remote = remote
        self.branch = branch
    }
}

public func resolveMenuSyncTarget(state: RepositoryState) -> MenuSyncTarget? {
    guard let remote = state.remote ?? findDefaultRemote(remotes: state.remotes) else {
        return nil
    }
    let branch: Branch?
    if case .valid(let current) = state.tip {
        branch = current
    } else {
        branch = nil
    }
    return MenuSyncTarget(remote: remote, branch: branch)
}

/// Feedback when push/pull cannot run because HEAD is not on a branch.
/// Mirrors the reference menu-update guards (`branchIsUnborn`, `onDetachedHead`).
public func syncAvailabilityMessage(operation: String, state: RepositoryState) -> String {
    switch state.tip {
    case .unborn:
        return "\(operation) is unavailable before the first commit."
    case .detached:
        return "\(operation) is unavailable while HEAD is detached."
    case .unknown:
        return "\(operation) is unavailable: the repository state is unknown."
    case .valid:
        return "\(operation) is unavailable for the current branch."
    }
}

/// Feedback when pull cannot run because the current branch tracks no
/// upstream. Plain `git pull <remote>` fails with "did not specify a branch"
/// in that state; the toolbar never offers Pull there (it shows Publish
/// instead), so the menu explains rather than dumping git's stderr.
public func pullUpstreamMessage(branchName: String) -> String {
    "Pull is unavailable: the current branch '\(branchName)' has no upstream branch."
}

/// Merge source for "Update from Default Branch": the inferred default branch
/// when the current branch is valid and different from it. Nil mirrors the
/// reference early return (menu-update.ts disables the item in those states).
public func updateFromDefaultTarget(state: RepositoryState) -> Branch? {
    guard case .valid(let current) = state.tip,
          let def = state.defaultBranch,
          current.ref != def.ref
    else { return nil }
    return def
}

/// File IDs for the discard-all confirm (mirrors `discardAllChanges` in
/// `app.tsx`, which passes the whole working-directory file list).
public func menuDiscardAllFileIDs(state: RepositoryState) -> [String] {
    state.workingDirectory.files.map(\.id)
}

/// `existsOnRemote` for the delete-branch confirm. Mirrors the reference
/// (`aheadBehind !== null`); the bespoke dialog (Task 13) uses it to warn
/// that the remote branch survives.
public func menuDeleteBranchExistsOnRemote(state: RepositoryState) -> Bool {
    state.aheadBehind != nil
}

/// Tag target for "Create Tag…": the tip commit (current branch tip, or the
/// checked-out SHA when detached). Nil on unborn/unknown (nothing to tag).
public func menuCreateTagTargetSHA(state: RepositoryState) -> String? {
    switch state.tip {
    case .valid(let branch): return branch.tip.sha
    case .detached(let sha): return sha
    case .unborn, .unknown: return nil
    }
}

/// Owning branch name for "Stash All Changes…". Nil when HEAD is not on a
/// branch (mirrors `_createStashForCurrentBranch`, which bails without one).
public func menuStashBranchName(state: RepositoryState) -> String? {
    if case .valid(let branch) = state.tip { return branch.name }
    return nil
}

// MARK: - Toolbar unification (pure mapping)

/// What the toolbar push/pull button delegates to. The menu actions resolve
/// to the same cases, so both triggers share the `AppStore` methods below.
public enum ToolbarSyncRequest: Sendable, Equatable {
    case push
    case pull
    case fetch
    case forcePush(remote: String)
    /// No remote configured. There is no GitHub publish dialog per scope, so
    /// both menu and toolbar route to Repository Settings (Remote tab) where
    /// the user can add one.
    case publishSetup
    case none
}

public func toolbarSyncRequest(for pushPull: PushPullViewState) -> ToolbarSyncRequest {
    switch pushPull.action {
    case .push: return .push
    case .pull: return .pull
    case .fetch: return .fetch
    case .forcePush(let remote): return .forcePush(remote: remote)
    case .publishRepository, .publishBranch: return .publishSetup
    case .progress, .detached: return .none
    }
}

// MARK: - AppStore handlers

@MainActor
public extension AppStore {
    /// Central subscriber entry point. Called from `ContentView`'s
    /// always-mounted `.gitDesktopMenuAction` observer; actions owned by
    /// views (`RepositoryView`, `TextDiffView`, Changes list) are ignored
    /// here so they are never double-handled.
    func handleMenuAction(_ action: GitDesktopMenuAction) {
        guard ownerOfMenuAction(action) == .router else { return }
        switch action {
        case .push: Task { await menuPush() }
        case .pull: Task { await menuPull() }
        case .fetch: Task { await menuFetch() }
        case .stashAllChanges: Task { await menuStashAll() }
        case .discardAllChanges: menuDiscardAll()
        case .renameBranch: menuRenameBranch()
        case .deleteBranch: menuDeleteBranch()
        case .createTag: menuCreateTag()
        case .createBranch: menuCreateBranch()
        case .mergeIntoCurrent: menuMerge(squash: false)
        case .squashAndMerge: menuMerge(squash: true)
        case .rebaseCurrent: menuRebase()
        case .updateFromDefault: menuUpdateFromDefault()
        default: break
        }
    }

    // MARK: Sync (real pipeline operations)

    /// Run a sync op through the repository's `GitStore` actor, re-refresh,
    /// and publish. Failures map through the Task 7 sync error chain
    /// (`pushNeedsPull`, auth sheets, …) instead of the generic pipeline
    /// `.error`, and a vanished path routes to Missing — never a crash.
    func performSyncPipelineMutation(
        for repository: Repository,
        context: SyncErrorContext,
        work: @Sendable (any GitService) async throws -> Void
    ) async {
        guard FileManager.default.fileExists(atPath: repository.path) else {
            selectMissingRepository(repository)
            return
        }
        let pipeline = gitStore(for: repository)
        await pipeline.updateRepository(repository)
        do {
            let (_, state) = try await pipeline.performAndRefresh(work: work)
            updateRepositoryState(state)
        } catch {
            guard let popup = popupForSyncFailure(error, context: context) else {
                // Conflict errors are owned by the merge/rebase flows and map
                // to no popup — but the working directory changed (MERGE_HEAD
                // etc.), so refresh to keep the snapshot truthful instead of
                // leaving it stale with no UI at all (Task 16).
                await refreshRepository(repository)
                return
            }
            showPopup(popup)
        }
    }

    /// Menu Repository → Push (`Cmd+P`) and the toolbar push button.
    func menuPush() async {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard let target = resolveMenuSyncTarget(state: state) else {
            menuPublishSetup()
            return
        }
        guard let branch = target.branch else {
            showPopup(.error(message: syncAvailabilityMessage(operation: "Push", state: state)))
            return
        }
        let remote = target.remote
        let localBranch = branch.name
        let remoteBranch = branch.upstreamWithoutRemote
        let context = SyncErrorContext(
            repositoryID: repo.id, remoteURL: remote.url,
            operation: .push, isBackgroundTask: false)
        await performSyncPipelineMutation(for: repo, context: context) { service in
            guard let sync = service as? any SyncOperations else {
                throw GitError(
                    kind: nil, args: ["push", remote.name], stdout: "",
                    stderr: "Sync operations are unavailable for this repository.",
                    exitCode: 1)
            }
            try await sync.push(
                remote: remote, localBranch: localBranch,
                remoteBranch: remoteBranch, tagsToPush: [],
                forceWithLease: false, noVerify: false, progress: nil)
        }
    }

    /// Menu Repository → Pull (`Cmd+Shift+P`) and the toolbar pull button.
    func menuPull() async {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard let target = resolveMenuSyncTarget(state: state) else {
            menuPublishSetup()
            return
        }
        guard target.branch != nil else {
            showPopup(.error(message: syncAvailabilityMessage(operation: "Pull", state: state)))
            return
        }
        // A branch with no upstream cannot pull (plain `git pull <remote>`
        // fails with "did not specify a branch"). The toolbar never offers
        // Pull here (it shows Publish instead); the menu explains rather
        // than dumping git's stderr into an `.error` sheet (Task 16).
        if case .valid(let branch) = state.tip, branch.upstream == nil {
            showPopup(.error(message: pullUpstreamMessage(branchName: branch.name)))
            return
        }
        let remote = target.remote
        let context = SyncErrorContext(
            repositoryID: repo.id, remoteURL: remote.url,
            operation: .pull, isBackgroundTask: false)
        await performSyncPipelineMutation(for: repo, context: context) { service in
            guard let sync = service as? any SyncOperations else {
                throw GitError(
                    kind: nil, args: ["pull", remote.name], stdout: "",
                    stderr: "Sync operations are unavailable for this repository.",
                    exitCode: 1)
            }
            try await sync.pull(remote: remote, progress: nil, noVerify: false)
        }
    }

    /// Menu Repository → Fetch (`Cmd+Shift+T`), the toolbar fetch button, and
    /// the push/pull split-menu Fetch item (Task 13 calls this too).
    func menuFetch() async {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard let target = resolveMenuSyncTarget(state: state) else {
            menuPublishSetup()
            return
        }
        let remote = target.remote
        let context = SyncErrorContext(
            repositoryID: repo.id, remoteURL: remote.url,
            operation: .fetch, isBackgroundTask: false)
        await performSyncPipelineMutation(for: repo, context: context) { service in
            guard let sync = service as? any SyncOperations else {
                throw GitError(
                    kind: nil, args: ["fetch", remote.name], stdout: "",
                    stderr: "Sync operations are unavailable for this repository.",
                    exitCode: 1)
            }
            try await sync.fetch(remote: remote, progress: nil, isBackgroundTask: false)
        }
    }

    /// Toolbar push/pull split-menu → force-push confirm. Execution (with the
    /// `Defaults.confirmForcePush` gate + `WarnForcePushView`) stays with
    /// Tasks 6–7; this only opens the confirm, so the destructive op is never
    /// one click away.
    func menuForcePush(remote: String) {
        guard let repo = selectedRepository, let state = selectedState else { return }
        let upstream: String
        if case .valid(let branch) = state.tip {
            upstream = branch.upstream ?? "\(remote)/\(branch.name)"
        } else {
            upstream = "\(remote)/branch"
        }
        showPopup(.confirmForcePush(repositoryID: repo.id, upstreamBranch: upstream))
    }

    /// Shared publish fallback (menu sync with no remote + toolbar Publish
    /// states). The reference opens the GitHub publish dialog; per scope
    /// there is none, so Repository Settings opens on the Remote tab (the
    /// default tab) where the user adds the remote, then pushes normally.
    func menuPublishSetup() {
        guard let id = selectedRepository?.id else { return }
        showPopup(.repositorySettings(repositoryID: id, initialTab: nil))
    }

    /// Toolbar primary button. Same code path as the Repository menu — the
    /// button resolves to a `ToolbarSyncRequest` and delegates to the menu
    /// methods above. Button progress wiring stays with Task 13; these calls
    /// pass no progress callback yet (the ops still re-refresh on completion).
    func performToolbarPrimaryAction(_ pushPull: PushPullViewState) {
        switch toolbarSyncRequest(for: pushPull) {
        case .push: Task { await menuPush() }
        case .pull: Task { await menuPull() }
        case .fetch: Task { await menuFetch() }
        case .forcePush(let remote): menuForcePush(remote: remote)
        case .publishSetup: menuPublishSetup()
        case .none: break
        }
    }

    // MARK: Stash (real pipeline operation)

    /// Menu Branch → Stash All Changes (`Cmd+Shift+S`). Stages everything
    /// first (`stash push` without `-u` would otherwise skip unstaged
    /// untracked files — the reference stages via `stageFiles` before
    /// stashing) then creates the Desktop stash through the actor.
    func menuStashAll() async {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard let branchName = menuStashBranchName(state: state) else { return }
        let filePaths = state.workingDirectory.files.map(\.path)
        guard !filePaths.isEmpty else { return }
        await performPipelineMutation(for: repo) { service in
            try await service.stage(files: filePaths)
            return try await service.createStash(branchName: branchName)
        }
    }

    // MARK: Confirms (destructive/branching flows keep their dialogs)

    /// Menu Branch → Discard All Changes (`Cmd+Shift+Backspace`). Always
    /// confirms — discards cannot be recovered. (Reference parity: the
    /// "don't ask again" setting row is hidden for discard-all.)
    func menuDiscardAll() {
        guard let repo = selectedRepository, let state = selectedState else { return }
        let fileIDs = menuDiscardAllFileIDs(state: state)
        guard !fileIDs.isEmpty else { return }
        showPopup(.confirmDiscardChanges(
            repositoryID: repo.id,
            fileIDs: fileIDs,
            showDiscardChangesSetting: false,
            discardingAllChanges: true))
    }

    /// Menu Branch → New Branch (`Cmd+Shift+N`).
    func menuCreateBranch() {
        guard let id = selectedRepository?.id else { return }
        showPopup(.createBranch(
            repositoryID: id, initialName: nil, targetCommitSHA: nil))
    }

    /// Menu Branch → Rename (`Cmd+Shift+R`). Mirrors the reference: only when
    /// HEAD is on a branch; the bespoke dialog (Task 13) performs the rename.
    func menuRenameBranch() {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard case .valid(let branch) = state.tip else { return }
        showPopup(.renameBranch(repositoryID: repo.id, branchRef: branch.ref))
    }

    /// Menu Branch → Delete (`Cmd+Shift+D`). Opens the delete confirm (which
    /// warns when the branch exists on the remote); execution stays with the
    /// Task 5/13 dialog.
    func menuDeleteBranch() {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard case .valid(let branch) = state.tip else { return }
        showPopup(.deleteBranch(
            repositoryID: repo.id,
            branchRef: branch.ref,
            existsOnRemote: menuDeleteBranchExistsOnRemote(state: state)))
    }

    /// Menu Branch → Create Tag. Targets the tip commit; unborn/unknown HEAD
    /// has nothing to tag (mirrors the reference early return).
    func menuCreateTag() {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard let sha = menuCreateTagTargetSHA(state: state) else { return }
        showPopup(.createTag(
            repositoryID: repo.id, targetCommitSHA: sha, initialName: nil))
    }

    /// Menu Branch → Merge / Squash-and-Merge. Opens the multi-commit flow
    /// (choose-branch → merge), which executes the merge and owns the
    /// conflict UI (Tasks 5–6, rendered by Task 13).
    ///
    /// Coordination gap for Task 13: `Popup.multiCommitOperation` carries no
    /// merge-vs-rebase-vs-squash discriminator, so squash and merge open the
    /// same dialog today. Task 13 should add the mode (or read it from
    /// compare/multi-commit operation state) when it renders the bespoke
    /// wizard; see TODO.md.
    func menuMerge(squash: Bool) {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard case .valid = state.tip else { return }
        _ = squash
        showPopup(.multiCommitOperation(repositoryID: repo.id))
    }

    /// Menu Branch → Rebase Current Branch. Same flow entry as merge (the
    /// wizard's rebase choose-branch step); see the discriminator gap above.
    func menuRebase() {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard case .valid = state.tip else { return }
        showPopup(.multiCommitOperation(repositoryID: repo.id))
    }

    /// Menu Branch → Update from Default Branch. The reference merges the
    /// default branch directly; the Swift app opens the same merge flow
    /// instead so conflicts land in the wizard UI rather than stranding a
    /// conflicted working directory with no dialog open. Task 13 should
    /// preselect `state.defaultBranch` in the wizard's choose-branch step.
    func menuUpdateFromDefault() {
        guard let repo = selectedRepository, let state = selectedState else { return }
        guard updateFromDefaultTarget(state: state) != nil else { return }
        showPopup(.multiCommitOperation(repositoryID: repo.id))
    }
}
