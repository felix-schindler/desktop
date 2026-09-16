#if TESTBUILD
@testable import GitDesktop
#endif
import Foundation

// MARK: - Task16Tests
// End-to-end fixture pass regressions (PLAN.md Task 16). Same harness style
// as `Task14Tests` (no test bundle; `runAll()` returns the failure count).
//
// Each group covers one failure filed during the scripted fixture pass
// (add → stage → commit → branch → merge clean/conflict → push, plus
// stash/tag/worktree round trips and the Task 10 menu/shortcut checklist):
// - pull without upstream posted raw git stderr (now a friendly message)
// - dirty-WD branch checkout posted a bare `.error` (now the bespoke
//   `.localChangesOverwritten` sheet with the file list)
// - worktree switching compared raw path strings, missing symlink-resolved
//   equivalents (`/tmp/…` vs `/private/tmp/…`) and adding duplicate repos
// - sync failures that map to no popup (merge/rebase conflicts) left the
//   pipeline snapshot stale with no UI at all (now re-refreshed)

@MainActor
public enum Task16Tests {
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
        testPullUpstreamMessage(&failures)
        await testMenuPullNoUpstream(&failures)
        await testMenuPullWithUpstream(&failures)
        testCheckoutConflictPopup(&failures)
        await testShellCheckoutDirtyPresentsSheet(&failures)
        testCanonicalRepoPath(&failures)
        testShellSwitchWorktreeDedupsSymlink(&failures)
        await testSyncConflictRefreshesState(&failures)
        await testSyncAuthFailureStillPops(&failures)
        if failures.isEmpty {
            print("Task16Tests: all tests passed")
        } else {
            print("Task16Tests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Fixtures

    private static func mainBranch(upstream: String? = nil, sha: String = "abc1234567890") -> Branch {
        Branch(
            name: "main", upstream: upstream,
            tip: BranchTip(sha: sha),
            type: .local, ref: "refs/heads/main")
    }

    private static func mockForTip(
        _ tip: Tip,
        branches: [Branch],
        remote: Remote? = Remote(name: "origin", url: "file:///tmp/origin.git"),
        path: String
    ) -> MockGitService {
        let headers: StatusParser.StatusHeaders = {
            switch tip {
            case .valid(let branch):
                return StatusParser.StatusHeaders(
                    currentBranch: branch.name,
                    currentUpstreamBranch: branch.upstream,
                    currentTip: branch.tip.sha,
                    aheadBehind: nil)
            case .detached(let sha):
                return StatusParser.StatusHeaders(
                    currentBranch: nil, currentUpstreamBranch: nil,
                    currentTip: sha, aheadBehind: nil)
            case .unborn(let ref):
                let name = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count)) : ref
                return StatusParser.StatusHeaders(
                    currentBranch: name, currentUpstreamBranch: nil,
                    currentTip: nil, aheadBehind: nil)
            case .unknown:
                return StatusParser.StatusHeaders()
            }
        }()
        let mock = MockGitService(repositoryPath: path)
        mock.stubStatus = RepositoryStatus(
            headers: headers, workingDirectory: .fromFiles([]))
        mock.stubBranches = branches
        mock.stubRemotes = remote.map { [$0] } ?? []
        mock.stubCommits = []
        return mock
    }

    private static func storeServing(
        repo: Repository, tip: Tip, branches: [Branch], mock: MockGitService
    ) async -> AppStore {
        let app = AppStore()
        app.setRepositories([repo])
        app.makeService = { _ in mock }
        await app.refreshRepository(repo)
        app.selectRepository(repo)
        // Drain the fire-and-forget select refresh: it may not have inserted
        // its hash when first checked, so wait for it to be observed in
        // flight and then finish (a plain `isRefreshing` spin can miss a
        // late-starting task and leave a stale refresh racing the test).
        var spins = 0
        var sawRefreshing = false
        while spins < 200 {
            if app.isRefreshing(repo) {
                sawRefreshing = true
            } else if sawRefreshing {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        // Re-refresh explicitly so the published state reflects the current
        // stubs with nothing in flight when the caller proceeds.
        await app.refreshRepository(repo)
        return app
    }

    // MARK: - Pull without upstream

    static func testPullUpstreamMessage(_ failures: inout [Failure]) {
        let test = "pull-upstream-message"
        let message = pullUpstreamMessage(branchName: "main")
        check(message.contains("main"), "names the branch (\(message))", test: test, failures: &failures)
        check(message.contains("upstream"), "mentions upstream (\(message))", test: test, failures: &failures)
    }

    static func testMenuPullNoUpstream(_ failures: inout [Failure]) async {
        let test = "pull-no-upstream"
        let path = FileManager.default.temporaryDirectory.path
        let repo = Repository(path: path, id: 16011)
        let main = mainBranch(upstream: nil)
        let mock = mockForTip(.valid(branch: main), branches: [main], path: path)
        let app = await storeServing(repo: repo, tip: .valid(branch: main), branches: [main], mock: mock)
        await app.menuPull()
        check(mock.pulledRemotes.isEmpty, "no pull without upstream (got \(mock.pulledRemotes))",
              test: test, failures: &failures)
        check(app.currentPopup == .error(message: pullUpstreamMessage(branchName: "main")),
              "friendly popup, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
    }

    static func testMenuPullWithUpstream(_ failures: inout [Failure]) async {
        let test = "pull-with-upstream"
        let path = FileManager.default.temporaryDirectory.path
        let repo = Repository(path: path, id: 16012)
        let main = mainBranch(upstream: "origin/main")
        let mock = mockForTip(.valid(branch: main), branches: [main], path: path)
        let app = await storeServing(repo: repo, tip: .valid(branch: main), branches: [main], mock: mock)
        await app.menuPull()
        check(mock.pulledRemotes == ["origin"], "pull runs with upstream (got \(mock.pulledRemotes))",
              test: test, failures: &failures)
        let hasError = app.allPopups.contains { if case .error = $0 { return true }; return false }
        check(!hasError, "no .error on success (got \(app.allPopups))",
              test: test, failures: &failures)
    }

    // MARK: - Checkout conflict sheet

    static func testCheckoutConflictPopup(_ failures: inout [Failure]) {
        let test = "checkout-conflict-popup"
        func gitError(kind: GitErrorKind?, stderr: String) -> GitError {
            GitError(kind: kind, args: ["checkout", "side"], stdout: "", stderr: stderr, exitCode: 1)
        }
        let stderr = "error: Your local changes to the following files would be overwritten by checkout:\n\tf.txt\nPlease commit your changes or stash them before you switch branches.\n"
        let popup = checkoutConflictPopup(
            error: gitError(kind: .localChangesOverwritten, stderr: stderr), repositoryID: 7)
        check(popup == .localChangesOverwritten(repositoryID: 7, files: ["f.txt"]),
              "conflict → sheet with files, got \(String(describing: popup))",
              test: test, failures: &failures)
        for kind: GitErrorKind? in [.mergeWithLocalChanges, .rebaseWithLocalChanges] {
            let mapped = checkoutConflictPopup(
                error: gitError(kind: kind, stderr: stderr), repositoryID: 7)
            check(mapped == .localChangesOverwritten(repositoryID: 7, files: ["f.txt"]),
                  "\(String(describing: kind)) → sheet", test: test, failures: &failures)
        }
        let other = checkoutConflictPopup(
            error: gitError(kind: .hostDown, stderr: "down"), repositoryID: 7)
        check(other == nil, "other kinds defer to routeRefreshFailure",
              test: test, failures: &failures)
        struct Boom: Error {}
        check(checkoutConflictPopup(error: Boom(), repositoryID: 7) == nil,
              "non-git errors defer", test: test, failures: &failures)
    }

    /// Live fixture: dirty `f.txt` blocks checkout of `side` (which changed
    /// `f.txt`), so the shell must present the bespoke sheet — the exact
    /// failure filed in the fixture pass (bare `.error` before the fix).
    static func testShellCheckoutDirtyPresentsSheet(_ failures: inout [Failure]) async {
        let test = "checkout-dirty-sheet"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task16Tests-checkout-\(UUID().uuidString)").path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            check(false, "temp dir failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func run(_ args: [String]) async throws {
            let result = try await GitProcess.run(args, workingDirectory: dir)
            guard result.exitCode == 0 else {
                throw GitError(
                    kind: parseGitError(result.stderrString),
                    args: args, stdout: result.stdoutString,
                    stderr: result.stderrString, exitCode: result.exitCode)
            }
        }
        do {
            try await run(["-c", "init.defaultBranch=main", "init"])
            try await run(["config", "user.name", "Task16 Tests"])
            try await run(["config", "user.email", "task16@example.com"])
            try "base\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "f.txt"])
            try await run(["commit", "-m", "c1"])
            try await run(["checkout", "-qb", "side"])
            try "side-content\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["commit", "-qam", "side"])
            try await run(["checkout", "-q", "main"])
            try "dirty\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        let repo = Repository(path: dir, id: 16013)
        let app = AppStore()
        app.setRepositories([repo])
        app.selectRepository(repo)
        await app.refreshRepository(repo)
        let live = LiveGitService(repositoryPath: dir)
        let branches: [Branch]
        do {
            branches = try await live.branches()
        } catch {
            check(false, "branches threw: \(error)", test: test, failures: &failures)
            return
        }
        guard let side = branches.first(where: { $0.name == "side" }) else {
            check(false, "side branch lookup", test: test, failures: &failures)
            return
        }
        let ok = await shellCheckoutBranch(store: app, repository: repo, branch: side)
        check(ok == false, "conflicted checkout fails", test: test, failures: &failures)
        check(app.currentPopup == .localChangesOverwritten(repositoryID: repo.id, files: ["f.txt"]),
              "bespoke sheet, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
    }

    // MARK: - Canonical worktree paths

    static func testCanonicalRepoPath(_ failures: inout [Failure]) {
        let test = "canonical-path"
        let tmp = FileManager.default.temporaryDirectory.path
        let resolved = (tmp as NSString).resolvingSymlinksInPath
        check(canonicalRepoPath(tmp) == canonicalRepoPath(resolved),
              "symlink variants equal (\(tmp) vs \(resolved))",
              test: test, failures: &failures)
        let canonical = canonicalRepoPath(tmp)
        check(canonicalRepoPath(canonical) == canonical, "idempotent",
              test: test, failures: &failures)
        check((canonical as NSString).isAbsolutePath, "absolute (\(canonical))",
              test: test, failures: &failures)
    }

    /// Switching to the current repo through a symlink-resolved worktree path
    /// must not add a duplicate repository (fixture pass: `/tmp/…` stored vs
    /// `/private/tmp/…` reported by git).
    static func testShellSwitchWorktreeDedupsSymlink(_ failures: inout [Failure]) {
        let test = "switch-dedup"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task16Tests-wt-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let repo = Repository(path: dir, id: 16014)
        let app = AppStore()
        app.setRepositories([repo])
        let resolved = (dir as NSString).resolvingSymlinksInPath
        let entry = WorktreeEntry(
            path: resolved, head: "abc1234", branch: "refs/heads/main",
            type: .linked, isLocked: false, isPrunable: false)
        shellSwitchWorktree(store: app, repository: repo, worktree: entry)
        check(app.repositories.count == 1,
              "no duplicate repo (got \(app.repositories.map(\.path)))",
              test: test, failures: &failures)
    }

    // MARK: - Sync failures that map to no popup still refresh

    static func testSyncConflictRefreshesState(_ failures: inout [Failure]) async {
        let test = "sync-conflict-refresh"
        let path = FileManager.default.temporaryDirectory.path
        let repo = Repository(path: path, id: 16015)
        let main = mainBranch(upstream: "origin/main")
        let mock = mockForTip(.valid(branch: main), branches: [main], path: path)
        mock.syncFailure = GitError(
            kind: .mergeConflicts, args: ["pull", "origin"], stdout: "",
            stderr: "Automatic merge failed; fix conflicts and then commit the result.",
            exitCode: 1)
        let app = await storeServing(repo: repo, tip: .valid(branch: main), branches: [main], mock: mock)
        // New history lands after the failure is triggered: the post-failure
        // refresh (the fix) is the only path that can publish it.
        let identity = CommitIdentity(
            name: "A", email: "a@x.com",
            date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        mock.stubCommits = [Commit(
            sha: "deadbee", shortSha: "deadbee", summary: "Remote work",
            body: "", author: identity, committer: identity,
            parentSHAs: [], trailers: [])]
        await app.menuPull()
        check(app.allPopups.isEmpty, "conflicts map to no popup (got \(app.allPopups))",
              test: test, failures: &failures)
        check(app.selectedState?.recentCommits.count == 1,
              "state refreshed after conflict (got \(app.selectedState?.recentCommits.count ?? -1))",
              test: test, failures: &failures)
    }

    static func testSyncAuthFailureStillPops(_ failures: inout [Failure]) async {
        let test = "sync-auth-popup"
        let path = FileManager.default.temporaryDirectory.path
        let repo = Repository(path: path, id: 16016)
        let main = mainBranch(upstream: "origin/main")
        let mock = mockForTip(.valid(branch: main), branches: [main], path: path)
        mock.syncFailure = GitError(
            kind: .httpsAuthenticationFailed, args: ["fetch", "origin"], stdout: "",
            stderr: "fatal: Authentication failed", exitCode: 128)
        let app = await storeServing(repo: repo, tip: .valid(branch: main), branches: [main], mock: mock)
        await app.menuFetch()
        check(app.currentPopup == .genericGitAuthentication(
            remoteURL: "file:///tmp/origin.git", username: nil),
            "auth sheet preserved, got \(String(describing: app.currentPopup))",
            test: test, failures: &failures)
    }
}
