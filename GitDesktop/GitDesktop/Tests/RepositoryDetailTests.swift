import Foundation

// MARK: - RepositoryDetailTests (Task 12)
// Pure helper tests + live fixture for the shell diff loaders. Same harness
// style as `GitStoreTests` (no test bundle; `runAll()` returns failures).
// Async because diff/file loading hits real git in a temp fixture repo.

@MainActor
public enum RepositoryDetailTests {
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
        testBranchName(&failures)
        testFilterCommits(&failures)
        testLocalSHAs(&failures)
        testOrderedSelection(&failures)
        testLocalAuthors(&failures)
        testNumstatTotals(&failures)
        await testWorkingDirectoryDiffFixture(&failures)
        await testCommitFilesAndDiffFixture(&failures)
        if failures.isEmpty {
            print("RepositoryDetailTests: all tests passed")
        } else {
            print("RepositoryDetailTests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Pure helpers

    static func testBranchName(_ failures: inout [Failure]) {
        let test = "branch-name"
        let main = Branch(name: "main", upstream: nil, tip: BranchTip(sha: "aaa"), type: .local, ref: "refs/heads/main")
        check(repositoryBranchName(tip: .valid(branch: main)) == "main", "valid", test: test, failures: &failures)
        check(repositoryBranchName(tip: .unborn(ref: "refs/heads/feature")) == "feature", "unborn strips", test: test, failures: &failures)
        check(repositoryBranchName(tip: .detached(currentSha: "abc")) == nil, "detached nil", test: test, failures: &failures)
        check(repositoryBranchName(tip: .unknown) == nil, "unknown nil", test: test, failures: &failures)
    }

    static func testFilterCommits(_ failures: inout [Failure]) {
        let test = "filter"
        let identity = CommitIdentity(name: "Ada Lovelace", email: "ada@example.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        let other = CommitIdentity(name: "Grace Hopper", email: "grace@example.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        let c1 = Commit(sha: "aaa1111", shortSha: "aaa1111", summary: "Add engine", body: "", author: identity, committer: identity, parentSHAs: [], trailers: [])
        let c2 = Commit(sha: "bbb2222", shortSha: "bbb2222", summary: "Fix brakes", body: "", author: other, committer: other, parentSHAs: [], trailers: [])
        check(filterHistoryCommits([c1, c2], filterText: "").count == 2, "empty → all", test: test, failures: &failures)
        check(filterHistoryCommits([c1, c2], filterText: "engine") == [c1], "summary", test: test, failures: &failures)
        check(filterHistoryCommits([c1, c2], filterText: "BBB") == [c2], "sha case-insensitive", test: test, failures: &failures)
        check(filterHistoryCommits([c1, c2], filterText: "grace") == [c2], "author", test: test, failures: &failures)
        check(filterHistoryCommits([c1, c2], filterText: "nope").isEmpty, "no match", test: test, failures: &failures)
    }

    static func testLocalSHAs(_ failures: inout [Failure]) {
        let test = "local-shas"
        let identity = CommitIdentity(name: "A", email: "a@x.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        func commit(_ sha: String) -> Commit {
            Commit(sha: sha, shortSha: sha, summary: "S", body: "", author: identity, committer: identity, parentSHAs: [], trailers: [])
        }
        let commits = [commit("a"), commit("b"), commit("c")]
        check(localCommitSHAs(commits: commits, ahead: nil).isEmpty, "nil → empty", test: test, failures: &failures)
        check(localCommitSHAs(commits: commits, ahead: 0).isEmpty, "0 → empty", test: test, failures: &failures)
        check(localCommitSHAs(commits: commits, ahead: 2) == ["a", "b"], "first N", test: test, failures: &failures)
    }

    static func testOrderedSelection(_ failures: inout [Failure]) {
        let test = "ordered-selection"
        let identity = CommitIdentity(name: "A", email: "a@x.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        func commit(_ sha: String) -> Commit {
            Commit(sha: sha, shortSha: sha, summary: "S", body: "", author: identity, committer: identity, parentSHAs: [], trailers: [])
        }
        let commits = [commit("a"), commit("b"), commit("c")]
        let ordered = orderedSelectedCommits(commits: commits, selectedSHAs: ["c", "a"])
        check(ordered.map(\.sha) == ["a", "c"], "display order, got \(ordered.map(\.sha))", test: test, failures: &failures)
    }

    static func testLocalAuthors(_ failures: inout [Failure]) {
        let test = "local-authors"
        let ada = CommitIdentity(name: "Ada", email: "ada@x.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        let ada2 = CommitIdentity(name: "Ada L", email: "ADA@x.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        let grace = CommitIdentity(name: "Grace", email: "grace@x.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        func commit(_ id: CommitIdentity) -> Commit {
            Commit(sha: UUID().uuidString, shortSha: "abc", summary: "S", body: "", author: id, committer: id, parentSHAs: [], trailers: [])
        }
        let authors = repositoryLocalAuthors(commits: [commit(ada), commit(ada2), commit(grace)])
        check(authors.count == 2, "dedupe by email, got \(authors.count)", test: test, failures: &failures)
    }

    static func testNumstatTotals(_ failures: inout [Failure]) {
        let test = "numstat"
        let stdout = ":100644 100644 abc def M\0README.md\01\t2\tREADME.md\0-\t3\timage.png\0"
        let (added, deleted) = RepositoryDetailLoading.numstatTotals(stdout)
        check(added == 1 && deleted == 2, "binary `-` rows count 0, got \(added)/\(deleted)", test: test, failures: &failures)
    }

    // MARK: - Live fixture

    static func makeFixtureRepo() async throws -> (dir: String, sha: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoDetailTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func run(_ args: [String]) async throws {
            let result = try await GitProcess.run(args, workingDirectory: dir)
            guard result.exitCode == 0 else {
                throw GitError(kind: parseGitError(result.stderrString), args: args, stdout: result.stdoutString, stderr: result.stderrString, exitCode: result.exitCode)
            }
        }
        try await run(["-c", "init.defaultBranch=main", "init"])
        try await run(["config", "user.name", "Detail Tests"])
        try await run(["config", "user.email", "detail@example.com"])
        try "hello\n".write(toFile: (dir as NSString).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await run(["add", "--", "README.md"])
        try await run(["commit", "-m", "Initial commit"])
        let shaResult = try await GitProcess.run(["rev-parse", "HEAD"], workingDirectory: dir)
        let sha = shaResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dirty: modified tracked + untracked.
        try "hello world\n".write(toFile: (dir as NSString).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "untracked\n".write(toFile: (dir as NSString).appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        return (dir, sha)
    }

    static func testWorkingDirectoryDiffFixture(_ failures: inout [Failure]) async {
        let test = "workdir-diff"
        let dir: String
        do {
            (dir, _) = try await makeFixtureRepo()
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let modified = WorkingDirectoryFileChange(
            path: "README.md",
            status: .modified(submoduleStatus: nil),
            selection: .fromInitialSelection(.all))
        do {
            let result = try await RepositoryDetailLoading.workingDirectoryDiff(
                repositoryPath: dir, file: modified, hideWhitespace: false)
            switch result.diff {
            case .text(let data):
                check(!data.hunks.isEmpty, "modified has hunks", test: test, failures: &failures)
            default:
                check(false, "expected text diff, got \(result.diff.type)", test: test, failures: &failures)
            }
            check(!(result.contents?.newLines.isEmpty ?? true), "new contents loaded", test: test, failures: &failures)
        } catch {
            check(false, "workdir diff threw: \(error)", test: test, failures: &failures)
        }
        let untracked = WorkingDirectoryFileChange(
            path: "new.txt",
            status: .untracked(submoduleStatus: nil),
            selection: .fromInitialSelection(.all))
        do {
            let result = try await RepositoryDetailLoading.workingDirectoryDiff(
                repositoryPath: dir, file: untracked, hideWhitespace: false)
            switch result.diff {
            case .text(let data):
                check(!data.hunks.isEmpty, "untracked has hunks", test: test, failures: &failures)
            default:
                check(false, "expected text for untracked, got \(result.diff.type)", test: test, failures: &failures)
            }
        } catch {
            check(false, "untracked diff threw: \(error)", test: test, failures: &failures)
        }
    }

    static func testCommitFilesAndDiffFixture(_ failures: inout [Failure]) async {
        let test = "commit-diff"
        let dir: String
        let sha: String
        do {
            (dir, sha) = try await makeFixtureRepo()
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Build the Commit without `LiveGitService` so the CLI harness stays
        // Foundation-only (no Operations/Auth/AppStore deps).
        let identity = CommitIdentity(name: "Detail Tests", email: "detail@example.com", date: Date(timeIntervalSince1970: 0), tzOffset: 0)
        let commit = Commit(sha: sha, shortSha: String(sha.prefix(7)), summary: "Initial commit", body: "", author: identity, committer: identity, parentSHAs: [], trailers: [])
        let commits = [commit]
        check(!sha.isEmpty, "log sha", test: test, failures: &failures)
        do {
            let changeset = try await RepositoryDetailLoading.commitChangedFiles(
                repositoryPath: dir, selected: [commits[0]])
            let paths = Set(changeset.files.map(\.path))
            check(paths.contains("README.md"), "commit files \(paths)", test: test, failures: &failures)
            guard let file = changeset.files.first(where: { $0.path == "README.md" }) else { return }
            let diff = try await RepositoryDetailLoading.commitDiff(
                repositoryPath: dir, file: file, selected: [commits[0]], hideWhitespace: false)
            switch diff.diff {
            case .text(let data):
                check(!data.hunks.isEmpty, "commit diff has hunks", test: test, failures: &failures)
            default:
                check(false, "expected text commit diff, got \(diff.diff.type)", test: test, failures: &failures)
            }
            check(!(diff.contents?.newLines.isEmpty ?? true), "commit contents loaded", test: test, failures: &failures)
        } catch {
            check(false, "commit files/diff threw: \(error)", test: test, failures: &failures)
        }
    }
}
