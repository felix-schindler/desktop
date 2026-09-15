import Foundation

// MARK: - PreviewData
// Task 2 preview + manual-verification data built on `MockGitService.preview`
// shapes. The shipped app starts empty (Task 9 owns persistence); `MyApp`
// seeds this only for `#if DEBUG` smoke-testing (see `MyApp.swift`).

@MainActor
public func makePreviewStore() -> AppStore {
    let store = AppStore()
    populatePreviewData(store)
    return store
}

/// Fill an empty store with smoke-test data. Used by previews and by
/// `ContentView` when `GITDESKTOP_SEED_PREVIEW=1` (DEBUG only, Task 9 owns
/// real persistence and removes this path).
///
/// Task 11: `selectRepository` triggers an async `GitStore.refresh()`. The
/// preview paths don't exist on disk, so a Live service would fail and route
/// to Missing. Inject per-repo `MockGitService`s mirroring `previewState`
/// so the pipeline refresh is idempotent and previews keep their
/// differentiated file lists.
@MainActor
public func populatePreviewData(_ store: AppStore) {
    guard store.repositories.isEmpty else { return }
    let repositories = previewRepositories()
    store.setRepositories(repositories)
    var mocks: [String: MockGitService] = [:]
    for repository in repositories {
        let state = previewState(for: repository)
        store.updateRepositoryState(state)
        mocks[repository.hash] = previewMock(for: repository, state: state)
    }
    let captured = mocks
    store.makeService = { repo in
        captured[repo.hash] ?? MockGitService.preview
    }
    if let first = repositories.first {
        store.selectRepository(first)
    }
}

/// Mock whose stubs mirror a preview `RepositoryState`, so `GitStore.refresh()`
/// rebuilds the same working-directory/branches/remotes. Missing repos get
/// `stubStatus == nil` so refresh throws `.notAGitRepository` and routes to
/// the Missing view (same as a vanished real repo).
@MainActor
func previewMock(for repository: Repository, state: RepositoryState) -> MockGitService {
    let mock = MockGitService(repositoryPath: repository.path)
    if repository.missing {
        mock.stubStatus = nil
        mock.stubBranches = []
        mock.stubRemotes = []
        mock.stubCommits = []
        return mock
    }
    let headers: StatusParser.StatusHeaders = {
        switch state.tip {
        case .valid(let branch):
            return StatusParser.StatusHeaders(
                currentBranch: branch.name,
                currentUpstreamBranch: branch.upstream,
                currentTip: branch.tip.sha,
                aheadBehind: state.aheadBehind)
        case .detached(let sha):
            return StatusParser.StatusHeaders(
                currentBranch: nil,
                currentUpstreamBranch: nil,
                currentTip: sha,
                aheadBehind: state.aheadBehind)
        case .unborn(let ref):
            let name = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count)) : ref
            return StatusParser.StatusHeaders(
                currentBranch: name,
                currentUpstreamBranch: nil,
                currentTip: nil,
                aheadBehind: nil)
        case .unknown:
            return StatusParser.StatusHeaders()
        }
    }()
    mock.stubStatus = RepositoryStatus(
        headers: headers,
        workingDirectory: state.workingDirectory)
    mock.stubBranches = state.branches
    mock.stubRemotes = state.remote.map { [$0] } ?? []
    // One commit per tip SHA so History previews have content. The summary
    // matches the branch to keep the mock readable.
    let tipSHA: String? = {
        if case .valid(let branch) = state.tip { return branch.tip.sha }
        return nil
    }()
    if let tipSHA {
        let identity = CommitIdentity(
            name: "Ada Lovelace", email: "ada@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000), tzOffset: 0)
        mock.stubCommits = [Commit(
            sha: tipSHA, shortSha: String(tipSHA.prefix(7)),
            summary: "Preview commit on \(state.tipDescription)",
            body: "",
            author: identity, committer: identity,
            parentSHAs: [], trailers: [])]
    }
    return mock
}

private extension RepositoryState {
    /// Short human description of the tip for mock commit summaries.
    var tipDescription: String {
        switch tip {
        case .valid(let branch): return branch.name
        case .detached(let sha): return shortenSHA(sha)
        case .unborn(let ref): return ref
        case .unknown: return "unknown"
        }
    }
}

public func previewRepositories() -> [Repository] {
    [
        Repository(path: "/Users/preview/Code/GitDesktop", id: 1),
        Repository(path: "/Users/preview/Code/personal-website", id: 2, alias: "Personal website"),
        Repository(path: "/Users/preview/Code/design-tokens", id: 3),
        Repository(path: "/Volumes/Archive/old-blog", id: 4, missing: true),
    ]
}

public func previewState(for repository: Repository) -> RepositoryState {
    switch repository.id {
    case 1:
        let main = Branch(
            name: "main", upstream: "origin/main",
            tip: BranchTip(sha: "abc1234567890"),
            type: .local, ref: "refs/heads/main")
        let feature = Branch(
            name: "feature/dark-toolbar", upstream: nil,
            tip: BranchTip(sha: "def9876543210"),
            type: .local, ref: "refs/heads/feature/dark-toolbar")
        let files = [
            WorkingDirectoryFileChange(
                path: "GitDesktop/GitDesktop/Views/Shell/ToolbarView.swift",
                status: .modified(submoduleStatus: nil),
                selection: .fromInitialSelection(.all)),
            WorkingDirectoryFileChange(
                path: "GitDesktop/GitDesktop/Views/Shell/RepoListView.swift",
                status: .new(submoduleStatus: nil),
                selection: .fromInitialSelection(.all)),
            WorkingDirectoryFileChange(
                path: "old-notes.txt",
                status: .deleted(submoduleStatus: nil),
                selection: .fromInitialSelection(.all)),
        ]
        return RepositoryState(
            repository: repository,
            workingDirectory: .fromFiles(files),
            tip: .valid(branch: main),
            aheadBehind: AheadBehind(ahead: 2, behind: 1),
            branches: [main, feature],
            remote: Remote(name: "origin", url: "https://example.com/GitDesktop.git"))
    case 2:
        let main = Branch(
            name: "main", upstream: "origin/main",
            tip: BranchTip(sha: "1111111111111"),
            type: .local, ref: "refs/heads/main")
        return RepositoryState(
            repository: repository,
            workingDirectory: .fromFiles([]),
            tip: .valid(branch: main),
            aheadBehind: AheadBehind(ahead: 0, behind: 0),
            branches: [main],
            remote: Remote(name: "origin", url: "https://example.com/personal-website.git"))
    case 3:
        let develop = Branch(
            name: "develop", upstream: nil,
            tip: BranchTip(sha: "2222222222222"),
            type: .local, ref: "refs/heads/develop")
        let files = [
            WorkingDirectoryFileChange(
                path: "tokens.json",
                status: .modified(submoduleStatus: nil),
                selection: .fromInitialSelection(.all)),
        ]
        return RepositoryState(
            repository: repository,
            workingDirectory: .fromFiles(files),
            tip: .valid(branch: develop),
            aheadBehind: nil,
            branches: [develop],
            remote: nil)
    default:
        return RepositoryState(repository: repository)
    }
}
