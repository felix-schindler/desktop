#if TESTBUILD
@testable import GitDesktop
#endif
import Foundation

// MARK: - Task14Tests
// Task 14 menu/toolbar action subscriptions. Same harness style as
// `GitStoreTests` (no test bundle; `runAll()` returns the failure count).
// Pure routing/resolution groups run without git; the pipeline groups drive
// `AppStore` menu handlers against `MockGitService` (recorded ops) plus one
// live `menuStashAll` round-trip on a fixture repo.
//
// Covers PLAN.md Task 14 accept: every `Task10Tests.testMenuInventory` item
// executes its real op (or its confirm) — push/pull/fetch record sync ops,
// stash-all stages + stashes, discard-all/rename/delete/tag/merge/rebase
// post their confirms, and disabled states match `Commands` item-for-item.

@MainActor
public enum Task14Tests {
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
        testRoutingInventory(&failures)
        testEnabledStates(&failures)
        testSyncTarget(&failures)
        testUpdateFromDefaultTarget(&failures)
        testDiscardDeleteTagStash(&failures)
        testToolbarMapping(&failures)
        await testPushPullFetchRecordOps(&failures)
        await testPushNoRemoteRoutesToSettings(&failures)
        await testPushFailureMapping(&failures)
        await testStashAll(&failures)
        await testConfirms(&failures)
        await testLiveStashAll(&failures)
        if failures.isEmpty {
            print("Task14Tests: all tests passed")
        } else {
            print("Task14Tests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Fixtures

    private static func mainBranch(sha: String = "abc1234567890", upstream: String? = "origin/main") -> Branch {
        Branch(
            name: "main", upstream: upstream,
            tip: BranchTip(sha: sha),
            type: .local, ref: "refs/heads/main")
    }

    private static func file(path: String) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(
            path: path, status: .modified(submoduleStatus: nil),
            selection: .fromInitialSelection(.all))
    }

    private static func state(
        repo: Repository,
        files: [WorkingDirectoryFileChange] = [WorkingDirectoryFileChange](),
        tip: Tip? = nil,
        branches: [Branch]? = nil,
        remote: Remote? = Remote(name: "origin", url: "https://example.com/r.git"),
        remotes: [Remote]? = nil,
        aheadBehind: AheadBehind? = AheadBehind(ahead: 1, behind: 0),
        defaultBranch: Branch?? = .some(nil)
    ) -> RepositoryState {
        let main = mainBranch()
        var s = RepositoryState(repository: repo)
        s.workingDirectory = .fromFiles(files)
        s.tip = tip ?? .valid(branch: main)
        s.branches = branches ?? [main]
        s.remote = remote
        s.remotes = remotes ?? (remote.map { [$0] } ?? [])
        s.aheadBehind = aheadBehind
        // Default to no default branch unless the caller opts in; most menu
        // guards must not depend on it.
        if case .some(let def) = defaultBranch { s.defaultBranch = def }
        return s
    }

    private static func mockForState(_ state: RepositoryState) -> MockGitService {
        let mock = MockGitService(repositoryPath: state.repository.path)
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
                    currentBranch: nil, currentUpstreamBranch: nil,
                    currentTip: sha, aheadBehind: state.aheadBehind)
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
        mock.stubStatus = RepositoryStatus(
            headers: headers, workingDirectory: state.workingDirectory)
        mock.stubBranches = state.branches
        mock.stubRemotes = state.remotes
        mock.stubCommits = []
        return mock
    }

    /// Store whose pipeline serves `mock`, refreshed + selected on `repo`.
    private static func storeServing(
        repo: Repository, state: RepositoryState, mock: MockGitService
    ) async -> AppStore {
        let app = AppStore()
        app.setRepositories([repo])
        app.makeService = { _ in mock }
        await app.refreshRepository(repo)
        app.selectRepository(repo)
        return app
    }

    // MARK: - Routing inventory

    static func testRoutingInventory(_ failures: inout [Failure]) {
        let test = "routing-inventory"
        // The router owns exactly the subscriber-less actions from PLAN Task 14
        // (plus createBranch for future notification posters).
        let routerActions: Set<GitDesktopMenuAction> = [
            .push, .pull, .fetch,
            .stashAllChanges, .updateFromDefault,
            .mergeIntoCurrent, .squashAndMerge, .rebaseCurrent,
            .createTag, .createBranch, .renameBranch, .deleteBranch,
            .discardAllChanges,
        ]
        for action in GitDesktopMenuAction.allCases {
            let owner = ownerOfMenuAction(action)
            if routerActions.contains(action) {
                check(owner == .router, "\(action.rawValue) owned by router, got \(owner)",
                      test: test, failures: &failures)
            }
        }
        let routerCount = GitDesktopMenuAction.allCases.filter {
            ownerOfMenuAction($0) == .router
        }.count
        check(routerCount == routerActions.count,
              "router owns \(routerCount), expected \(routerActions.count)",
              test: test, failures: &failures)
        // Navigation stays with RepositoryView (compare opens History).
        for action: GitDesktopMenuAction in [.showChanges, .showHistory, .goToCommitMessage, .compareToBranch] {
            check(ownerOfMenuAction(action) == .repositoryView,
                  "\(action.rawValue) → repositoryView", test: test, failures: &failures)
        }
        // Text actions stay with the focused views.
        for action: GitDesktopMenuAction in [.findInDiff, .selectAll] {
            check(ownerOfMenuAction(action) == .focusedView,
                  "\(action.rawValue) → focusedView", test: test, failures: &failures)
        }
        // The remainder is explicitly deferred to Tasks 12–13 — no silent gaps.
        let deferred: Set<GitDesktopMenuAction> = [
            .chooseRepository, .showBranches, .showWorktrees,
            .toggleStashedChanges, .toggleChangesFilter,
            .increaseResizableWidth, .decreaseResizableWidth,
        ]
        for action in deferred {
            check(ownerOfMenuAction(action) == .deferred,
                  "\(action.rawValue) → deferred", test: test, failures: &failures)
        }
        let total = GitDesktopMenuAction.allCases.count
        check(total == routerActions.count + 4 + 2 + deferred.count,
              "all \(total) actions classified", test: test, failures: &failures)
    }

    // MARK: - Enabled states (mirror Commands disabled modifiers)

    static func testEnabledStates(_ failures: inout [Failure]) {
        let test = "enabled-states"
        let repoScoped: [GitDesktopMenuAction] = [
            .push, .pull, .fetch,
            .createBranch, .renameBranch, .deleteBranch,
            .discardAllChanges, .stashAllChanges,
            .updateFromDefault, .compareToBranch,
            .mergeIntoCurrent, .squashAndMerge, .rebaseCurrent,
            .createTag,
        ]
        for action in repoScoped {
            check(isMenuActionEnabled(action, hasSelection: false) == false,
                  "\(action.rawValue) disabled without repo", test: test, failures: &failures)
            check(isMenuActionEnabled(action, hasSelection: true) == true,
                  "\(action.rawValue) enabled with repo", test: test, failures: &failures)
        }
        // View/Edit items are never disabled by Commands.
        for action in GitDesktopMenuAction.allCases where !repoScoped.contains(action) {
            check(isMenuActionEnabled(action, hasSelection: false) == true,
                  "\(action.rawValue) stays enabled", test: test, failures: &failures)
        }
    }

    // MARK: - Pure resolvers

    static func testSyncTarget(_ failures: inout [Failure]) {
        let test = "sync-target"
        let repo = Repository(path: "/tmp/t14", id: 1401)
        let origin = Remote(name: "origin", url: "https://example.com/r.git")
        let fork = Remote(name: "fork", url: "https://example.com/f.git")
        // Current remote wins (upstream remote), else default.
        var s = state(repo: repo, remote: origin, remotes: [origin, fork])
        check(resolveMenuSyncTarget(state: s)?.remote == origin, "state.remote wins",
              test: test, failures: &failures)
        check(resolveMenuSyncTarget(state: s)?.branch?.name == "main", "branch main",
              test: test, failures: &failures)
        s = state(repo: repo, remote: nil, remotes: [fork, origin])
        check(resolveMenuSyncTarget(state: s)?.remote == origin, "falls back to origin",
              test: test, failures: &failures)
        s = state(repo: repo, remote: nil, remotes: [fork])
        check(resolveMenuSyncTarget(state: s)?.remote == fork, "falls back to first",
              test: test, failures: &failures)
        s = state(repo: repo, remote: nil, remotes: [])
        check(resolveMenuSyncTarget(state: s) == nil, "nil without remotes",
              test: test, failures: &failures)
        s = state(repo: repo, tip: .detached(currentSha: "deadbee"))
        check(resolveMenuSyncTarget(state: s)?.branch == nil, "detached → no branch",
              test: test, failures: &failures)
        check(resolveMenuSyncTarget(state: s)?.remote == origin, "detached keeps remote",
              test: test, failures: &failures)
        check(syncAvailabilityMessage(operation: "Pull", state: s).contains("detached"),
              "pull-detached message", test: test, failures: &failures)
        let unbornState = state(repo: repo, tip: .unborn(ref: "refs/heads/main"))
        check(syncAvailabilityMessage(operation: "Push", state: unbornState).contains("first commit"),
              "push-unborn message", test: test, failures: &failures)
    }

    static func testUpdateFromDefaultTarget(_ failures: inout [Failure]) {
        let test = "update-from-default"
        let repo = Repository(path: "/tmp/t14", id: 1402)
        let main = mainBranch()
        let feature = Branch(
            name: "feature", upstream: nil,
            tip: BranchTip(sha: "def9876"), type: .local, ref: "refs/heads/feature")
        var s = state(
            repo: repo, tip: .valid(branch: feature),
            branches: [main, feature], defaultBranch: .some(main))
        check(updateFromDefaultTarget(state: s)?.name == "main", "feature → main",
              test: test, failures: &failures)
        s = state(
            repo: repo, tip: .valid(branch: main),
            branches: [main], defaultBranch: .some(main))
        check(updateFromDefaultTarget(state: s) == nil, "already on default",
              test: test, failures: &failures)
        s = state(repo: repo, defaultBranch: .some(nil))
        check(updateFromDefaultTarget(state: s) == nil, "no default → nil",
              test: test, failures: &failures)
        s = state(
            repo: repo, tip: .detached(currentSha: "deadbee"),
            defaultBranch: .some(main))
        check(updateFromDefaultTarget(state: s) == nil, "detached → nil",
              test: test, failures: &failures)
    }

    static func testDiscardDeleteTagStash(_ failures: inout [Failure]) {
        let test = "resolvers"
        let repo = Repository(path: "/tmp/t14", id: 1403)
        let s = state(repo: repo, files: [file(path: "a.txt"), file(path: "b.txt")])
        check(menuDiscardAllFileIDs(state: s).count == 2, "discard ids",
              test: test, failures: &failures)
        check(menuDeleteBranchExistsOnRemote(state: s) == true, "aheadBehind → on remote",
              test: test, failures: &failures)
        let local = state(repo: repo, aheadBehind: nil)
        check(menuDeleteBranchExistsOnRemote(state: local) == false, "no aheadBehind → local",
              test: test, failures: &failures)
        check(menuCreateTagTargetSHA(state: s) == "abc1234567890", "tag targets tip",
              test: test, failures: &failures)
        let detached = state(repo: repo, tip: .detached(currentSha: "deadbee"))
        check(menuCreateTagTargetSHA(state: detached) == "deadbee", "tag targets detached SHA",
              test: test, failures: &failures)
        let unborn = state(repo: repo, tip: .unborn(ref: "refs/heads/main"))
        check(menuCreateTagTargetSHA(state: unborn) == nil, "unborn → nil",
              test: test, failures: &failures)
        check(menuStashBranchName(state: s) == "main", "stash branch",
              test: test, failures: &failures)
        check(menuStashBranchName(state: detached) == nil, "detached → nil branch",
              test: test, failures: &failures)
    }

    static func testToolbarMapping(_ failures: inout [Failure]) {
        let test = "toolbar-mapping"
        let tip = Tip.valid(branch: mainBranch())
        func viewState(_ action: ToolbarPushPullAction) -> PushPullViewState {
            PushPullViewState(action: action)
        }
        check(toolbarSyncRequest(for: viewState(.push(remote: "origin"))) == .push,
              "toolbar push", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.pull(remote: "origin", rebase: false))) == .pull,
              "toolbar pull", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.fetch(remote: "origin"))) == .fetch,
              "toolbar fetch", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.forcePush(remote: "origin"))) == .forcePush(remote: "origin"),
              "toolbar force-push", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.publishRepository)) == .publishSetup,
              "toolbar publish repo", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.publishBranch)) == .publishSetup,
              "toolbar publish branch", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.progress(title: "Pushing"))) == .none,
              "toolbar progress", test: test, failures: &failures)
        check(toolbarSyncRequest(for: viewState(.detached(rebaseInProgress: false))) == .none,
              "toolbar detached", test: test, failures: &failures)
        _ = tip
    }

    // MARK: - Pipeline integration (Mock)

    static func testPushPullFetchRecordOps(_ failures: inout [Failure]) async {
        let test = "sync-ops"
        let repo = Repository(path: FileManager.default.temporaryDirectory.path, id: 1410)
        let s = state(repo: repo, files: [file(path: "a.txt")])
        let mock = mockForState(s)
        let app = await storeServing(repo: repo, state: s, mock: mock)
        await app.menuPush()
        await app.menuPull()
        await app.menuFetch()
        check(mock.pushedBranches.count == 1, "one push, got \(mock.pushedBranches.count)",
              test: test, failures: &failures)
        if let push = mock.pushedBranches.first {
            check(push.remote == "origin" && push.localBranch == "main" && push.remoteBranch == "main",
                  "push origin main→main, got \(push)", test: test, failures: &failures)
        }
        check(mock.pulledRemotes == ["origin"], "pull origin, got \(mock.pulledRemotes)",
              test: test, failures: &failures)
        check(mock.fetchedRemotes == ["origin"], "fetch origin, got \(mock.fetchedRemotes)",
              test: test, failures: &failures)
        let hasError = app.allPopups.contains { if case .error = $0 { return true }; return false }
        check(!hasError, "no .error on success (got \(app.allPopups))",
              test: test, failures: &failures)
    }

    static func testPushNoRemoteRoutesToSettings(_ failures: inout [Failure]) async {
        let test = "sync-no-remote"
        let repo = Repository(path: FileManager.default.temporaryDirectory.path, id: 1411)
        let develop = Branch(
            name: "develop", upstream: nil,
            tip: BranchTip(sha: "2222222"), type: .local, ref: "refs/heads/develop")
        let s = state(
            repo: repo, tip: .valid(branch: develop), branches: [develop],
            remote: nil, remotes: [], aheadBehind: nil)
        let mock = mockForState(s)
        let app = await storeServing(repo: repo, state: s, mock: mock)
        await app.menuPush()
        check(mock.pushedBranches.isEmpty, "no push without remote",
              test: test, failures: &failures)
        check(app.currentPopup == .repositorySettings(repositoryID: repo.id, initialTab: nil),
              "push without remote → settings, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
    }

    static func testPushFailureMapping(_ failures: inout [Failure]) async {
        let test = "sync-error-map"
        let repo = Repository(path: FileManager.default.temporaryDirectory.path, id: 1412)
        let s = state(repo: repo)
        let mock = mockForState(s)
        mock.syncFailure = GitError(
            kind: .pushNotFastForward, args: ["push", "origin"], stdout: "",
            stderr: "rejected (non-fast-forward)", exitCode: 1)
        let app = await storeServing(repo: repo, state: s, mock: mock)
        await app.menuPush()
        check(app.currentPopup == .pushNeedsPull(repositoryID: repo.id),
              "push-rejected → pushNeedsPull, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
    }

    static func testStashAll(_ failures: inout [Failure]) async {
        let test = "stash-all"
        let repo = Repository(path: FileManager.default.temporaryDirectory.path, id: 1413)
        let s = state(repo: repo, files: [file(path: "a.txt"), file(path: "b.txt")])
        let mock = mockForState(s)
        let app = await storeServing(repo: repo, state: s, mock: mock)
        await app.menuStashAll()
        check(Set(mock.stagedPaths) == ["a.txt", "b.txt"],
              "stages all before stash, got \(mock.stagedPaths)",
              test: test, failures: &failures)
        check(mock.stubStashes.count == 1, "one stash created, got \(mock.stubStashes.count)",
              test: test, failures: &failures)
        // Empty working directory is a silent no-op (menu-update.ts disables it).
        mock.stubStashes.removeAll()
        let clean = state(repo: repo, files: [])
        let cleanMock = mockForState(clean)
        let cleanApp = await storeServing(repo: repo, state: clean, mock: cleanMock)
        await cleanApp.menuStashAll()
        check(cleanMock.stubStashes.isEmpty, "empty WD → no stash",
              test: test, failures: &failures)
    }

    static func testConfirms(_ failures: inout [Failure]) async {
        let test = "confirms"
        let repo = Repository(path: FileManager.default.temporaryDirectory.path, id: 1414)
        let main = mainBranch()
        let feature = Branch(
            name: "feature", upstream: nil,
            tip: BranchTip(sha: "def9876"), type: .local, ref: "refs/heads/feature")
        let s = state(
            repo: repo, files: [file(path: "a.txt")],
            tip: .valid(branch: feature), branches: [main, feature],
            defaultBranch: .some(main))
        let mock = mockForState(s)
        let app = await storeServing(repo: repo, state: s, mock: mock)

        app.menuDiscardAll()
        if case .confirmDiscardChanges(let id, let fileIDs, _, let all) = app.currentPopup {
            check(id == repo.id && fileIDs.count == 1 && all == true, "discard-all confirm",
                  test: test, failures: &failures)
        } else {
            check(false, "discard-all → confirm, got \(String(describing: app.currentPopup))",
                  test: test, failures: &failures)
        }
        app.closeAllPopups()
        app.menuRenameBranch()
        check(app.currentPopup == .renameBranch(repositoryID: repo.id, branchRef: "refs/heads/feature"),
              "rename → dialog, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
        app.closeAllPopups()
        app.menuDeleteBranch()
        check(app.currentPopup == .deleteBranch(
            repositoryID: repo.id, branchRef: "refs/heads/feature", existsOnRemote: true),
            "delete → confirm, got \(String(describing: app.currentPopup))",
            test: test, failures: &failures)
        app.closeAllPopups()
        app.menuCreateTag()
        check(app.currentPopup == .createTag(
            repositoryID: repo.id, targetCommitSHA: "def9876", initialName: nil),
            "tag → dialog, got \(String(describing: app.currentPopup))",
            test: test, failures: &failures)
        app.closeAllPopups()
        app.menuMerge(squash: false)
        check(app.currentPopup == .multiCommitOperation(repositoryID: repo.id),
              "merge → flow, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
        app.closeAllPopups()
        app.menuMerge(squash: true)
        check(app.currentPopup == .multiCommitOperation(repositoryID: repo.id),
              "squash-merge → flow, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
        app.closeAllPopups()
        app.menuRebase()
        check(app.currentPopup == .multiCommitOperation(repositoryID: repo.id),
              "rebase → flow, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
        app.closeAllPopups()
        app.menuUpdateFromDefault()
        check(app.currentPopup == .multiCommitOperation(repositoryID: repo.id),
              "update-from-default → flow, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
        app.closeAllPopups()
        app.menuCreateBranch()
        check(app.currentPopup == .createBranch(
            repositoryID: repo.id, initialName: nil, targetCommitSHA: nil),
            "create-branch → dialog, got \(String(describing: app.currentPopup))",
            test: test, failures: &failures)
        app.closeAllPopups()
        // No default branch → silent no-op (reference disables the item).
        let noDefault = state(repo: repo, defaultBranch: .some(nil))
        let noDefaultApp = await storeServing(
            repo: repo, state: noDefault, mock: mockForState(noDefault))
        noDefaultApp.menuUpdateFromDefault()
        check(noDefaultApp.currentPopup == nil, "no default → silent, got \(String(describing: noDefaultApp.currentPopup))",
              test: test, failures: &failures)
        // Empty working directory → silent no-op.
        let clean = state(repo: repo, files: [])
        let cleanApp = await storeServing(
            repo: repo, state: clean, mock: mockForState(clean))
        cleanApp.menuDiscardAll()
        check(cleanApp.currentPopup == nil, "empty WD → no discard confirm",
              test: test, failures: &failures)
        // Detached HEAD → no branch dialogs.
        let detached = state(repo: repo, tip: .detached(currentSha: "deadbee"))
        let detachedApp = await storeServing(
            repo: repo, state: detached, mock: mockForState(detached))
        detachedApp.menuRenameBranch()
        detachedApp.menuDeleteBranch()
        detachedApp.menuMerge(squash: false)
        detachedApp.menuRebase()
        check(detachedApp.currentPopup == nil, "detached → no branch dialogs",
              test: test, failures: &failures)
        // Non-router actions are ignored by the router (owned by views).
        app.handleMenuAction(.showHistory)
        check(true, "non-router ignored without crashing", test: test, failures: &failures)
    }

    // MARK: - Live fixture (real stash-all through the pipeline)

    static func makeLiveFixture() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task14Tests-\(UUID().uuidString)").path
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
        try await run(["config", "user.name", "Task14 Tests"])
        try await run(["config", "user.email", "task14@example.com"])
        try "hello\n".write(
            toFile: (dir as NSString).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try await run(["add", "--", "README.md"])
        try await run(["commit", "-m", "Initial commit"])
        try "hello world\n".write(
            toFile: (dir as NSString).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try "untracked\n".write(
            toFile: (dir as NSString).appendingPathComponent("new.txt"),
            atomically: true, encoding: .utf8)
        return dir
    }

    static func testLiveStashAll(_ failures: inout [Failure]) async {
        let test = "live-stash-all"
        let dir: String
        do {
            dir = try await makeLiveFixture()
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let repo = Repository(path: dir, id: 1420)
        let app = AppStore()
        app.setRepositories([repo])
        app.selectRepository(repo)
        await app.refreshRepository(repo)
        guard let before = app.selectedState, !before.workingDirectory.files.isEmpty else {
            check(false, "fixture has dirty WD", test: test, failures: &failures)
            return
        }
        await app.menuStashAll()
        do {
            let live = LiveGitService(repositoryPath: dir)
            let stashes = try await live.stashes()
            check(!stashes.entries.isEmpty, "live stash created",
                  test: test, failures: &failures)
            let status = try await live.status(includeUntracked: true)
            check(status?.workingDirectory.files.isEmpty == true,
                  "live WD clean after stash-all (got \(status?.workingDirectory.files.map(\.path) ?? []))",
                  test: test, failures: &failures)
        } catch {
            check(false, "live verify threw: \(error)", test: test, failures: &failures)
        }
    }
}
