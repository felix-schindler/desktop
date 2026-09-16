#if TESTBUILD
@testable import GitDesktop
#endif
import Foundation

// MARK: - MultiCommitTests
// Task 6 unit tests: rebase/cherry-pick progress parsers, result
// classifiers, sequencer readers, squash/reorder todo builders, drop routing
// and wizard rules. Fixtures mirror `electron/app/test/` multi-commit cases
// and the `lib/git/{rebase,cherry-pick,squash,reorder}.ts` sources.
// Same harness style as `Tests/ParserTests.swift` (no test bundle):
// `runAll()` returns the failure count.
@MainActor
public enum MultiCommitTests {
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
        testFormatRebaseValue(&failures)
        testRebaseProgressLine(&failures)
        testCherryPickProgressParser(&failures)
        testResultClassification(&failures)
        testRebaseSnapshot(&failures)
        testSequencerTodo(&failures)
        testSquashTodo(&failures)
        testReorderTodo(&failures)
        testScopeLog(&failures)
        testValidationGuards(&failures)
        testLastRetainedCommitRef(&failures)
        testCanStartOperation(&failures)
        testResolveChooseBranchInitial(&failures)
        testDropRouting(&failures)
        testKeyboardReorder(&failures)
        testBannerMapping(&failures)
        await testWarnAboutRemoteCommits(&failures)
        await testShellRebaseBranch(&failures)
        await testLiveRebaseBranch(&failures)
        await testShellSquash(&failures)
        await testShellReorder(&failures)
        await testShellContinueAbort(&failures)
        await testLiveSquash(&failures)
        await testLiveReorder(&failures)
        await testLiveContinueRebase(&failures)

        if failures.isEmpty {
            print("MultiCommitTests: all tests passed")
        } else {
            print("MultiCommitTests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Helpers

    static func oneLine(_ sha: String, _ summary: String = "") -> CommitOneLine {
        CommitOneLine(sha: sha, summary: summary.isEmpty ? "commit \(sha)" : summary)
    }

    static func testIdentity() -> CommitIdentity {
        CommitIdentity(
            name: "Ada Lovelace", email: "ada@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000), tzOffset: 0)
    }

    static func testCommit(sha: String, parents: [String] = ["parent"]) -> Commit {
        let identity = testIdentity()
        return Commit(
            sha: sha, shortSha: String(sha.prefix(7)), summary: "commit \(sha)",
            body: "", author: identity, committer: identity,
            parentSHAs: parents, trailers: [])
    }

    static func testBranch(_ name: String) -> Branch {
        Branch(name: name, upstream: nil, tip: BranchTip(sha: "abc1234"), type: .local, ref: "refs/heads/\(name)")
    }

    // MARK: - formatRebaseValue

    static func testFormatRebaseValue(_ failures: inout [Failure]) {
        let test = "format-rebase-value"
        check(formatRebaseValue(0.5) == 0.5, "0.5 unchanged", test: test, failures: &failures)
        check(formatRebaseValue(1.0 / 3.0) == 0.33, "1/3 → 0.33, got \(formatRebaseValue(1.0 / 3.0))", test: test, failures: &failures)
        check(formatRebaseValue(2.0 / 3.0) == 0.67, "2/3 → 0.67", test: test, failures: &failures)
        check(formatRebaseValue(1.5) == 1.0, "clamped to 1", test: test, failures: &failures)
        check(formatRebaseValue(-0.2) == 0.0, "clamped to 0", test: test, failures: &failures)
    }

    // MARK: - Rebase progress lines

    static func testRebaseProgressLine(_ failures: inout [Failure]) {
        let test = "rebase-progress"
        let commits = [oneLine("a", "First"), oneLine("b", "Second"), oneLine("c", "Third")]
        if let progress = parseRebaseProgressLine("Rebasing (2/3)", commits: commits) {
            check(progress.position == 2, "position 2", test: test, failures: &failures)
            check(progress.totalCommitCount == 3, "total 3", test: test, failures: &failures)
            check(progress.value == 0.67, "value 0.67, got \(progress.value)", test: test, failures: &failures)
            check(progress.currentCommitSummary == "Second", "summary Second", test: test, failures: &failures)
            check(progress.detailLine == "Commit 2 of 3", "detail line", test: test, failures: &failures)
        } else {
            check(false, "Rebasing (2/3) parses", test: test, failures: &failures)
        }
        // Unrelated git output is skipped.
        check(parseRebaseProgressLine("Auto-merging foo.ts", commits: commits) == nil, "conflict line skipped", test: test, failures: &failures)
        check(parseRebaseProgressLine("Rebasing (x/y)", commits: commits) == nil, "malformed skipped", test: test, failures: &failures)
        check(parseRebaseProgressLine(" Rebasing (1/3)", commits: commits) == nil, "leading space rejected", test: test, failures: &failures)
        // Out-of-range position yields an empty summary (mirrors `?.summary ?? ''`).
        if let progress = parseRebaseProgressLine("Rebasing (9/9)", commits: commits) {
            check(progress.currentCommitSummary.isEmpty, "empty summary fallback", test: test, failures: &failures)
        } else {
            check(false, "out-of-range still parses", test: test, failures: &failures)
        }
    }

    // MARK: - Cherry-pick progress parser

    static func testCherryPickProgressParser(_ failures: inout [Failure]) {
        let test = "cherry-pick-progress"
        let commits = [oneLine("a", "First"), oneLine("b", "Second"), oneLine("c", "Third")]
        var parser = CherryPickProgressParser(commits: commits)
        check(parser.parse(line: "  Date: today") == nil, "timestamp skipped", test: test, failures: &failures)
        if let first = parser.parse(line: "[main abc1234] First") {
            check(first.position == 1 && first.totalCommitCount == 3, "1 of 3", test: test, failures: &failures)
            check(first.value == 0.33, "value 0.33, got \(first.value)", test: test, failures: &failures)
            check(first.currentCommitSummary == "First", "summary First", test: test, failures: &failures)
        } else {
            check(false, "first pick parses", test: test, failures: &failures)
        }
        _ = parser.parse(line: "[main def5678] Second")
        if let third = parser.parse(line: "[main ghi9012] Third") {
            check(third.position == 3 && third.value == 1.0, "3 of 3 completes", test: test, failures: &failures)
        } else {
            check(false, "third pick parses", test: test, failures: &failures)
        }
        // Resuming after conflicts starts from the already-picked count.
        var resumed = CherryPickProgressParser(commits: commits, count: 2)
        if let progress = resumed.parse(line: "[main ghi9012] Third") {
            check(progress.position == 3, "resumed position 3", test: test, failures: &failures)
        } else {
            check(false, "resumed pick parses", test: test, failures: &failures)
        }
    }

    // MARK: - Result classification

    static func testResultClassification(_ failures: inout [Failure]) {
        let test = "result-classify"
        check(parseRebaseResult(exitCode: 0, stdout: "Successfully rebased", error: nil) == .completedWithoutError, "rebase success", test: test, failures: &failures)
        check(parseRebaseResult(exitCode: 0, stdout: "Current branch feature is up to date.\n", error: nil) == .alreadyUpToDate, "rebase up-to-date", test: test, failures: &failures)
        check(parseRebaseResult(exitCode: 1, stdout: "", error: .rebaseConflicts) == .conflictsEncountered, "rebase conflicts", test: test, failures: &failures)
        check(parseRebaseResult(exitCode: 1, stdout: "", error: .unresolvedConflicts) == .outstandingFilesNotStaged, "rebase outstanding", test: test, failures: &failures)
        check(parseRebaseResult(exitCode: 128, stdout: "", error: .badRevision) == nil, "rebase unknown → nil", test: test, failures: &failures)

        check(parseCherryPickResult(exitCode: 0, error: nil) == .completedWithoutError, "pick success", test: test, failures: &failures)
        check(parseCherryPickResult(exitCode: 1, error: .mergeConflicts) == .conflictsEncountered, "pick conflicts", test: test, failures: &failures)
        check(parseCherryPickResult(exitCode: 1, error: .conflictModifyDeletedInBranch) == .conflictsEncountered, "pick modify/delete", test: test, failures: &failures)
        check(parseCherryPickResult(exitCode: 1, error: .unresolvedConflicts) == .outstandingFilesNotStaged, "pick outstanding", test: test, failures: &failures)
        check(parseCherryPickResult(exitCode: 128, error: .badRevision) == nil, "pick unknown → nil", test: test, failures: &failures)
    }

    // MARK: - Rebase snapshot

    static func testRebaseSnapshot(_ failures: inout [Failure]) {
        let test = "rebase-snapshot"
        if let snapshot = rebaseSnapshotProgress(msgnumText: "2\n", endText: "5\n", origHead: "aaa\n", onto: "bbb\n") {
            check(snapshot.position == 2 && snapshot.total == 5, "2/5", test: test, failures: &failures)
            check(snapshot.value == 0.4, "value 0.4, got \(snapshot.value)", test: test, failures: &failures)
        } else {
            check(false, "valid snapshot parses", test: test, failures: &failures)
        }
        check(rebaseSnapshotProgress(msgnumText: "x", endText: "5", origHead: "aaa", onto: "bbb") == nil, "bad msgnum → nil", test: test, failures: &failures)
        check(rebaseSnapshotProgress(msgnumText: nil, endText: "5", origHead: "aaa", onto: "bbb") == nil, "missing → nil", test: test, failures: &failures)
        check(rebaseSnapshotProgress(msgnumText: "0", endText: "5", origHead: "aaa", onto: "bbb") == nil, "zero → nil", test: test, failures: &failures)
    }

    // MARK: - Sequencer todo

    static func testSequencerTodo(_ failures: inout [Failure]) {
        let test = "sequencer-todo"
        if let line = parseSequencerTodoLine("pick abc1234 Add thing") {
            check(line == CommitOneLine(sha: "abc1234", summary: "Add thing"), "todo line \(line)", test: test, failures: &failures)
        } else {
            check(false, "todo line parses", test: test, failures: &failures)
        }
        check(parseSequencerTodoLine("pick nospace") == nil, "sha-only rejected", test: test, failures: &failures)
        let todo = "pick aaa First\npick bbb Second\n"
        if let commits = parseSequencerTodo(todo) {
            check(commits.count == 2 && commits[0].sha == "aaa", "todo file", test: test, failures: &failures)
        } else {
            check(false, "todo file parses", test: test, failures: &failures)
        }
        check(parseSequencerTodo("") == nil, "empty todo → nil", test: test, failures: &failures)

        let remaining = [oneLine("c", "Third")]
        if let progress = cherryPickSnapshotProgress(cherryPickedCount: 2, remainingCommits: remaining) {
            check(progress.position == 3 && progress.totalCommitCount == 3, "3 of 3", test: test, failures: &failures)
            check(progress.currentCommitSummary == "Third", "summary", test: test, failures: &failures)
        } else {
            check(false, "snapshot progress", test: test, failures: &failures)
        }
        check(cherryPickSnapshotProgress(cherryPickedCount: 3, remainingCommits: []) == nil, "no remaining → nil", test: test, failures: &failures)
    }

    // MARK: - Squash todo

    static func testSquashTodo(_ failures: inout [Failure]) {
        let test = "squash-todo"
        // History oldest→newest A B C D E; squash A+E onto C → B, A-C-E, D.
        // `log` is newest-first, as `git log` returns it.
        let log = ["E", "D", "C", "B", "A"].map { oneLine($0.lowercased(), "commit \($0)") }
        do {
            let todo = try buildSquashTodo(log: log, toSquashSHAs: ["a", "e"], squashOntoSHA: "c")
            let expected = "pick b commit B\npick a commit A\nsquash c commit C\nsquash e commit E\npick d commit D\n"
            check(todo == expected, "squash order:\n\(todo)", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
        do {
            _ = try buildSquashTodo(log: log, toSquashSHAs: [], squashOntoSHA: "c")
            check(false, "empty throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .noCommits(operation: .squash), "noCommits, got \(error)", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
        do {
            _ = try buildSquashTodo(log: log, toSquashSHAs: ["c"], squashOntoSHA: "c")
            check(false, "target-in-set throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .targetIncludedInSquash, "target guard, got \(error)", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
        do {
            _ = try buildSquashTodo(log: log, toSquashSHAs: ["a"], squashOntoSHA: "zzz")
            check(false, "missing onto throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .targetNotInLog, "target log guard, got \(error)", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
    }

    // MARK: - Reorder todo

    static func testReorderTodo(_ failures: inout [Failure]) {
        let test = "reorder-todo"
        // Move A+E before C → B, A, E, C, D.
        let log = ["E", "D", "C", "B", "A"].map { oneLine($0.lowercased(), "commit \($0)") }
        do {
            let todo = try buildReorderTodo(log: log, toMoveSHAs: ["a", "e"], beforeSHA: "c")
            let expected = "pick b commit B\npick a commit A\npick e commit E\npick c commit C\npick d commit D\n"
            check(todo == expected, "reorder order:\n\(todo)", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
        // Nil base moves to the end: move B → A, C, D, B.
        let log2 = ["D", "C", "B", "A"].map { oneLine($0.lowercased(), "commit \($0)") }
        do {
            let todo = try buildReorderTodo(log: log2, toMoveSHAs: ["b"], beforeSHA: nil)
            let expected = "pick a commit A\npick c commit C\npick d commit D\npick b commit B\n"
            check(todo == expected, "move to end:\n\(todo)", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
        do {
            _ = try buildReorderTodo(log: log, toMoveSHAs: ["a"], beforeSHA: "zzz")
            check(false, "missing base throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .baseNotInLog, "base log guard, got \(error)", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
    }

    // MARK: - Log scoping

    static func testScopeLog(_ failures: inout [Failure]) {
        let test = "scope-log"
        let log = ["d", "c", "b", "a"].map { oneLine($0) }
        check(scopeLogForInteractiveRebase(log: log, ref: nil).map(\.sha) == ["d", "c", "b", "a"],
              "nil ref → whole log", test: test, failures: &failures)
        check(scopeLogForInteractiveRebase(log: log, ref: "b^").map(\.sha) == ["d", "c", "b"],
              "base included", test: test, failures: &failures)
        check(scopeLogForInteractiveRebase(log: log, ref: "a^").map(\.sha) == ["d", "c", "b", "a"],
              "root-adjacent → whole log", test: test, failures: &failures)
        check(scopeLogForInteractiveRebase(log: log, ref: "zzz^").isEmpty,
              "unknown base → empty (builders throw)", test: test, failures: &failures)
    }

    // MARK: - Validation guards

    static func testValidationGuards(_ failures: inout [Failure]) {
        let test = "validation-guards"
        let merge = testCommit(sha: "merge1", parents: ["a", "b"])
        check(merge.isMergeCommit, "merge fixture", test: test, failures: &failures)
        do {
            try validateSquash(toSquash: [testCommit(sha: "a")], squashOnto: testCommit(sha: "b"))
        } catch {
            check(false, "valid squash throws \(error)", test: test, failures: &failures)
        }
        do {
            try validateSquash(toSquash: [merge], squashOnto: testCommit(sha: "b"))
            check(false, "merge toSquash throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .mergeCommitInvolved(sha: "merge1"), "merge guard, got \(error)", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
        do {
            try validateSquash(toSquash: [testCommit(sha: "a")], squashOnto: merge)
            check(false, "merge onto throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .mergeCommitInvolved(sha: "merge1"), "onto merge guard, got \(error)", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
        do {
            try validateReorder(toMove: [merge])
            check(false, "merge reorder throws", test: test, failures: &failures)
        } catch let error as MultiCommitValidationError {
            check(error == .mergeCommitInvolved(sha: "merge1"), "reorder merge guard", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
    }

    // MARK: - lastRetainedCommitRef

    static func testLastRetainedCommitRef(_ failures: inout [Failure]) {
        let test = "last-retained-ref"
        check(lastRetainedCommitRef(commitSHAs: ["a", "b", "c"], containing: ["a", "b"]) == "b^", "mid-range ref", test: test, failures: &failures)
        check(lastRetainedCommitRef(commitSHAs: ["a", "b", "c"], containing: ["c"]) == nil, "root → nil", test: test, failures: &failures)
        check(lastRetainedCommitRef(commitSHAs: ["a", "b", "c"], containing: ["a", "c"]) == nil, "range incl root → nil", test: test, failures: &failures)
        check(lastRetainedCommitRef(commitSHAs: ["a", "b", "c"], containing: []) == nil, "empty → nil", test: test, failures: &failures)
        check(lastRetainedCommitRef(commitSHAs: ["a", "b", "c"], containing: ["zzz"]) == nil, "unknown → nil", test: test, failures: &failures)
    }

    // MARK: - canStartOperation

    static func testCanStartOperation(_ failures: inout [Failure]) {
        let test = "can-start"
        let current = testBranch("feature")
        check(canStartOperation(selectedBranch: nil, currentBranch: current, commitCount: 3, hasConflictsPreview: false, isInvalidPreview: false) == false, "no selection", test: test, failures: &failures)
        check(canStartOperation(selectedBranch: testBranch("feature"), currentBranch: current, commitCount: 3, hasConflictsPreview: false, isInvalidPreview: false) == false, "same branch", test: test, failures: &failures)
        check(canStartOperation(selectedBranch: testBranch("main"), currentBranch: current, commitCount: 0, hasConflictsPreview: false, isInvalidPreview: false) == false, "no commits", test: test, failures: &failures)
        check(canStartOperation(selectedBranch: testBranch("main"), currentBranch: current, commitCount: 0, hasConflictsPreview: true, isInvalidPreview: false) == true, "conflicts always start", test: test, failures: &failures)
        check(canStartOperation(selectedBranch: testBranch("main"), currentBranch: current, commitCount: 3, hasConflictsPreview: false, isInvalidPreview: true) == false, "invalid preview", test: test, failures: &failures)
        check(canStartOperation(selectedBranch: testBranch("main"), currentBranch: current, commitCount: 3, hasConflictsPreview: false, isInvalidPreview: false) == true, "clean start", test: test, failures: &failures)
    }

    // MARK: - Choose-branch preselect

    static func testResolveChooseBranchInitial(_ failures: inout [Failure]) {
        let test = "choose-branch-initial"
        let eligible: Set<String> = ["main", "feature"]
        check(resolveChooseBranchInitialName(
            initialBranchName: "feature", currentBranchName: "feature",
            defaultBranchName: "main", eligibleBranchNames: eligible) == "feature",
              "explicit wins", test: test, failures: &failures)
        check(resolveChooseBranchInitialName(
            initialBranchName: nil, currentBranchName: "feature",
            defaultBranchName: "main", eligibleBranchNames: eligible) == "main",
              "default when off-default", test: test, failures: &failures)
        check(resolveChooseBranchInitialName(
            initialBranchName: nil, currentBranchName: "main",
            defaultBranchName: "main", eligibleBranchNames: eligible) == nil,
              "nil when on default", test: test, failures: &failures)
        check(resolveChooseBranchInitialName(
            initialBranchName: nil, currentBranchName: "feature",
            defaultBranchName: nil, eligibleBranchNames: eligible) == nil,
              "nil without default", test: test, failures: &failures)
        check(resolveChooseBranchInitialName(
            initialBranchName: "gone", currentBranchName: "feature",
            defaultBranchName: "main", eligibleBranchNames: eligible) == "main",
              "stale initial falls back to default", test: test, failures: &failures)
        check(resolveChooseBranchInitialName(
            initialBranchName: "gone", currentBranchName: "feature",
            defaultBranchName: "missing", eligibleBranchNames: eligible) == nil,
              "stale everything → nil", test: test, failures: &failures)
    }

    // MARK: - Drop routing

    static func testDropRouting(_ failures: inout [Failure]) {
        let test = "drop-routing"
        let ordered = ["a", "b", "c", "d"]

        let branch = routeCommitDrop(draggedSHAs: ["a", "b"], target: .branch(name: "main"))
        check(branch == .cherryPick(branchName: "main", shas: ["a", "b"]), "branch → cherry-pick, got \(branch)", test: test, failures: &failures)

        let squash = routeCommitDrop(draggedSHAs: ["a", "b"], target: .commit(sha: "c"))
        check(squash == .squash(ontoSHA: "c", shas: ["a", "b"]), "commit → squash, got \(squash)", test: test, failures: &failures)

        let itself = routeCommitDrop(draggedSHAs: ["c"], target: .commit(sha: "c"))
        check(itself == .invalid(reason: .droppedOntoItself), "self-drop rejected, got \(itself)", test: test, failures: &failures)

        let mergeDrop = routeCommitDrop(draggedSHAs: ["a", "m"], target: .insertionPoint(beforeSHA: "c"), orderedSHAs: ordered, mergeCommitSHAs: ["m"])
        check(mergeDrop == .invalid(reason: .mergeCommitInvolved(sha: "m")), "merge guard, got \(mergeDrop)", test: test, failures: &failures)

        let reorder = routeCommitDrop(draggedSHAs: ["a", "b"], target: .insertionPoint(beforeSHA: "d"), orderedSHAs: ordered)
        check(reorder == .reorder(beforeSHA: "d", shas: ["a", "b"]), "insertion → reorder, got \(reorder)", test: test, failures: &failures)

        let scattered = routeCommitDrop(draggedSHAs: ["a", "c"], target: .insertionPoint(beforeSHA: "d"), orderedSHAs: ordered)
        check(scattered == .invalid(reason: .notContiguous), "non-contiguous rejected, got \(scattered)", test: test, failures: &failures)

        let empty = routeCommitDrop(draggedSHAs: [], target: .branch(name: "main"))
        check(empty == .invalid(reason: .noCommits), "empty rejected", test: test, failures: &failures)

        check(areCommitsContiguous(draggedSHAs: ["b", "c"], orderedSHAs: ordered), "contiguous", test: test, failures: &failures)
        check(!areCommitsContiguous(draggedSHAs: ["a", "a"], orderedSHAs: ordered), "duplicates rejected", test: test, failures: &failures)
        check(!areCommitsContiguous(draggedSHAs: ["zzz"], orderedSHAs: ordered), "unknown rejected", test: test, failures: &failures)
    }

    // MARK: - Keyboard reorder

    static func testKeyboardReorder(_ failures: inout [Failure]) {
        let test = "keyboard-reorder"
        let session = KeyboardReorderSession(shas: ["a", "b"], orderedSHAs: ["a", "b", "c", "d"])
        check(session.hintText.contains("2 commits"), "hint count", test: test, failures: &failures)
        let confirmed = session.confirm(insertionIndex: 3)
        check(confirmed == .reorder(beforeSHA: "d", shas: ["a", "b"]), "insertion resolves, got \(confirmed)", test: test, failures: &failures)
        let toEnd = session.confirm(insertionIndex: 4)
        check(toEnd == .reorder(beforeSHA: nil, shas: ["a", "b"]), "end resolves, got \(toEnd)", test: test, failures: &failures)
        let single = KeyboardReorderSession(shas: ["a"], orderedSHAs: ["a", "b"])
        check(single.hintText.contains("1 commit."), "singular hint", test: test, failures: &failures)
    }

    // MARK: - Squash / reorder seams + continue / abort

    static func squashLog() -> [Commit] {
        // Newest-first A..D; summaries double as todo text.
        ["d", "c", "b", "a"].map { testCommit(sha: $0) }
    }

    static func commit(named sha: String, in log: [Commit]) -> Commit {
        log.first(where: { $0.sha == sha })!
    }

    static func testShellSquash(_ failures: inout [Failure]) async {
        let test = "shell-squash"
        let repo = Repository(path: "/tmp/shell-squash", id: 1710)
        let feature = Branch(
            name: "feature", upstream: nil, tip: BranchTip(sha: "d"),
            type: .local, ref: "refs/heads/feature")
        let mock = MockGitService(repositoryPath: repo.path)
        mock.stubCommits = squashLog()
        let app = await storeServing(repo: repo, tipBranch: feature, mock: mock)
        let log = mock.stubCommits
        let service = MockMultiCommitService()
        let result = await shellSquashCommits(
            store: app, repository: repo,
            toSquash: [commit(named: "d", in: log), commit(named: "c", in: log)],
            onto: commit(named: "b", in: log),
            summary: "Squashed!", service: service)
        check(result == .completedWithoutError, "completes, got \(String(describing: result))",
              test: test, failures: &failures)
        check(service.recordedOps == [.interactiveRebase(action: .squash)],
              "runs interactive squash, got \(service.recordedOps)",
              test: test, failures: &failures)
        check(app.currentBanner == .successfulSquash(count: 3, actionToken: {
            if case .successfulSquash(_, let token) = app.currentBanner { return token }
            return UUID()
        }()), "squash banner, got \(String(describing: app.currentBanner))",
              test: test, failures: &failures)
        check(app.multiCommitUndoStates[repo.hash] == MultiCommitUndoState(
            kind: .squash, undoSHA: "d", branchName: "feature"),
              "undo recorded, got \(String(describing: app.multiCommitUndoStates[repo.hash]))",
              test: test, failures: &failures)
        check(app.inFlightMultiCommitOps[repo.hash] == nil, "in-flight cleared",
              test: test, failures: &failures)
        // Conflicts keep the op open and surface the conflicts flow.
        service.stubRebaseResult = .conflictsEncountered
        let conflicted = await shellSquashCommits(
            store: app, repository: repo,
            toSquash: [commit(named: "d", in: log)],
            onto: commit(named: "c", in: log),
            summary: "Again", service: service)
        check(conflicted == .conflictsEncountered, "conflicts pass through",
              test: test, failures: &failures)
        if case .conflictsFound(let description, _) = app.currentBanner {
            check(description.contains("squashing"), "conflicts banner, got \(description)",
                  test: test, failures: &failures)
        } else {
            check(false, "conflicts banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
        }
        check(app.currentPopup == .multiCommitOperation(
            repositoryID: repo.id, kind: .squash, initialBranchName: nil),
              "squash dialog opens, got \(String(describing: app.currentPopup))",
              test: test, failures: &failures)
        check(app.inFlightMultiCommitOps[repo.hash]?.kind == .squash, "in-flight kept",
              test: test, failures: &failures)
        // Validation failures never start.
        let mergey = testCommit(sha: "m", parents: ["a", "b"])
        let refused = await shellSquashCommits(
            store: app, repository: repo,
            toSquash: [mergey], onto: commit(named: "a", in: log),
            summary: "Nope", service: service)
        check(refused == nil, "merge squash refused",
              test: test, failures: &failures)
        let errors = app.allPopups.filter {
            if case .error = $0 { return true }; return false
        }
        check(!errors.isEmpty, "validation posts .error",
              test: test, failures: &failures)
    }

    static func testShellReorder(_ failures: inout [Failure]) async {
        let test = "shell-reorder"
        let repo = Repository(path: "/tmp/shell-reorder", id: 1711)
        let feature = Branch(
            name: "feature", upstream: nil, tip: BranchTip(sha: "d"),
            type: .local, ref: "refs/heads/feature")
        let mock = MockGitService(repositoryPath: repo.path)
        mock.stubCommits = squashLog()
        let app = await storeServing(repo: repo, tipBranch: feature, mock: mock)
        let log = mock.stubCommits
        let service = MockMultiCommitService()
        let result = await shellReorderCommits(
            store: app, repository: repo,
            toMove: [commit(named: "d", in: log)], beforeSHA: "c",
            service: service)
        check(result == .completedWithoutError, "completes, got \(String(describing: result))",
              test: test, failures: &failures)
        check(service.recordedOps == [.interactiveRebase(action: .reorder)],
              "runs interactive reorder, got \(service.recordedOps)",
              test: test, failures: &failures)
        if case .successfulReorder(let count, _) = app.currentBanner {
            check(count == 1, "reorder banner count, got \(count)",
                  test: test, failures: &failures)
        } else {
            check(false, "reorder banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
        }
        check(app.multiCommitUndoStates[repo.hash]?.kind == .reorder, "undo recorded",
              test: test, failures: &failures)
        // Dirty workdir refuses before anything runs.
        var dirty = RepositoryState(repository: repo)
        dirty.workingDirectory = .fromFiles([WorkingDirectoryFileChange(
            path: "x.txt", status: .modified(submoduleStatus: nil),
            selection: .fromInitialSelection(.all))])
        dirty.tip = .valid(branch: feature)
        dirty.branches = [feature]
        app.updateRepositoryState(dirty)
        let opsBefore = service.recordedOps.count
        let refused = await shellReorderCommits(
            store: app, repository: repo,
            toMove: [commit(named: "d", in: log)], beforeSHA: nil,
            service: service)
        check(refused == nil && service.recordedOps.count == opsBefore,
              "dirty refuses without running",
              test: test, failures: &failures)
    }

    static func testShellContinueAbort(_ failures: inout [Failure]) async {
        let test = "shell-continue-abort"
        let repo = Repository(path: "/tmp/shell-continue", id: 1712)
        let feature = testBranch("feature")
        let mock = MockGitService(repositoryPath: repo.path)
        let app = await storeServing(repo: repo, tipBranch: feature, mock: mock)
        let service = MockMultiCommitService()
        let popup = Popup.multiCommitOperation(
            repositoryID: repo.id, kind: .squash, initialBranchName: nil)
        // Continue a recorded squash through to its banner.
        app.inFlightMultiCommitOps[repo.hash] = InFlightMultiCommitOp(
            kind: .squash, count: 3, targetBranchName: "feature")
        app.showPopup(popup)
        service.stubRebaseResult = .completedWithoutError
        let done = await shellContinueMultiCommitOp(
            store: app, repository: repo, popup: popup, service: service)
        check(done, "continue completes", test: test, failures: &failures)
        check(service.recordedOps.contains(.continuedRebase),
              "continued, got \(service.recordedOps)",
              test: test, failures: &failures)
        if case .successfulSquash(let count, _) = app.currentBanner {
            check(count == 3, "squash banner keeps count, got \(count)",
                  test: test, failures: &failures)
        } else {
            check(false, "squash banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
        }
        check(app.inFlightMultiCommitOps[repo.hash] == nil, "in-flight cleared",
              test: test, failures: &failures)
        check(!app.allPopups.contains(popup), "popup closes",
              test: test, failures: &failures)
        // Renewed conflicts stay open for another round.
        app.inFlightMultiCommitOps[repo.hash] = InFlightMultiCommitOp(
            kind: .reorder, count: 1, targetBranchName: "feature")
        app.showPopup(popup)
        service.stubRebaseResult = .conflictsEncountered
        let stuck = await shellContinueMultiCommitOp(
            store: app, repository: repo, popup: popup, service: service)
        check(!stuck && app.allPopups.contains(popup), "conflicts stay open",
              test: test, failures: &failures)
        check(app.inFlightMultiCommitOps[repo.hash] != nil, "in-flight kept",
              test: test, failures: &failures)
        // Abort tears everything down, including the conflicts banner.
        app.setBanner(.conflictsFound(operationDescription: "squashing", actionToken: UUID()))
        let aborted = await shellAbortMultiCommitOp(
            store: app, repository: repo, popup: popup, service: service)
        check(aborted, "abort runs", test: test, failures: &failures)
        check(service.recordedOps.contains(.abortedRebase),
              "aborted, got \(service.recordedOps)",
              test: test, failures: &failures)
        check(app.inFlightMultiCommitOps[repo.hash] == nil, "abort clears in-flight",
              test: test, failures: &failures)
        check(app.currentBanner == nil, "abort clears conflicts banner",
              test: test, failures: &failures)
        check(!app.allPopups.contains(popup), "abort closes popup",
              test: test, failures: &failures)
    }

    static func testLiveSquash(_ failures: inout [Failure]) async {
        let test = "live-squash"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiCommitTests-squash-\(UUID().uuidString)").path
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
        func log() async throws -> [String] {
            let result = try await GitProcess.run(
                ["log", "--format=%H %s"], workingDirectory: dir)
            return result.stdoutString.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        do {
            try await run(["-c", "init.defaultBranch=main", "init"])
            try await run(["config", "user.name", "MultiCommit Tests"])
            try await run(["config", "user.email", "multicommit@example.com"])
            for (name, content) in [("a", "a\n"), ("b", "b\n"), ("c", "c\n"), ("d", "d\n")] {
                try "\(content)".write(
                    toFile: (dir as NSString).appendingPathComponent("\(name).txt"),
                    atomically: true, encoding: .utf8)
                try await run(["add", "--", "\(name).txt"])
                try await run(["commit", "-m", name.uppercased()])
            }
            let repo = Repository(path: dir, id: 1713)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            guard let state = app.selectedState else {
                check(false, "no state", test: test, failures: &failures)
                return
            }
            func byMessage(_ message: String) -> Commit {
                state.recentCommits.first(where: { $0.summary == message })!
            }
            let result = await shellSquashCommits(
                store: app, repository: repo,
                toSquash: [byMessage("D"), byMessage("C")], onto: byMessage("B"),
                summary: "Squashed!")
            check(result == .completedWithoutError, "squash completes, got \(String(describing: result))",
                  test: test, failures: &failures)
            let after = try await log()
            check(after.count == 2, "two commits remain, got \(after)",
                  test: test, failures: &failures)
            check(after.first?.contains("Squashed!") == true, "message kept, got \(after)",
                  test: test, failures: &failures)
            if case .successfulSquash(let count, _) = app.currentBanner {
                check(count == 3, "banner count, got \(count)",
                      test: test, failures: &failures)
            } else {
                check(false, "squash banner, got \(String(describing: app.currentBanner))",
                      test: test, failures: &failures)
            }
            // Undo restores all four commits.
            if let banner = app.currentBanner {
                await shellUndoBanner(store: app, banner: banner)
                let undone = try await log()
                check(undone.count == 4, "undo restores, got \(undone)",
                      test: test, failures: &failures)
            } else {
                check(false, "no banner to undo", test: test, failures: &failures)
            }
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testLiveReorder(_ failures: inout [Failure]) async {
        let test = "live-reorder"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiCommitTests-reorder-\(UUID().uuidString)").path
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
        func subjects() async throws -> [String] {
            let result = try await GitProcess.run(
                ["log", "--format=%s"], workingDirectory: dir)
            return result.stdoutString.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        do {
            try await run(["-c", "init.defaultBranch=main", "init"])
            try await run(["config", "user.name", "MultiCommit Tests"])
            try await run(["config", "user.email", "multicommit@example.com"])
            for (name, content) in [("a", "a\n"), ("b", "b\n"), ("c", "c\n"), ("d", "d\n")] {
                try "\(content)".write(
                    toFile: (dir as NSString).appendingPathComponent("\(name).txt"),
                    atomically: true, encoding: .utf8)
                try await run(["add", "--", "\(name).txt"])
                try await run(["commit", "-m", name.uppercased()])
            }
            let repo = Repository(path: dir, id: 1714)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            guard let state = app.selectedState else {
                check(false, "no state", test: test, failures: &failures)
                return
            }
            let d = state.recentCommits.first(where: { $0.summary == "D" })!
            let c = state.recentCommits.first(where: { $0.summary == "C" })!
            let result = await shellReorderCommits(
                store: app, repository: repo, toMove: [d], beforeSHA: c.sha)
            check(result == .completedWithoutError, "reorder completes, got \(String(describing: result))",
                  test: test, failures: &failures)
            check(try await subjects() == ["C", "D", "B", "A"],
                  "D before C, got \(try await subjects())",
                  test: test, failures: &failures)
            // Undo restores the original order.
            if let banner = app.currentBanner {
                await shellUndoBanner(store: app, banner: banner)
                check(try await subjects() == ["D", "C", "B", "A"],
                      "undo restores, got \(try await subjects())",
                      test: test, failures: &failures)
            } else {
                check(false, "no banner to undo", test: test, failures: &failures)
            }
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testLiveContinueRebase(_ failures: inout [Failure]) async {
        let test = "live-continue"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiCommitTests-continue-\(UUID().uuidString)").path
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
            try await run(["config", "user.name", "MultiCommit Tests"])
            try await run(["config", "user.email", "multicommit@example.com"])
            try "base\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "f.txt"])
            try await run(["commit", "-m", "base"])
            try await run(["checkout", "-qb", "feature"])
            try "base\nfeature\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["commit", "-qam", "feature work"])
            try await run(["checkout", "-q", "main"])
            try "base\nmainline\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["commit", "-qam", "main work"])
            try await run(["checkout", "-q", "feature"])
            // Start a conflicting rebase directly, then drive the shell seam.
            let service = LiveMultiCommitService()
            let started = try await service.rebase(
                repositoryPath: dir, baseBranch: "main", targetBranch: "feature")
            guard started == .conflictsEncountered else {
                check(false, "conflicted start, got \(started)", test: test, failures: &failures)
                return
            }
            let repo = Repository(path: dir, id: 1715)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            app.inFlightMultiCommitOps[repo.hash] = InFlightMultiCommitOp(
                kind: .rebase, count: 0,
                targetBranchName: "feature", baseBranchName: "main")
            let popup = Popup.multiCommitOperation(
                repositoryID: repo.id, kind: .rebase, initialBranchName: nil)
            app.showPopup(popup)
            // Resolve with theirs and stage, like the conflicts UI would.
            try await run(["checkout", "--theirs", "--", "f.txt"])
            try await run(["add", "--", "f.txt"])
            await app.refreshRepository(repo)
            let done = await shellContinueMultiCommitOp(
                store: app, repository: repo, popup: popup)
            check(done, "continue completes", test: test, failures: &failures)
            check(app.currentBanner == .successfulRebase(targetBranch: "feature", baseBranch: "main"),
                  "rebase banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
            check(!app.allPopups.contains(popup), "popup closes",
                  test: test, failures: &failures)
            check(app.inFlightMultiCommitOps[repo.hash] == nil, "in-flight cleared",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    // MARK: - Force-push gate + rebase execution

    /// AppStore serving `mock` on `repo` at `tipBranch` (stubs mirror the
    /// published state so background refreshes converge).
    private static func storeServing(
        repo: Repository, tipBranch: Branch, mock: MockGitService
    ) async -> AppStore {
        mock.stubStatus = RepositoryStatus(
            headers: StatusParser.StatusHeaders(
                currentBranch: tipBranch.name,
                currentUpstreamBranch: tipBranch.upstream,
                currentTip: tipBranch.tip.sha,
                aheadBehind: nil),
            workingDirectory: .fromFiles([]))
        mock.stubBranches = [tipBranch]
        mock.stubRemotes = []
        // stubCommits is the caller's (the seams read the branch log for
        // todo building); default MockGitService starts empty.
        let app = AppStore()
        app.setRepositories([repo])
        app.makeService = { _ in mock }
        app.selectRepository(repo)
        var state = RepositoryState(repository: repo)
        state.tip = .valid(branch: tipBranch)
        state.branches = [tipBranch]
        app.updateRepositoryState(state)
        await app.refreshRepository(repo)
        return app
    }

    static func testWarnAboutRemoteCommits(_ failures: inout [Failure]) async {
        let test = "warn-remote-commits"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiCommitTests-warn-\(UUID().uuidString)").path
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
            try await run(["config", "user.name", "MultiCommit Tests"])
            try await run(["config", "user.email", "multicommit@example.com"])
            try "a\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "f.txt"])
            try await run(["commit", "-m", "A"])
            let shaA = try await run(["rev-parse", "HEAD"])
            try "a\nb\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "f.txt"])
            try await run(["commit", "-m", "B"])
            let shaB = try await run(["rev-parse", "HEAD"])
            // No upstream → never warn.
            check(await warnAboutRemoteCommits(
                repositoryPath: dir, upstream: nil, oldestCommitRef: shaB) == false,
                  "no upstream → no warn", test: test, failures: &failures)
            // Upstream ref missing locally → never warn.
            check(await warnAboutRemoteCommits(
                repositoryPath: dir, upstream: "origin/gone", oldestCommitRef: shaB) == false,
                  "missing upstream ref → no warn", test: test, failures: &failures)
            try await run(["update-ref", "refs/remotes/origin/main", shaB])
            // Upstream == tip → nothing outside → no warn.
            check(await warnAboutRemoteCommits(
                repositoryPath: dir, upstream: "origin/main", oldestCommitRef: shaB) == false,
                  "upstream at tip → no warn", test: test, failures: &failures)
            // Upstream ahead of the rewrite base → warn.
            try await run(["update-ref", "refs/remotes/origin/main", shaB])
            check(await warnAboutRemoteCommits(
                repositoryPath: dir, upstream: "origin/main", oldestCommitRef: shaA) == true,
                  "upstream ahead → warn", test: test, failures: &failures)
            // Bad ref fails open (the rebase surfaces the real error).
            check(await warnAboutRemoteCommits(
                repositoryPath: dir, upstream: "origin/main", oldestCommitRef: "deadbee") == false,
                  "bad ref fails open", test: test, failures: &failures)
            // Bad workdir fails open too.
            check(await warnAboutRemoteCommits(
                repositoryPath: "/nonexistent-\(UUID().uuidString)",
                upstream: "origin/main", oldestCommitRef: shaA) == false,
                  "missing repo fails open", test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testShellRebaseBranch(_ failures: inout [Failure]) async {
        let test = "shell-rebase"
        let repo = Repository(path: "/tmp/shell-rebase", id: 1701)
        let feature = testBranch("feature")
        let mock = MockGitService(repositoryPath: repo.path)
        let app = await storeServing(repo: repo, tipBranch: feature, mock: mock)
        let chooser = Popup.multiCommitOperation(
            repositoryID: repo.id, kind: .rebase, initialBranchName: nil)
        app.showPopup(chooser)
        let service = MockMultiCommitService()
        service.stubRebaseResult = .completedWithoutError
        let result = await shellRebaseBranch(
            store: app, repository: repo, popup: chooser,
            baseBranchName: "main", targetBranchName: "feature",
            service: service)
        check(result == .completedWithoutError, "result passes through, got \(String(describing: result))",
              test: test, failures: &failures)
        check(service.recordedOps == [.rebased(base: "main", target: "feature")],
              "rebase ran, got \(service.recordedOps)",
              test: test, failures: &failures)
        check(app.currentBanner == .successfulRebase(targetBranch: "feature", baseBranch: "main"),
              "success banner, got \(String(describing: app.currentBanner))",
              test: test, failures: &failures)
        check(!app.allPopups.contains(chooser), "chooser closes, got \(app.allPopups)",
              test: test, failures: &failures)
        // Conflicts map to the conflicts banner (dialog stays for the flow).
        app.showPopup(chooser)
        service.stubRebaseResult = .conflictsEncountered
        let conflicted = await shellRebaseBranch(
            store: app, repository: repo, popup: chooser,
            baseBranchName: "main", targetBranchName: "feature",
            service: service)
        check(conflicted == .conflictsEncountered, "conflicts pass through",
              test: test, failures: &failures)
        if case .rebaseConflictsFound(let target, _) = app.currentBanner {
            check(target == "feature", "conflicts banner, got \(target)",
                  test: test, failures: &failures)
        } else {
            check(false, "conflicts banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
        }
    }

    static func testLiveRebaseBranch(_ failures: inout [Failure]) async {
        let test = "live-rebase"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiCommitTests-rebase-\(UUID().uuidString)").path
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
            try await run(["config", "user.name", "MultiCommit Tests"])
            try await run(["config", "user.email", "multicommit@example.com"])
            try "base\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "f.txt"])
            try await run(["commit", "-m", "base"])
            try await run(["checkout", "-qb", "feature"])
            try "feature\n".write(
                toFile: (dir as NSString).appendingPathComponent("g.txt"),
                atomically: true, encoding: .utf8)
            try await run(["add", "--", "g.txt"])
            try await run(["commit", "-m", "feature work"])
            // Diverge main too: rebasing onto the bare merge-base is a
            // no-op ("up to date") in git, so real replay needs both sides.
            try await run(["checkout", "-q", "main"])
            try "base\nmainline\n".write(
                toFile: (dir as NSString).appendingPathComponent("f.txt"),
                atomically: true, encoding: .utf8)
            try await run(["commit", "-qam", "main work"])
            try await run(["checkout", "-q", "feature"])
            let repo = Repository(path: dir, id: 1702)
            let app = AppStore()
            app.setRepositories([repo])
            app.selectRepository(repo)
            await app.refreshRepository(repo)
            let chooser = Popup.multiCommitOperation(
                repositoryID: repo.id, kind: .rebase, initialBranchName: nil)
            app.showPopup(chooser)
            // No upstream configured → the gate stays quiet and the rebase runs.
            let result = await shellRebaseBranch(
                store: app, repository: repo, popup: chooser,
                baseBranchName: "main", targetBranchName: "feature")
            check(result == .completedWithoutError, "live rebase completes, got \(String(describing: result))",
                  test: test, failures: &failures)
            check(app.currentBanner == .successfulRebase(targetBranch: "feature", baseBranch: "main"),
                  "live banner, got \(String(describing: app.currentBanner))",
                  test: test, failures: &failures)
            check(!app.allPopups.contains(chooser), "live chooser closes",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    // MARK: - Banner mapping

    static func testBannerMapping(_ failures: inout [Failure]) {
        let test = "banner-mapping"
        let token = UUID()
        check(
            rebaseResultBanner(.completedWithoutError, targetBranch: "feature", baseBranch: "main", actionToken: token)
                == .successfulRebase(targetBranch: "feature", baseBranch: "main"),
            "rebase success banner", test: test, failures: &failures)
        check(
            rebaseResultBanner(.alreadyUpToDate, targetBranch: "feature", baseBranch: "main")
                == .branchAlreadyUpToDate(ourBranch: "feature", theirBranch: "main"),
            "rebase up-to-date banner", test: test, failures: &failures)
        check(
            rebaseResultBanner(.conflictsEncountered, targetBranch: "feature", baseBranch: nil, actionToken: token)
                == .rebaseConflictsFound(targetBranch: "feature", actionToken: token),
            "rebase conflicts banner", test: test, failures: &failures)
        check(
            rebaseResultBanner(.aborted, targetBranch: "feature", baseBranch: nil) == nil,
            "rebase abort silent", test: test, failures: &failures)
        check(
            cherryPickResultBanner(.completedWithoutError, targetBranchName: "main", count: 2, actionToken: token)
                == .successfulCherryPick(targetBranchName: "main", count: 2, actionToken: token),
            "pick success banner", test: test, failures: &failures)
        check(
            cherryPickResultBanner(.conflictsEncountered, targetBranchName: "main", count: 2, actionToken: token)
                == .cherryPickConflictsFound(targetBranchName: "main", actionToken: token),
            "pick conflicts banner", test: test, failures: &failures)
        check(
            cherryPickUndoneBanner(targetBranchName: "main", count: 2)
                == .cherryPickUndone(targetBranchName: "main", countCherryPicked: 2),
            "pick undone banner", test: test, failures: &failures)
        check(
            squashResultBanner(count: 3, actionToken: token) == .successfulSquash(count: 3, actionToken: token),
            "squash banner", test: test, failures: &failures)
        check(squashUndoneBanner(count: 3) == .squashUndone(commitsCount: 3), "squash undone", test: test, failures: &failures)
        check(
            reorderResultBanner(count: 2, actionToken: token) == .successfulReorder(count: 2, actionToken: token),
            "reorder banner", test: test, failures: &failures)
        check(reorderUndoneBanner(count: 2) == .reorderUndone(commitsCount: 2), "reorder undone", test: test, failures: &failures)
        check(shouldConfirmAbort(hasResolvedConflicts: true), "confirm when resolved", test: test, failures: &failures)
        check(!shouldConfirmAbort(hasResolvedConflicts: false), "no confirm when clean", test: test, failures: &failures)
    }
}
