#if TESTBUILD
@testable import GitDesktop
#endif
import Foundation

// MARK: - UndoTests
// Banner undo (`shellUndoBanner` + `decideMultiCommitUndo`): true
// `reset --hard` to the recorded pre-op tip with dirty-workdir /
// branch-switched guards (port of `_undoMultiCommitOperation`).
// Same harness style as `Task14Tests`: `runAll()` returns the failure count.
// Pure guard tests need no git; the pipeline groups drive `shellUndoBanner`
// against `MockGitService` (recorded resets) plus one live cherry-pick/undo
// round-trip on a fixture repo.

@MainActor
public enum UndoTests {
    public struct Failure: Sendable {
        public var test: String
        public var message: String
    }

    private static func check(
        _ condition: Bool, _ message: String,
        test: String, failures: inout [Failure]
    ) {
        if !condition {
            failures.append(Failure(test: test, message: message))
        }
    }

    @discardableResult
    public static func runAll() async -> Int {
        var failures: [Failure] = []
        testDecideGuards(&failures)
        testRefusalMessages(&failures)
        await testUndoCherryPickResetsHard(&failures)
        await testUndoSquashResetsHard(&failures)
        await testUndoDirtyWorkdirRefuses(&failures)
        await testUndoBranchSwitchRefuses(&failures)
        await testUndoMissingRecordRefuses(&failures)
        await testUndoKindMismatchRefuses(&failures)
        await testUndoRebaseClears(&failures)
        await testLiveCherryPickUndo(&failures)
        await testLivePickChecksOutTarget(&failures)
        await testLivePickSkipsCheckoutOnTarget(&failures)
        await testLivePickDirtyBlocksCheckout(&failures)
        if failures.isEmpty {
            print("UndoTests: all tests passed")
        } else {
            print("UndoTests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Fixtures

    static func branch(
        named name: String, sha: String = "abc1234567890"
    ) -> Branch {
        Branch(
            name: name, upstream: nil,
            tip: BranchTip(sha: sha),
            type: .local, ref: "refs/heads/\(name)")
    }

    static func dirtyFile() -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(
            path: "dirty.txt", status: .modified(submoduleStatus: nil),
            selection: .fromInitialSelection(.all))
    }

    static func record(
        kind: MultiCommitOperationKind = .cherryPick,
        sha: String = "pre0000000001",
        branch: String = "feature"
    ) -> MultiCommitUndoState {
        MultiCommitUndoState(kind: kind, undoSHA: sha, branchName: branch)
    }

    // MARK: - Pure guards

    static func testDecideGuards(_ failures: inout [Failure]) {
        let test = "undo-decide"
        let tip = Tip.valid(branch: branch(named: "feature", sha: "post9999999999"))
        // Happy path.
        if case .proceed(let out) = decideMultiCommitUndo(
            record: record(), expectedKind: .cherryPick, tip: tip, hasLocalChanges: false) {
            check(out.undoSHA == "pre0000000001", "record passes through",
                  test: test, failures: &failures)
        } else {
            check(false, "clean same-branch proceeds", test: test, failures: &failures)
        }
        // No record.
        check(decideMultiCommitUndo(
            record: nil, expectedKind: .cherryPick, tip: tip, hasLocalChanges: false)
            == .refuse(reason: .noUndoInfo(kind: .cherryPick)), "nil record refuses",
              test: test, failures: &failures)
        // Kind mismatch reads as no undo info for the banner's operation.
        check(decideMultiCommitUndo(
            record: record(kind: .squash), expectedKind: .cherryPick,
            tip: tip, hasLocalChanges: false)
            == .refuse(reason: .noUndoInfo(kind: .cherryPick)), "mismatch refuses",
              test: test, failures: &failures)
        // Dirty workdir blocks even with a valid record.
        check(decideMultiCommitUndo(
            record: record(), expectedKind: .cherryPick, tip: tip, hasLocalChanges: true)
            == .refuse(reason: .dirtyWorkdir(kind: .cherryPick)), "dirty refuses",
              test: test, failures: &failures)
        // Branch switch blocks.
        let other = Tip.valid(branch: branch(named: "main", sha: "post9999999999"))
        check(decideMultiCommitUndo(
            record: record(), expectedKind: .cherryPick, tip: other, hasLocalChanges: false)
            == .refuse(reason: .branchSwitched(kind: .cherryPick, expectedBranch: "feature")),
              "switched refuses", test: test, failures: &failures)
        // Detached / unborn / unknown tips are not the recorded branch.
        for bad in [Tip.detached(currentSha: "post9999999999"), .unborn(ref: "refs/heads/feature"), .unknown] {
            check(decideMultiCommitUndo(
                record: record(), expectedKind: .cherryPick, tip: bad, hasLocalChanges: false)
                == .refuse(reason: .branchSwitched(kind: .cherryPick, expectedBranch: "feature")),
                  "non-valid tip refuses (\(bad))", test: test, failures: &failures)
        }
        // Empty SHA cannot reset.
        check(decideMultiCommitUndo(
            record: record(sha: ""), expectedKind: .cherryPick, tip: tip, hasLocalChanges: false)
            == .refuse(reason: .undeterminedSHA(kind: .cherryPick)), "empty SHA refuses",
              test: test, failures: &failures)
        // Guard order: dirty beats branch switch (mirrors the reference).
        check(decideMultiCommitUndo(
            record: record(), expectedKind: .cherryPick, tip: other, hasLocalChanges: true)
            == .refuse(reason: .dirtyWorkdir(kind: .cherryPick)), "dirty first",
              test: test, failures: &failures)
    }

    static func testRefusalMessages(_ failures: inout [Failure]) {
        let test = "undo-messages"
        check(MultiCommitUndoRefusal.noUndoInfo(kind: .squash).message.contains("no undo information"),
              "no-info copy", test: test, failures: &failures)
        check(MultiCommitUndoRefusal.dirtyWorkdir(kind: .cherryPick).message.contains("local changes"),
              "dirty copy", test: test, failures: &failures)
        check(MultiCommitUndoRefusal.branchSwitched(kind: .reorder, expectedBranch: "main").message.contains("main"),
              "switched names branch", test: test, failures: &failures)
        check(MultiCommitUndoRefusal.undeterminedSHA(kind: .squash).message.contains("reset"),
              "sha copy", test: test, failures: &failures)
    }

    // MARK: - Mock pipeline

    /// AppStore serving `mock`, selected on `repo` with `tip`/`files`.
    /// Mock stubs mirror the published state so the select-triggered
    /// background refresh converges instead of racing the setup.
    private static func storeServing(
        repo: Repository,
        tipBranch: Branch,
        files: [WorkingDirectoryFileChange],
        record recordValue: MultiCommitUndoState?,
        banner: Banner
    ) async -> (AppStore, MockGitService) {
        let mock = MockGitService(repositoryPath: repo.path)
        mock.stubStatus = RepositoryStatus(
            headers: StatusParser.StatusHeaders(
                currentBranch: tipBranch.name,
                currentUpstreamBranch: tipBranch.upstream,
                currentTip: tipBranch.tip.sha,
                aheadBehind: nil),
            workingDirectory: .fromFiles(files))
        mock.stubBranches = [tipBranch]
        mock.stubRemotes = []
        mock.stubCommits = []
        let app = AppStore()
        app.setRepositories([repo])
        app.makeService = { _ in mock }
        app.selectRepository(repo)
        var state = RepositoryState(repository: repo)
        state.workingDirectory = .fromFiles(files)
        state.tip = .valid(branch: tipBranch)
        state.branches = [tipBranch]
        app.updateRepositoryState(state)
        if let recordValue {
            app.multiCommitUndoStates[repo.hash] = recordValue
        }
        app.setBanner(banner)
        // Settle the select-triggered refresh (stubs match, so it converges).
        await app.refreshRepository(repo)
        return (app, mock)
    }

    private static func errorMessages(_ app: AppStore) -> [String] {
        app.allPopups.compactMap {
            if case .error(let message) = $0 { return message }
            return nil
        }
    }

    static func testUndoCherryPickResetsHard(_ failures: inout [Failure]) async {
        let test = "undo-pick"
        let repo = Repository(path: "/tmp/undo-pick", id: 1501)
        let tip = branch(named: "feature", sha: "post9999999999")
        let banner = Banner.successfulCherryPick(
            targetBranchName: "feature", count: 2, actionToken: UUID())
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [],
            record: record(sha: "pre0000000001"), banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.count == 1
                && mock.resets.first?.mode == .hard
                && mock.resets.first?.ref == "pre0000000001",
              "reset --hard pre-op sha, got \(mock.resets)",
              test: test, failures: &failures)
        check(app.currentBanner == .cherryPickUndone(targetBranchName: "feature", countCherryPicked: 2),
              "undone banner, got \(String(describing: app.currentBanner))",
              test: test, failures: &failures)
        check(app.multiCommitUndoStates[repo.hash] == nil, "record consumed",
              test: test, failures: &failures)
        check(errorMessages(app).isEmpty, "no error, got \(errorMessages(app))",
              test: test, failures: &failures)
    }

    static func testUndoSquashResetsHard(_ failures: inout [Failure]) async {
        let test = "undo-squash"
        let repo = Repository(path: "/tmp/undo-squash", id: 1502)
        let tip = branch(named: "feature", sha: "post9999999999")
        let banner = Banner.successfulSquash(count: 3, actionToken: UUID())
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [],
            record: record(kind: .squash, sha: "pre0000000001"), banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.count == 1 && mock.resets.first?.ref == "pre0000000001",
              "squash resets, got \(mock.resets)",
              test: test, failures: &failures)
        check(app.currentBanner == .squashUndone(commitsCount: 3),
              "squash undone, got \(String(describing: app.currentBanner))",
              test: test, failures: &failures)
    }

    static func testUndoDirtyWorkdirRefuses(_ failures: inout [Failure]) async {
        let test = "undo-dirty"
        let repo = Repository(path: "/tmp/undo-dirty", id: 1503)
        let tip = branch(named: "feature", sha: "post9999999999")
        let banner = Banner.successfulCherryPick(
            targetBranchName: "feature", count: 1, actionToken: UUID())
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [dirtyFile()],
            record: record(), banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.isEmpty, "no reset when dirty, got \(mock.resets)",
              test: test, failures: &failures)
        check(errorMessages(app).joined().contains("local changes"),
              "dirty error, got \(errorMessages(app))",
              test: test, failures: &failures)
        check(app.currentBanner == banner, "banner stays",
              test: test, failures: &failures)
        check(app.multiCommitUndoStates[repo.hash] != nil, "record kept",
              test: test, failures: &failures)
    }

    static func testUndoBranchSwitchRefuses(_ failures: inout [Failure]) async {
        let test = "undo-switched"
        let repo = Repository(path: "/tmp/undo-switched", id: 1504)
        let tip = branch(named: "main", sha: "other1111111")
        let banner = Banner.successfulCherryPick(
            targetBranchName: "feature", count: 1, actionToken: UUID())
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [],
            record: record(), banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.isEmpty, "no reset after switch, got \(mock.resets)",
              test: test, failures: &failures)
        check(errorMessages(app).joined().contains("feature"),
              "switch error names branch, got \(errorMessages(app))",
              test: test, failures: &failures)
        check(app.currentBanner == banner, "banner stays",
              test: test, failures: &failures)
    }

    static func testUndoMissingRecordRefuses(_ failures: inout [Failure]) async {
        let test = "undo-no-record"
        let repo = Repository(path: "/tmp/undo-no-record", id: 1505)
        let tip = branch(named: "feature", sha: "post9999999999")
        let banner = Banner.successfulSquash(count: 1, actionToken: UUID())
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [],
            record: nil, banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.isEmpty, "no reset without record",
              test: test, failures: &failures)
        check(errorMessages(app).joined().contains("no undo information"),
              "no-info error, got \(errorMessages(app))",
              test: test, failures: &failures)
    }

    static func testUndoKindMismatchRefuses(_ failures: inout [Failure]) async {
        let test = "undo-mismatch"
        let repo = Repository(path: "/tmp/undo-mismatch", id: 1506)
        let tip = branch(named: "feature", sha: "post9999999999")
        let banner = Banner.successfulCherryPick(
            targetBranchName: "feature", count: 1, actionToken: UUID())
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [],
            record: record(kind: .squash), banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.isEmpty, "no reset on mismatch",
              test: test, failures: &failures)
        check(!errorMessages(app).isEmpty, "mismatch explains, got \(errorMessages(app))",
              test: test, failures: &failures)
    }

    static func testUndoRebaseClears(_ failures: inout [Failure]) async {
        let test = "undo-rebase"
        let repo = Repository(path: "/tmp/undo-rebase", id: 1507)
        let tip = branch(named: "feature", sha: "post9999999999")
        let banner = Banner.successfulRebase(targetBranch: "feature", baseBranch: "main")
        let (app, mock) = await storeServing(
            repo: repo, tipBranch: tip, files: [],
            record: record(kind: .rebase), banner: banner)
        await shellUndoBanner(store: app, banner: banner)
        check(mock.resets.isEmpty, "rebase never resets",
              test: test, failures: &failures)
        check(app.currentBanner == nil, "rebase clears",
              test: test, failures: &failures)
    }

    // MARK: - Live cherry-pick target checkout

    /// Fixture: `main` at B ("a\nb\n"), `feature` at A ("a\n"), checked out
    /// on `main`. Returns the dir plus both tip SHAs.
    static func makeTwoBranchFixture() async throws -> (dir: String, shaA: String, shaB: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoTests-pick-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func run(_ args: [String]) async throws -> String {
            let result = try await GitProcess.run(args, workingDirectory: dir)
            guard result.exitCode == 0 else {
                throw GitError(
                    kind: parseGitError(result.stderrString),
                    args: args, stdout: result.stdoutString,
                    stderr: result.stderrString, exitCode: result.exitCode)
            }
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await run(["-c", "init.defaultBranch=main", "init"])
        try await run(["config", "user.name", "Undo Tests"])
        try await run(["config", "user.email", "undo@example.com"])
        try "a\n".write(
            toFile: (dir as NSString).appendingPathComponent("file.txt"),
            atomically: true, encoding: .utf8)
        try await run(["add", "--", "file.txt"])
        try await run(["commit", "-m", "A"])
        let shaA = try await run(["rev-parse", "HEAD"])
        try await run(["checkout", "-qb", "feature"])
        try await run(["checkout", "-q", "main"])
        try "a\nb\n".write(
            toFile: (dir as NSString).appendingPathComponent("file.txt"),
            atomically: true, encoding: .utf8)
        try await run(["add", "--", "file.txt"])
        try await run(["commit", "-m", "B"])
        let shaB = try await run(["rev-parse", "HEAD"])
        return (dir, shaA, shaB)
    }

    static func localBranch(named name: String, sha: String) -> Branch {
        Branch(name: name, upstream: nil, tip: BranchTip(sha: sha),
               type: .local, ref: "refs/heads/\(name)")
    }

    /// Drop onto a non-checked-out branch: the seam checks it out first, so
    /// the pick (and the undo record) land on the target — never on HEAD.
    static func testLivePickChecksOutTarget(_ failures: inout [Failure]) async {
        let test = "live-pick-checkout"
        let dir: String
        let shaA: String
        let shaB: String
        do {
            (dir, shaA, shaB) = try await makeTwoBranchFixture()
        } catch {
            check(false, "fixture failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let repo = Repository(path: dir, id: 1520)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            let ok = await shellCherryPickCommits(
                store: app, repository: repo,
                targetBranch: localBranch(named: "feature", sha: shaA),
                shas: [shaB])
            check(ok, "pick onto feature succeeds", test: test, failures: &failures)
            func rev(_ args: [String]) async throws -> String {
                try await GitProcess.run(args, workingDirectory: dir).stdoutString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let head = try await rev(["rev-parse", "HEAD"])
            let content = (try? String(
                contentsOfFile: (dir as NSString).appendingPathComponent("file.txt"),
                encoding: .utf8)) ?? ""
            // The pick must advance feature with B's content; SHA inequality
            // alone can't distinguish a no-op pick from a real one.
            check(head != shaA && content == "a\nb\n",
                  "feature advanced with B's content (head \(head) vs A \(shaA), content \(content.debugDescription))",
                  test: test, failures: &failures)
            let branch = try await GitProcess.run(
                ["rev-parse", "--abbrev-ref", "HEAD"], workingDirectory: dir).stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            check(branch == "feature", "on feature, got \(branch)",
                  test: test, failures: &failures)
            if case .successfulCherryPick(let target, let count, _) = app.currentBanner {
                check(target == "feature" && count == 1,
                      "banner names target (got \(target) x\(count))",
                      test: test, failures: &failures)
            } else {
                check(false, "success banner, got \(String(describing: app.currentBanner))",
                      test: test, failures: &failures)
            }
            check(app.multiCommitUndoStates[repo.hash]?.branchName == "feature"
                    && app.multiCommitUndoStates[repo.hash]?.undoSHA == shaA,
                  "undo covers target tip (got \(String(describing: app.multiCommitUndoStates[repo.hash])))",
                  test: test, failures: &failures)
            // And the recorded undo restores the target branch.
            if let banner = app.currentBanner {
                await shellUndoBanner(store: app, banner: banner)
                let undone = try await GitProcess.run(["rev-parse", "HEAD"], workingDirectory: dir).stdoutString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                check(undone == shaA, "undo restores feature to A (got \(undone))",
                      test: test, failures: &failures)
            } else {
                check(false, "no banner to undo", test: test, failures: &failures)
            }
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    /// Drop onto the checked-out branch: no checkout churn, pick applies.
    static func testLivePickSkipsCheckoutOnTarget(_ failures: inout [Failure]) async {
        let test = "live-pick-no-checkout"
        let dir: String
        let shaA: String
        let shaB: String
        do {
            (dir, shaA, shaB) = try await makeTwoBranchFixture()
        } catch {
            check(false, "fixture failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            _ = try await GitProcess.run(["checkout", "-q", "feature"], workingDirectory: dir)
            let repo = Repository(path: dir, id: 1521)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            let ok = await shellCherryPickCommits(
                store: app, repository: repo,
                targetBranch: localBranch(named: "feature", sha: shaA),
                shas: [shaB])
            check(ok, "pick onto current succeeds", test: test, failures: &failures)
            check(app.multiCommitUndoStates[repo.hash]?.branchName == "feature",
                  "undo recorded (got \(String(describing: app.multiCommitUndoStates[repo.hash])))",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    /// Dirty workdir blocking the target checkout aborts before any pick:
    /// bespoke sheet, no banner, no undo record, HEAD untouched.
    static func testLivePickDirtyBlocksCheckout(_ failures: inout [Failure]) async {
        let test = "live-pick-dirty"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoTests-dirty-\(UUID().uuidString)").path
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
            try await run(["config", "user.name", "Undo Tests"])
            try await run(["config", "user.email", "undo@example.com"])
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
            let repo = Repository(path: dir, id: 1522)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            let side = localBranch(named: "side", sha: "side")
            let ok = await shellCherryPickCommits(
                store: app, repository: repo, targetBranch: side, shas: ["deadbee"])
            check(!ok, "dirty checkout aborts the pick", test: test, failures: &failures)
            check(app.currentPopup == .localChangesOverwritten(repositoryID: repo.id, files: ["f.txt"]),
                  "bespoke sheet, got \(String(describing: app.currentPopup))",
                  test: test, failures: &failures)
            check(app.currentBanner == nil, "no banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
            check(app.multiCommitUndoStates[repo.hash] == nil, "no undo record",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    // MARK: - Live (real cherry-pick + undo on a fixture repo)

    static func testLiveCherryPickUndo(_ failures: inout [Failure]) async {
        let test = "live-undo-pick"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoTests-\(UUID().uuidString)").path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            check(false, "temp dir failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func run(_ args: [String]) async throws -> String {
            let result = try await GitProcess.run(args, workingDirectory: dir)
            guard result.exitCode == 0 else {
                throw GitError(
                    kind: parseGitError(result.stderrString),
                    args: args, stdout: result.stdoutString,
                    stderr: result.stderrString, exitCode: result.exitCode)
            }
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try await run(["-c", "init.defaultBranch=main", "init"])
            try await run(["config", "user.name", "Undo Tests"])
            try await run(["config", "user.email", "undo@example.com"])
            try "a\n".write(
                toFile: (dir as NSString).appendingPathComponent("file.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "file.txt"])
            try await run(["commit", "-m", "A"])
            let shaA = try await run(["rev-parse", "HEAD"])
            try await run(["checkout", "-b", "feature"])
            try await run(["checkout", "main"])
            try "a\nb\n".write(
                toFile: (dir as NSString).appendingPathComponent("file.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "file.txt"])
            try await run(["commit", "-m", "B"])
            let shaB = try await run(["rev-parse", "HEAD"])
            try await run(["checkout", "feature"])
            // Real cherry-pick of B onto feature (mirrors dropCommits).
            let service = LiveMultiCommitService()
            let picked = try await service.cherryPick(repositoryPath: dir, shas: [shaB])
            guard picked == .completedWithoutError else {
                check(false, "pick failed: \(picked)", test: test, failures: &failures)
                return
            }
            let repo = Repository(path: dir, id: 1510)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            guard let state = app.selectedState,
                  case .valid(let current) = state.tip,
                  current.name == "feature"
            else {
                check(false, "on feature", test: test, failures: &failures)
                return
            }
            app.multiCommitUndoStates[repo.hash] = MultiCommitUndoState(
                kind: .cherryPick, undoSHA: shaA, branchName: "feature")
            let banner = Banner.successfulCherryPick(
                targetBranchName: "feature", count: 1, actionToken: UUID())
            app.setBanner(banner)
            await shellUndoBanner(store: app, banner: banner)
            let head = try await run(["rev-parse", "HEAD"])
            check(head == shaA, "HEAD back at A, got \(head)",
                  test: test, failures: &failures)
            let content = (try? String(
                contentsOfFile: (dir as NSString).appendingPathComponent("file.txt"),
                encoding: .utf8)) ?? ""
            check(content == "a\n", "workdir reverted, got \(content.debugDescription)",
                  test: test, failures: &failures)
            check(app.currentBanner == .cherryPickUndone(targetBranchName: "feature", countCherryPicked: 1),
                  "undone banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
            check(app.multiCommitUndoStates[repo.hash] == nil, "record consumed",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }
}
