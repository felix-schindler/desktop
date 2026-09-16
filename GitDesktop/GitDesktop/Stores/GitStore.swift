import Foundation

// MARK: - GitStore
// Task 11 data pipeline: per-repository `actor GitStore` owning a
// `GitService` (Live in production, Mock in previews/tests).
//
// Reference: `electron/app/src/lib/stores/git-store.ts` (`loadStatus`,
// `loadBranches`, `loadRemotes`, `getCommits`) + `git-store-cache.ts`.
// The Swift collapse is deliberately small: `refresh()` loads status +
// branches + recent log + remotes and builds a `RepositoryState` snapshot.
// Mutations run through the actor (serial execution) then re-refresh so
// Tasks 12–14 read one consistent seam and never call git directly.
//
// Errors are never swallowed here and never crash: `refresh()` throws the
// classified `GitError` (see `GitError.swift`) and `AppStore` maps it to an
// `.error` popup / Missing view (see `App/AppStore+GitPipeline.swift`).

// MARK: - Pure helpers (no git, fully unit-testable)

/// Default remote: `origin` when present, else the first remote.
/// Port of `findDefaultRemote` in `helpers/find-default-remote.ts`.
nonisolated public func findDefaultRemote(remotes: [Remote]) -> Remote? {
    if let origin = remotes.first(where: { $0.name == "origin" }) {
        return origin
    }
    return remotes.first
}

/// Current remote for `tip`: the upstream's remote when the branch tracks
/// one, else the default. Port of `GitStore.loadRemotes`.
nonisolated public func findCurrentRemote(
    remotes: [Remote],
    tip: Tip,
    defaultRemote: Remote?
) -> Remote? {
    if case .valid(let branch) = tip,
       let upstreamRemote = branch.upstreamRemoteName,
       let match = remotes.first(where: { $0.name == upstreamRemote }) {
        return match
    }
    return defaultRemote
}

/// Resolve `Tip` from status headers, preferring the matching local branch
/// from `branches` (carries the for-each-ref upstream) when available.
/// Mirrors `GitStore.loadStatus`: branch+tip → valid, tip-only → detached,
/// branch-only → unborn, neither → unknown.
nonisolated public func resolveTip(
    headers: StatusParser.StatusHeaders,
    branches: [Branch]
) -> Tip {
    switch (headers.currentBranch, headers.currentTip) {
    case (let branchName?, let tipSHA?):
        if let match = branches.first(where: { $0.type == .local && $0.name == branchName }) {
            // Refresh the tip SHA from status (HEAD) while keeping the
            // branch's upstream/ref from for-each-ref.
            var branch = match
            branch.tip = BranchTip(sha: tipSHA)
            if branch.upstream == nil {
                branch.upstream = headers.currentUpstreamBranch
            }
            return .valid(branch: branch)
        }
        return .valid(branch: Branch(
            name: branchName,
            upstream: headers.currentUpstreamBranch,
            tip: BranchTip(sha: tipSHA),
            type: .local,
            ref: "refs/heads/\(branchName)"))
    case (nil, let tipSHA?):
        return .detached(currentSha: tipSHA)
    case (let branchName?, nil):
        return .unborn(ref: "refs/heads/\(branchName)")
    case (nil, nil):
        return .unknown
    }
}

/// Default branch: `origin/HEAD` (via `symbolic-ref`) first, falling back to
/// the local heuristic (`main` → `master` → first sorted).
/// Port of `findDefaultBranch` in `helpers/find-default-branch.ts`: when the
/// caller supplies `remoteHEAD` (from `getRemoteHEAD`) or a
/// `defaultBranchName` (from `init.defaultBranch`), local branches tracking
/// the remote default win, then local name matches, then the remote branch
/// itself. The old heuristic remains as the final fallback so repos without
/// a resolvable remote HEAD keep a stable default.
nonisolated public func findDefaultBranch(
    branches: [Branch],
    defaultRemoteName: String? = nil,
    remoteHEAD: String? = nil,
    defaultBranchName: String? = nil
) -> Branch? {
    if remoteHEAD != nil || defaultBranchName != nil {
        let name = remoteHEAD ?? defaultBranchName ?? "main"
        let remoteRef: String? = {
            guard let remoteHEAD, let defaultRemoteName else { return nil }
            return "\(defaultRemoteName)/\(remoteHEAD)"
        }()
        if let hit = resolveDefaultBranch(
            branches: branches,
            defaultBranchName: name,
            remoteRef: remoteRef
        ) {
            return hit
        }
    }
    let locals = branches.filter { $0.type == .local }
    if let main = locals.first(where: { $0.name == "main" }) { return main }
    if let master = locals.first(where: { $0.name == "master" }) { return master }
    return locals.sorted(by: { $0.name < $1.name }).first
}

/// Merge fresh git data into the previous UI state, preserving the user's
/// draft (`commitMessage`, `selection`). Pure so tests cover it without git.
nonisolated public func buildRepositoryState(
    repository: Repository,
    previous: RepositoryState?,
    status: RepositoryStatus,
    branches: [Branch],
    remotes: [Remote],
    commits: [Commit],
    remoteHEAD: String? = nil,
    defaultBranchName: String? = nil
) -> RepositoryState {
    let tip = resolveTip(headers: status.headers, branches: branches)
    let defaultRemote = findDefaultRemote(remotes: remotes)
    let current = findCurrentRemote(remotes: remotes, tip: tip, defaultRemote: defaultRemote)
    var next = previous ?? RepositoryState(repository: repository)
    next.repository = repository
    next.workingDirectory = status.workingDirectory
    next.tip = tip
    next.aheadBehind = status.headers.aheadBehind
    next.branches = branches
    next.remote = current
    next.remotes = remotes
    next.recentCommits = commits
    next.defaultBranch = findDefaultBranch(
        branches: branches,
        defaultRemoteName: defaultRemote?.name,
        remoteHEAD: remoteHEAD,
        defaultBranchName: defaultBranchName)
    return next
}

// MARK: - Actor

/// Per-repository pipeline. One instance per repository hash, owned by
/// `AppStore` (see `App/AppStore+GitPipeline.swift`). Tasks 12–14 read
/// `RepositoryState` from `AppStore` and run mutations via
/// `performAndRefresh` — they never instantiate git services directly.
public actor GitStore {
    /// Repository this store refreshes. Updated via `updateRepository`
    /// when the alias/path changes (cache re-keying lives in `AppStore`).
    public private(set) var repository: Repository
    private var service: any GitService
    private var cached: RepositoryState?

    /// General init: any `GitService` (Live for real repos, Mock for
    /// previews/tests). The pipeline never branches on concrete type.
    public init(repository: Repository, service: any GitService) {
        self.repository = repository
        self.service = service
        self.cached = nil
    }

    /// Convenience for production: Live service for the repo path.
    public init(repository: Repository) {
        self.repository = repository
        self.service = LiveGitService(repositoryPath: repository.path)
        self.cached = nil
    }

    /// Expose the service for thin view adapters (Tasks 12–14) that still
    /// need direct calls (diff contents, commit files). Prefer
    /// `performAndRefresh` for mutations so the cache stays coherent.
    public func gitService() -> any GitService {
        service
    }

    /// Update the repository (alias/path change). Live services track the
    /// path, so a path change recreates the Live service; injected mocks
    /// are kept as-is for previews/tests.
    public func updateRepository(_ repository: Repository) {
        let pathChanged = repository.path != self.repository.path
        self.repository = repository
        if pathChanged, service is LiveGitService {
            service = LiveGitService(repositoryPath: repository.path)
        }
        if var state = cached {
            state.repository = repository
            cached = state
        }
    }

    /// Seed or replace the cached snapshot (previews + tests).
    public func seed(_ state: RepositoryState) {
        cached = state
    }

    public func cachedState() -> RepositoryState? {
        cached
    }

    // MARK: Refresh

    /// Load status + branches + remotes + recent log and publish a new
    /// `RepositoryState`. Throws the classified `GitError` on failure —
    /// callers (`AppStore.refreshRepository`) map it to `.error` / Missing.
    ///
    /// A nil `status()` means "not a git repository" (Live maps exit 128 →
    /// nil); it throws `.notAGitRepository` so the caller routes to Missing.
    @discardableResult
    public func refresh(historyLimit: Int = 100) async throws -> RepositoryState {
        let status = try await service.status(includeUntracked: true)
        guard let status else {
            throw GitError(
                kind: .notAGitRepository,
                args: ["status"],
                stdout: "",
                stderr: "Not a git repository: \(repository.path)",
                exitCode: 128)
        }
        // Sequential: buffered calls, each fast on warm repos. Parallel
        // `async let` can land later with streaming `GitProcess` (Task 15).
        let branches = try await service.branches()
        let remotes = try await service.remotes()
        let commits = try await service.commits(range: nil, limit: historyLimit)
        // Remote HEAD resolution (best-effort, never throws): missing symref
        // or config just falls back to the local heuristic in
        // `findDefaultBranch`. Mirrors `find-default-branch.ts`. Resolved
        // through the `RemoteHEADResolving` seam so mocks stay hermetic
        // (no git I/O); non-conforming services skip to the fallback.
        let defaultRemote = findDefaultRemote(remotes: remotes)
        var remoteHEAD: String?
        var resolvedDefaultName: String
        if let resolver = service as? any RemoteHEADResolving {
            if let name = defaultRemote?.name {
                remoteHEAD = await resolver.remoteHEAD(remote: name)
            }
            if let remoteHEAD {
                resolvedDefaultName = remoteHEAD
            } else {
                resolvedDefaultName = await resolver.defaultBranchFallbackName()
            }
        } else {
            // Non-conforming services (test failure injectors): real lookup
            // is best-effort and never throws; refresh already failed earlier
            // for these when status() throws.
            if let name = defaultRemote?.name {
                remoteHEAD = await getRemoteHEAD(repositoryPath: repository.path, remote: name)
            }
            let configDefault = await getDefaultBranch()
            resolvedDefaultName = remoteHEAD ?? configDefault
        }
        let next = buildRepositoryState(
            repository: repository,
            previous: cached,
            status: status,
            branches: branches,
            remotes: remotes,
            commits: commits,
            remoteHEAD: remoteHEAD,
            defaultBranchName: resolvedDefaultName)
        cached = next
        return next
    }

    // MARK: Mutations (run through the actor, then re-refresh)

    /// Run any service operation serially through the actor, then refresh.
    /// Sync/branch ops that need `SyncOperations` cast inside `work`:
    /// `guard let sync = service as? any SyncOperations else { … }`.
    @discardableResult
    public func performAndRefresh<T: Sendable>(
        historyLimit: Int = 100,
        work: @Sendable (any GitService) async throws -> T
    ) async throws -> (T, RepositoryState) {
        let result = try await work(service)
        let state = try await refresh(historyLimit: historyLimit)
        return (result, state)
    }

    @discardableResult
    public func stage(files: [String], historyLimit: Int = 100) async throws -> RepositoryState {
        let (_, state) = try await performAndRefresh(historyLimit: historyLimit) { service in
            try await service.stage(files: files)
        }
        return state
    }

    @discardableResult
    public func unstage(files: [String], historyLimit: Int = 100) async throws -> RepositoryState {
        let (_, state) = try await performAndRefresh(historyLimit: historyLimit) { service in
            try await service.unstage(files: files)
        }
        return state
    }

    /// Stage `context` (full files + partial `git apply --cached` patches
    /// via `service.commit`, which mirrors `createCommit`) then refresh.
    /// Returns the new SHA + state.
    @discardableResult
    public func commit(context: CommitContext, historyLimit: Int = 100) async throws -> (String, RepositoryState) {
        let (sha, state) = try await performAndRefresh(historyLimit: historyLimit) { service in
            try await service.commit(context: context)
        }
        return (sha, state)
    }
}
