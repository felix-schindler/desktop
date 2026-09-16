#if TESTBUILD
@testable import GitDesktop
#endif
import Foundation

// MARK: - PartialStagingTests
// Unit + live tests for partial staging (`Git/PatchFormatter.swift` +
// `Git/Operations/StageOperations.swift` + `LiveGitService.commit`).
// Same harness style as `Task8Tests`: `runAll()` returns the failure count.
// Pure patch/partition tests need no git; the live tests commit in temp
// repos via real git (like `GitStoreTests`).

@MainActor
public enum PartialStagingTests {
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
        testPatchHeaders(&failures)
        testHunkHeader(&failures)
        testFullSelectionPatch(&failures)
        testPartialDeselectAdd(&failures)
        testPartialDeselectDelete(&failures)
        testNewFileDropsUnselected(&failures)
        testEmptyPatchThrows(&failures)
        testUnsupportedDiffThrows(&failures)
        testPartition(&failures)
        testParseLsTree(&failures)
        await testLivePartialCommit(&failures)
        await testLiveFullCommit(&failures)
        if failures.isEmpty {
            print("PartialStagingTests: all tests passed")
        } else {
            print("PartialStagingTests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: Fixtures

    /// One hunk: ` line1`, `-old`, `+new1`, `+new2`, ` line3`.
    /// Line `i` gets `originalLineNumber = base + i` so absolute indices
    /// (`unifiedDiffStart + offset`) match, like `DiffParser` output.
    static func selectionHunk(base: Int = 50) -> DiffHunk {
        let texts: [(String, DiffLineType)] = [
            ("@@ -1,3 +1,5 @@", .hunk),
            (" line1", .context),
            ("-old", .delete),
            ("+new1", .add),
            ("+new2", .add),
            (" line3", .context),
        ]
        let lines = texts.enumerated().map { offset, entry in
            DiffLine(
                text: entry.0, type: entry.1,
                originalLineNumber: base + offset,
                oldLineNumber: nil, newLineNumber: nil)
        }
        return DiffHunk(
            header: DiffHunkHeader(
                oldStartLine: 1, oldLineCount: 3,
                newStartLine: 1, newLineCount: 5),
            lines: lines,
            unifiedDiffStart: base,
            unifiedDiffEnd: base + texts.count - 1)
    }

    static func selectionDiff(base: Int = 50) -> Diff {
        .text(TextDiffData(
            text: "patch", hunks: [selectionHunk(base: base)],
            maxLineNumber: 5, hasHiddenBidiChars: false))
    }

    static func modifiedFile(selection: DiffSelection) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(
            path: "a.txt", status: .modified(submoduleStatus: nil),
            selection: selection)
    }

    // MARK: Pure — headers

    static func testPatchHeaders(_ failures: inout [Failure]) {
        let test = "patch-headers"
        check(formatPatchHeader(from: nil, to: "a.txt") == "--- /dev/null\n+++ b/a.txt\n",
              "new header, got \(formatPatchHeader(from: nil, to: "a.txt").debugDescription)",
              test: test, failures: &failures)
        check(formatPatchHeader(from: "a.txt", to: "a.txt") == "--- a/a.txt\n+++ b/a.txt\n",
              "modified header", test: test, failures: &failures)
        let fresh = modifiedFile(selection: .all)
        check(formatPatchHeaderForFile(fresh) == "--- a/a.txt\n+++ b/a.txt\n",
              "modified file header", test: test, failures: &failures)
        let added = WorkingDirectoryFileChange(
            path: "n.txt", status: .untracked(submoduleStatus: nil), selection: .all)
        check(formatPatchHeaderForFile(added) == "--- /dev/null\n+++ b/n.txt\n",
              "untracked header", test: test, failures: &failures)
        let renamed = WorkingDirectoryFileChange(
            path: "new.txt",
            status: .renamed(oldPath: "old.txt", renameIncludesModifications: false, submoduleStatus: nil),
            selection: .all)
        check(formatPatchHeaderForFile(renamed) == "--- a/new.txt\n+++ b/new.txt\n",
              "renamed targets new path", test: test, failures: &failures)
    }

    static func testHunkHeader(_ failures: inout [Failure]) {
        let test = "hunk-header"
        check(formatHunkHeader(oldStartLine: 1, oldLineCount: 1, newStartLine: 1, newLineCount: 1) == "@@ -1 +1 @@\n",
              "count 1 omits ,1", test: test, failures: &failures)
        check(formatHunkHeader(oldStartLine: 1, oldLineCount: 3, newStartLine: 1, newLineCount: 2) == "@@ -1,3 +1,2 @@\n",
              "counts kept", test: test, failures: &failures)
    }

    // MARK: Pure — formatPatch

    static func testFullSelectionPatch(_ failures: inout [Failure]) {
        let test = "patch-full"
        do {
            let patch = try formatPatch(
                file: modifiedFile(selection: .all), diff: selectionDiff())
            check(patch.hasPrefix("--- a/a.txt\n+++ b/a.txt\n"), "header",
                  test: test, failures: &failures)
            check(patch.contains("@@ -1,3 +1,4 @@\n"), "full counts kept, got \(patch.debugDescription)",
                  test: test, failures: &failures)
            check(patch.contains("-old\n") && patch.contains("+new1\n") && patch.contains("+new2\n"),
                  "all changes, got \(patch.debugDescription)",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testPartialDeselectAdd(_ failures: inout [Failure]) {
        let test = "patch-partial-add"
        let base = 50
        // Deselect `+new2` (absolute index base + 4).
        let selection = DiffSelection.all.withLineSelection(lineIndex: base + 4, selected: false)
        do {
            let patch = try formatPatch(
                file: modifiedFile(selection: selection), diff: selectionDiff(base: base))
            check(patch.contains("+new1\n"), "keeps selected add",
                  test: test, failures: &failures)
            check(!patch.contains("+new2\n"), "drops unselected add, got \(patch.debugDescription)",
                  test: test, failures: &failures)
            check(patch.contains("@@ -1,3 +1,3 @@\n"), "recomputed counts, got \(patch.debugDescription)",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testPartialDeselectDelete(_ failures: inout [Failure]) {
        let test = "patch-partial-delete"
        let base = 50
        // Deselect `-old` (absolute index base + 2): it becomes context.
        let selection = DiffSelection.all.withLineSelection(lineIndex: base + 2, selected: false)
        do {
            let patch = try formatPatch(
                file: modifiedFile(selection: selection), diff: selectionDiff(base: base))
            check(patch.contains(" old\n") && !patch.contains("-old\n"),
                  "delete → context, got \(patch.debugDescription)",
                  test: test, failures: &failures)
            check(patch.contains("+new1\n") && patch.contains("+new2\n"), "adds kept",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testNewFileDropsUnselected(_ failures: inout [Failure]) {
        let test = "patch-new-file"
        let lines = [
            DiffLine(text: "@@ -0,0 +1,3 @@", type: .hunk, originalLineNumber: 70, oldLineNumber: nil, newLineNumber: nil),
            DiffLine(text: "+a", type: .add, originalLineNumber: 71, oldLineNumber: nil, newLineNumber: 1),
            DiffLine(text: "+b", type: .add, originalLineNumber: 72, oldLineNumber: nil, newLineNumber: 2),
            DiffLine(text: "+c", type: .add, originalLineNumber: 73, oldLineNumber: nil, newLineNumber: 3),
        ]
        let diff = Diff.text(TextDiffData(
            text: "patch",
            hunks: [DiffHunk(
                header: DiffHunkHeader(oldStartLine: 0, oldLineCount: 0, newStartLine: 1, newLineCount: 3),
                lines: lines, unifiedDiffStart: 70, unifiedDiffEnd: 73)],
            maxLineNumber: 3, hasHiddenBidiChars: false))
        let file = WorkingDirectoryFileChange(
            path: "n.txt", status: .untracked(submoduleStatus: nil),
            selection: .all.withLineSelection(lineIndex: 72, selected: false))
        do {
            let patch = try formatPatch(file: file, diff: diff)
            check(patch.hasPrefix("--- /dev/null\n+++ b/n.txt\n"), "null header",
                  test: test, failures: &failures)
            check(patch.contains("+a\n") && patch.contains("+c\n") && !patch.contains("+b\n"),
                  "drops unselected, got \(patch.debugDescription)",
                  test: test, failures: &failures)
            check(patch.contains("@@ -0,0 +1,2 @@\n"), "counts, got \(patch.debugDescription)",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testEmptyPatchThrows(_ failures: inout [Failure]) {
        let test = "patch-empty"
        do {
            _ = try formatPatch(
                file: modifiedFile(selection: .none), diff: selectionDiff())
            check(false, "expected emptyPatch throw", test: test, failures: &failures)
        } catch let error as PatchFormatterError {
            check(error == .emptyPatch(path: "a.txt"), "emptyPatch, got \(error)",
                  test: test, failures: &failures)
        } catch {
            check(false, "wrong error: \(error)", test: test, failures: &failures)
        }
    }

    static func testUnsupportedDiffThrows(_ failures: inout [Failure]) {
        let test = "patch-unsupported"
        for diff: Diff in [.binary, .unrenderable] {
            do {
                _ = try formatPatch(file: modifiedFile(selection: .all), diff: diff)
                check(false, "expected throw for \(diff.type)", test: test, failures: &failures)
            } catch let error as PatchFormatterError {
                check(error == .unsupportedDiff(path: "a.txt"), "unsupported, got \(error)",
                      test: test, failures: &failures)
            } catch {
                check(false, "wrong error: \(error)", test: test, failures: &failures)
            }
        }
    }

    // MARK: Pure — staging ops

    static func testPartition(_ failures: inout [Failure]) {
        let test = "stage-partition"
        let full = modifiedFile(selection: .all)
        let renamedFull = WorkingDirectoryFileChange(
            path: "new.txt",
            status: .renamed(oldPath: "old.txt", renameIncludesModifications: false, submoduleStatus: nil),
            selection: .all)
        let deletedFull = WorkingDirectoryFileChange(
            path: "gone.txt", status: .deleted(submoduleStatus: nil), selection: .all)
        let partial = modifiedFile(
            selection: .all.withLineSelection(lineIndex: 51, selected: false))
        let none = modifiedFile(selection: .none)
        let out = partitionCommitFiles([full, renamedFull, deletedFull, partial, none])
        check(out.fullPaths == ["a.txt", "new.txt", "gone.txt"], "full \(out.fullPaths)",
              test: test, failures: &failures)
        check(out.oldRenamedPaths == ["old.txt"], "renamed source \(out.oldRenamedPaths)",
              test: test, failures: &failures)
        check(out.deletedPaths == ["gone.txt"], "deleted \(out.deletedPaths)",
              test: test, failures: &failures)
        check(out.partialFiles.map(\.path) == ["a.txt"], "partial \(out.partialFiles.map(\.path))",
              test: test, failures: &failures)
        check(updateIndexArgs() == ["update-index", "--add", "--remove", "--replace", "-z", "--stdin"],
              "default args \(updateIndexArgs())", test: test, failures: &failures)
        check(updateIndexArgs(options: UpdateIndexOptions(forceRemove: true))
            == ["update-index", "--add", "--remove", "--force-remove", "--replace", "-z", "--stdin"],
              "force-remove args", test: test, failures: &failures)
        check(applyPatchToIndexArgs() == ["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-"],
              "apply args", test: test, failures: &failures)
    }

    static func testParseLsTree(_ failures: inout [Failure]) {
        let test = "ls-tree-parse"
        let parsed = parseLsTreeModeAndOid("100644 blob abc123def456\told.txt\n")
        check(parsed?.mode == "100644" && parsed?.oid == "abc123def456",
              "mode+oid, got \(String(describing: parsed))", test: test, failures: &failures)
        check(parseLsTreeModeAndOid("") == nil, "empty → nil",
              test: test, failures: &failures)
    }

    // MARK: Live — real git in temp repos

    static func makeRepoWithFile(content: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PartialStaging-\(UUID().uuidString)").path
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
        try await run(["config", "user.name", "Partial Staging Tests"])
        try await run(["config", "user.email", "partial@example.com"])
        try content.write(
            toFile: (dir as NSString).appendingPathComponent("file.txt"),
            atomically: true, encoding: .utf8)
        try await run(["add", "--", "file.txt"])
        try await run(["commit", "-m", "Base"])
        return dir
    }

    static func showHEADFile(dir: String) async throws -> String {
        let result = try await GitProcess.run(["show", "HEAD:file.txt"], workingDirectory: dir)
        guard result.exitCode == 0 else {
            throw GitError(
                kind: parseGitError(result.stderrString),
                args: ["show"], stdout: result.stdoutString,
                stderr: result.stderrString, exitCode: result.exitCode)
        }
        return result.stdoutString
    }

    /// Append two lines, commit only the first: HEAD must contain `X` but
    /// not `Y`, and the workdir must still hold `Y` as uncommitted change.
    static func testLivePartialCommit(_ failures: inout [Failure]) async {
        let test = "live-partial-commit"
        let dir: String
        do {
            dir = try await makeRepoWithFile(content: "a\nb\nc\n")
        } catch {
            check(false, "fixture failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try "a\nb\nc\nX\nY\n".write(
                toFile: (dir as NSString).appendingPathComponent("file.txt"),
                atomically: true, encoding: .utf8)
            let live = LiveGitService(repositoryPath: dir)
            let probe = WorkingDirectoryFileChange(
                path: "file.txt", status: .modified(submoduleStatus: nil),
                selection: .all)
            let diff = try await StageLiveOperations.workingDirectoryDiffForStaging(
                repositoryPath: dir, file: probe)
            guard case .text(let data) = diff,
                  let hunk = data.hunks.first,
                  let yOffset = hunk.lines.firstIndex(where: { $0.text == "+Y" })
            else {
                check(false, "no +Y in live diff", test: test, failures: &failures)
                return
            }
            let yIndex = hunk.unifiedDiffStart + yOffset
            let file = WorkingDirectoryFileChange(
                path: "file.txt", status: .modified(submoduleStatus: nil),
                selection: .all.withLineSelection(lineIndex: yIndex, selected: false))
            check(file.selection.getSelectionType() == .partial, "selection is partial",
                  test: test, failures: &failures)
            let sha = try await live.commit(context: CommitContext(
                summary: "Partial", filePaths: [file.path], files: [file]))
            check(!sha.isEmpty, "commit sha", test: test, failures: &failures)
            let head = try await showHEADFile(dir: dir)
            check(head == "a\nb\nc\nX\n", "HEAD has X only, got \(head.debugDescription)",
                  test: test, failures: &failures)
            let workdir = (try? String(
                contentsOfFile: (dir as NSString).appendingPathComponent("file.txt"),
                encoding: .utf8)) ?? ""
            check(workdir == "a\nb\nc\nX\nY\n", "workdir keeps Y, got \(workdir.debugDescription)",
                  test: test, failures: &failures)
            let status = try await live.status(includeUntracked: true)
            check(status?.workingDirectory.files.map(\.path) == ["file.txt"],
                  "Y still dirty, got \(status?.workingDirectory.files.map(\.path) ?? [])",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }

    /// Fully selected files still commit whole (regression guard).
    static func testLiveFullCommit(_ failures: inout [Failure]) async {
        let test = "live-full-commit"
        let dir: String
        do {
            dir = try await makeRepoWithFile(content: "a\n")
        } catch {
            check(false, "fixture failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try "a\nb\n".write(
                toFile: (dir as NSString).appendingPathComponent("file.txt"),
                atomically: true, encoding: .utf8)
            let live = LiveGitService(repositoryPath: dir)
            let file = WorkingDirectoryFileChange(
                path: "file.txt", status: .modified(submoduleStatus: nil),
                selection: .all)
            _ = try await live.commit(context: CommitContext(
                summary: "Full", filePaths: [file.path], files: [file]))
            let head = try await showHEADFile(dir: dir)
            check(head == "a\nb\n", "HEAD whole, got \(head.debugDescription)",
                  test: test, failures: &failures)
            let status = try await live.status(includeUntracked: true)
            check(status?.workingDirectory.files.isEmpty == true,
                  "clean WD, got \(status?.workingDirectory.files.map(\.path) ?? [])",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw: \(error)", test: test, failures: &failures)
        }
    }
}
