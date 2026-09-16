import Foundation

// MARK: - GitStoreTests
// Task 11 pipeline tests. Same harness style as `Task8Tests` (no test bundle;
// `runAll()` returns the failure count) but async: refresh hits real git in a
// temp fixture repo, so callers await it:
//
//   let failures = await GitStoreTests.runAll()
//
// Covers:
// - pure pipeline helpers (`findDefaultRemote`, `findCurrentRemote`,
//   `resolveTip`, `findDefaultBranch`, `buildRepositoryState`)
// - live refresh against a fixture repo (status/branches/log populate state)
// - git failure posts `.error`; vanished path routes to the Missing view.

@MainActor
public enum GitStoreTests {
    public struct Failure: Sendable {
        public var test: String
        public var message: String
    }

    private static func check(_ condition: Bool, _ message: String, test: String, failures: inout [Failure]) {
        if !condition {
            failures.append(Failure(test: test, message: message))
        }
    }

    @discardableResult
    public static func runAll() async -> Int {
        var failures: [Failure] = []
        testFindDefaultRemote(&failures)
        testFindCurrentRemote(&failures)
        testResolveTip(&failures)
        testFindDefaultBranch(&failures)
        testBuildRepositoryState(&failures)
        await testRefreshPopulatesState(&failures)
        await testRefreshFailurePostsError(&failures)
        await testMissingRouting(&failures)
        if failures.isEmpty {
            print("GitStoreTests: all tests passed")
        } else {
            print("GitStoreTests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Pure helpers

    static func testFindDefaultRemote(_ failures: inout [Failure]) {
        let test = "default-remote"
        check(findDefaultRemote(remotes: []) == nil, "empty → nil", test: test, failures: &failures)
        let origin = Remote(name: "origin", url: "https://example.com/a.git")
        let upstream = Remote(name: "upstream", url: "https://example.com/b.git")
        check(findDefaultRemote(remotes: [upstream, origin]) == origin, "origin wins", test: test, failures: &failures)
        check(findDefaultRemote(remotes: [upstream]) == upstream, "solo → itself", test: test, failures: &failures)
    }

    static func testFindCurrentRemote(_ failures: inout [Failure]) {
        let test = "current-remote"
        let origin = Remote(name: "origin", url: "https://example.com/a.git")
        let fork = Remote(name: "fork", url: "https://example.com/b.git")
        let branch = Branch(
            name: "main", upstream: "fork/main",
            tip: BranchTip(sha: "abc1234"), type: .local, ref: "refs/heads/main")
        let current = findCurrentRemote(
            remotes: [origin, fork], tip: .valid(branch: branch), defaultRemote: origin)
        check(current == fork, "upstream remote wins, got \(String(describing: current))", test: test, failures: &failures)
        let fallback = findCurrentRemote(
            remotes: [origin], tip: .valid(branch: branch), defaultRemote: origin)
        check(fallback == origin, "missing upstream falls back to default", test: test, failures: &failures)
        let detached = findCurrentRemote(
            remotes: [origin], tip: .detached(currentSha: "abc"), defaultRemote: origin)
        check(detached == origin, "detached → default", test: test, failures: &failures)
    }

    static func testResolveTip(_ failures: inout [Failure]) {
        let test = "resolve-tip"
        let main = Branch(
            name: "main", upstream: "origin/main",
            tip: BranchTip(sha: "aaa1111"), type: .local, ref: "refs/heads/main")
        // Branch + tip → valid, preferring the branches-list upstream.
        var headers = StatusParser.StatusHeaders(
            currentBranch: "main", currentUpstreamBranch: nil,
            currentTip: "aaa1111", aheadBehind: nil)
        if case .valid(let branch) = resolveTip(headers: headers, branches: [main]) {
            check(branch.name == "main" && branch.upstream == "origin/main", "reuses list upstream", test: test, failures: &failures)
        } else {
            check(false, "expected valid", test: test, failures: &failures)
        }
        // Unknown branch → synthetic valid with status upstream.
        headers = StatusParser.StatusHeaders(
            currentBranch: "fresh", currentUpstreamBranch: "origin/fresh",
            currentTip: "bbb2222", aheadBehind: nil)
        if case .valid(let fresh) = resolveTip(headers: headers, branches: [main]) {
            check(fresh.ref == "refs/heads/fresh" && fresh.upstream == "origin/fresh", "synthetic \(fresh)", test: test, failures: &failures)
        } else {
            check(false, "expected synthetic valid", test: test, failures: &failures)
        }
        // Tip only → detached; branch only → unborn; neither → unknown.
        let detached = resolveTip(
            headers: StatusParser.StatusHeaders(currentBranch: nil, currentTip: "ccc3333"),
            branches: [])
        check(detached == .detached(currentSha: "ccc3333"), "detached", test: test, failures: &failures)
        let unborn = resolveTip(
            headers: StatusParser.StatusHeaders(currentBranch: "fresh", currentTip: nil),
            branches: [])
        check(unborn == .unborn(ref: "refs/heads/fresh"), "unborn, got \(unborn)", test: test, failures: &failures)
        let unknown = resolveTip(headers: StatusParser.StatusHeaders(), branches: [])
        check(unknown == .unknown, "unknown", test: test, failures: &failures)
    }

    static func testFindDefaultBranch(_ failures: inout [Failure]) {
        let test = "default-branch"
        func branch(_ name: String) -> Branch {
            Branch(name: name, upstream: nil, tip: BranchTip(sha: "aaa"), type: .local, ref: "refs/heads/\(name)")
        }
        check(findDefaultBranch(branches: []) == nil, "empty → nil", test: test, failures: &failures)
        let found = findDefaultBranch(branches: [branch("feature"), branch("main"), branch("master")])
        check(found?.name == "main", "main wins, got \(found?.name ?? "nil")", test: test, failures: &failures)
        let master = findDefaultBranch(branches: [branch("feature"), branch("master")])
        check(master?.name == "master", "master fallback", test: test, failures: &failures)
        let solo = findDefaultBranch(branches: [branch("develop")])
        check(solo?.name == "develop", "solo fallback", test: test, failures: &failures)
        // Remote branches never win.
        let remote = Branch(name: "origin/main", upstream: nil, tip: BranchTip(sha: "aaa"), type: .remote, ref: "refs/remotes/origin/main")
        check(findDefaultBranch(branches: [remote]) == nil, "remotes ignored", test: test, failures: &failures)
    }

    static func testBuildRepositoryState(_ failures: inout [Failure]) {
        let test = "build-state"
        let repo = Repository(path: "/tmp/fake", id: 1)
        let main = Branch(
            name: "main", upstream: "origin/main",
            tip: BranchTip(sha: "abc1234"), type: .local, ref: "refs/heads/main")
        let status = RepositoryStatus(
            headers: StatusParser.StatusHeaders(
                currentBranch: "main", currentUpstreamBranch: "origin/main",
                currentTip: "abc1234", aheadBehind: AheadBehind(ahead: 1, behind: 0)),
            workingDirectory: .fromFiles([]))
        let origin = Remote(name: "origin", url: "https://example.com/r.git")
        let identity = CommitIdentity(name: "A", email: "a@x.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        let commit = Commit(
            sha: "abc1234", shortSha: "abc1234", summary: "S", body: "",
            author: identity, committer: identity, parentSHAs: [], trailers: [])
        var previous = RepositoryState(repository: repo)
        previous.commitMessage = CommitMessage(summary: "draft", description: nil, timestamp: 7)
        let next = buildRepositoryState(
            repository: repo, previous: previous, status: status,
            branches: [main], remotes: [origin], commits: [commit])
        check(next.tip == .valid(branch: main), "tip \(next.tip)", test: test, failures: &failures)
        check(next.aheadBehind == AheadBehind(ahead: 1, behind: 0), "aheadBehind", test: test, failures: &failures)
        check(next.remote == origin && next.remotes == [origin], "remotes", test: test, failures: &failures)
        check(next.recentCommits == [commit], "commits", test: test, failures: &failures)
        check(next.defaultBranch?.name == "main", "default", test: test, failures: &failures)
        check(next.commitMessage.summary == "draft", "preserves draft", test: test, failures: &failures)
    }

    // MARK: - Live fixture

    /// Create a temp repo: `main` + `feature`, one commit, one modified + one
    /// untracked file in the working directory.
    static func makeFixtureRepo() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStoreTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func run(_ args: [String]) async throws {
            let result = try await GitProcess.run(args, workingDirectory: dir)
            guard result.exitCode == 0 else {
                throw GitError(
                    kind: parseGitError(result.stderrString),
                    args: args, stdout: result.stdoutString,
                    stderr: result.stderrString, exitCode: result.exitCode)
            }
        }
        try await run(["-c", "init.defaultBranch=main", "init"])
        try await run(["config", "user.name", "GitStore Tests"])
        try await run(["config", "user.email", "gitstore@example.com"])
        try "hello\n".write(
            toFile: (dir as NSString).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try await run(["add", "--", "README.md"])
        try await run(["commit", "-m", "Initial commit"])
        try await run(["branch", "feature"])
        // Dirty the working directory: modified tracked + new untracked.
        try "hello world\n".write(
            toFile: (dir as NSString).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try "untracked\n".write(
            toFile: (dir as NSString).appendingPathComponent("new.txt"),
            atomically: true, encoding: .utf8)
        return dir
    }

    static func testRefreshPopulatesState(_ failures: inout [Failure]) async {
        let test = "refresh-live"
        let dir: String
        do {
            dir = try await makeFixtureRepo()
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let repo = Repository(path: dir, id: 901)
        let pipeline = GitStore(repository: repo, service: LiveGitService(repositoryPath: dir))
        do {
            let state = try await pipeline.refresh()
            let paths = Set(state.workingDirectory.files.map(\.path))
            check(paths.contains("README.md") && paths.contains("new.txt"),
                  "working directory \(paths)", test: test, failures: &failures)
            let names = Set(state.branches.map(\.name))
            check(names.contains("main") && names.contains("feature"),
                  "branches \(names)", test: test, failures: &failures)
            check(!state.recentCommits.isEmpty, "history populated", test: test, failures: &failures)
            check(state.recentCommits.first?.summary == "Initial commit",
                  "log summary \(state.recentCommits.first?.summary ?? "nil")",
                  test: test, failures: &failures)
            if case .valid(let branch) = state.tip {
                check(branch.name == "main", "tip main, got \(branch.name)", test: test, failures: &failures)
            } else {
                check(false, "expected valid tip, got \(state.tip)", test: test, failures: &failures)
            }
            // AppStore selection publishes the same snapshot.
            let app = AppStore()
            app.setRepositories([repo])
            await app.refreshRepository(repo)
            let published = app.repositoryStates[repo.hash]
            check((published?.workingDirectory.files.count ?? 0) == state.workingDirectory.files.count,
                  "AppStore publishes status", test: test, failures: &failures)
            check((published?.recentCommits.count ?? 0) == state.recentCommits.count,
                  "AppStore publishes history", test: test, failures: &failures)
        } catch {
            check(false, "refresh threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testRefreshFailurePostsError(_ failures: inout [Failure]) async {
        let test = "refresh-error"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStoreTests-err-\(UUID().uuidString)").path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            check(false, "temp dir failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let repo = Repository(path: dir, id: 902)
        let app = AppStore()
        app.setRepositories([repo])
        // Select first with a succeeding mock so `.selection` becomes
        // `.repository` synchronously (mirrors the real select-then-refresh
        // flow without racing the fire-and-forget task).
        let okStatus = RepositoryStatus(
            headers: StatusParser.StatusHeaders(),
            workingDirectory: .fromFiles([]))
        let okMock = MockGitService(
            repositoryPath: dir, stubStatus: okStatus, stubCommits: [],
            stubBranches: [], stubRemotes: [])
        app.makeService = { _ in okMock }
        app.selectRepository(repo)
        // Wait out the select-triggered refresh before swapping in the
        // failing service (concurrent refreshes for one hash collapse).
        var spins = 0
        while app.isRefreshing(repo) && spins < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            spins += 1
        }
        // Now fail the next refresh: the path still exists, so the failure
        // must post `.error` and keep the `.repository` selection (only
        // vanished paths route to Missing).
        let boom = GitError(
            kind: .hostDown, args: ["fetch"], stdout: "",
            stderr: "fatal: unable to access 'x': Failed to connect: Host is down",
            exitCode: 128)
        app.makeService = { _ in FailingGitService(repositoryPath: dir, failure: boom) }
        // Drop the cached actor so the next lookup picks up the failing
        // service (actors capture their service at creation).
        app.gitStores.removeValue(forKey: repo.hash)
        await app.refreshRepository(repo)
        let hasError = app.allPopups.contains { if case .error = $0 { return true }; return false }
        check(hasError, "git failure posts .error (got \(app.allPopups))", test: test, failures: &failures)
        if case .repository = app.selection {
        } else {
            check(false, "existing-path failure keeps selection, got \(String(describing: app.selection))",
                  test: test, failures: &failures)
        }
    }

    static func testMissingRouting(_ failures: inout [Failure]) async {
        let test = "refresh-missing"
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStoreTests-gone-\(UUID().uuidString)").path
        // Never created on disk.
        let repo = Repository(path: missingPath, id: 903)
        let app = AppStore()
        app.setRepositories([repo])
        app.selectRepository(repo)
        // `selectRepository` fires an async refresh; await the explicit one
        // for determinism (the fire-and-forget dedupes while in flight, then
        // this call refreshes again — both route to Missing).
        await app.refreshRepository(repo)
        // Give the fire-and-forget task a chance to finish if it won the race.
        var attempts = 0
        while attempts < 20 {
            if case .missing = app.selection { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        if case .missing(let missing) = app.selection {
            check(missing.path == missingPath, "missing path", test: test, failures: &failures)
        } else {
            check(false, "vanished path routes to Missing, got \(String(describing: app.selection))",
                  test: test, failures: &failures)
        }
        let hasError = app.allPopups.contains { if case .error = $0 { return true }; return false }
        check(!hasError, "missing routes without .error popup", test: test, failures: &failures)
    }
}

// MARK: - Failing service (failure-path tests)

/// `GitService` that throws `failure` from every method. Lives in the test
/// file so production `MockGitService` needs no failure injection.
struct FailingGitService: GitService, Sendable {
    var repositoryPath: String
    var failure: Error

    nonisolated init(repositoryPath: String, failure: Error) {
        self.repositoryPath = repositoryPath
        self.failure = failure
    }

    func status(includeUntracked: Bool) async throws -> RepositoryStatus? { throw failure }
    func commits(range: String?, limit: Int) async throws -> [Commit] { throw failure }
    func stage(files: [String]) async throws { throw failure }
    func unstage(files: [String]) async throws { throw failure }
    func commit(context: CommitContext) async throws -> String { throw failure }
    func branches() async throws -> [Branch] { throw failure }
    func remotes() async throws -> [Remote] { throw failure }
    func stashes() async throws -> (entries: [StashEntry], totalCount: Int) { throw failure }
    func createStash(branchName: String) async throws -> Bool { throw failure }
    func popStash(stashSha: String) async throws -> StashLiveOperations.PopResult { throw failure }
    func dropStash(stashSha: String) async throws -> Bool { throw failure }
    func stashedFiles(stashSha: String) async throws -> [CommittedFileChange] { throw failure }
    func createTag(name: String, targetCommitSha: String) async throws { throw failure }
    func deleteTag(name: String) async throws { throw failure }
    func allTags() async throws -> [String: String] { throw failure }
    func worktrees() async throws -> [WorktreeEntry] { throw failure }
    func addWorktree(path: String, createBranch: String?, commitish: String?) async throws { throw failure }
    func removeWorktree(path: String, force: Bool) async throws { throw failure }
    func moveWorktree(oldPath: String, newPath: String) async throws { throw failure }
    func submodules() async throws -> [SubmoduleEntry] { throw failure }
    func installLFSHooks(force: Bool) async throws { throw failure }
    func isUsingLFS() async throws -> Bool { throw failure }
    func readGitIgnore() throws -> String? { throw failure }
    func saveGitIgnore(text: String) async throws { throw failure }
    func undoCommit(_ commit: Commit) async throws { throw failure }
    func reset(mode: GitResetMode, ref: String) async throws { throw failure }
    func revertCommit(sha: String, parentCount: Int) async throws { throw failure }
    func checkoutCommit(sha: String) async throws { throw failure }
}
