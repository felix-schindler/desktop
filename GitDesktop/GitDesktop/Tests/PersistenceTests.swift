#if TESTBUILD
@testable import GitDesktop
#endif
import Foundation
import SwiftData

// MARK: - PersistenceTests
// SwiftData migration coverage: full-field legacy roundtrip, v1 blob
// backward compatibility, path-dedupe pruning, in-memory CRUD, and the
// one-time UserDefaults → SwiftData migration.

@MainActor
public enum PersistenceTests {
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
        testLegacyFullFieldRoundtrip(&failures)
        testLegacyV1BlobCompat(&failures)
        testDedupe(&failures)
        testSwiftDataRoundtrip(&failures)
        testSwiftDataUpsertAndDelete(&failures)
        testSwiftDataDedupesOnSave(&failures)
        testMigration(&failures)
        testMigrationNoOpWhenPopulated(&failures)
        await testRelocateResolvesIdentity(&failures)
        await testRelocateRejectsNonRepo(&failures)
        if failures.isEmpty {
            print("PersistenceTests: all tests passed")
        } else {
            print("PersistenceTests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    private static func makeContext() throws -> ModelContext {
        ModelContext(try RepositoriesDatabase.makeContainer(inMemory: true))
    }

    private static func repo(
        _ path: String, id: Int, alias: String? = nil, missing: Bool = false,
        gitDir: String? = nil, mainWorktreePath: String? = nil,
        tutorial: Bool = false, forkTarget: ForkContributionTarget? = nil
    ) -> Repository {
        Repository(
            path: path, id: id, missing: missing, alias: alias,
            workflowPreferences: WorkflowPreferences(forkContributionTarget: forkTarget),
            isTutorialRepository: tutorial, gitDir: gitDir,
            mainWorktreePath: mainWorktreePath)
    }

    // MARK: Legacy UserDefaults path

    static func testLegacyFullFieldRoundtrip(_ failures: inout [Failure]) {
        let test = "legacy-full-fields"
        let store = UserDefaults(suiteName: "PersistenceTestsLegacy")!
        store.removePersistentDomain(forName: "PersistenceTestsLegacy")
        defer { store.removePersistentDomain(forName: "PersistenceTestsLegacy") }
        let repos = [
            repo("/a", id: 1, alias: "A", missing: true, gitDir: "/a/.git",
                 mainWorktreePath: "/main", tutorial: true, forkTarget: .parent),
            repo("/b", id: 2),
        ]
        RepositoryPersistence.save(repos, selectedID: 1, in: store)
        let loaded = RepositoryPersistence.load(in: store)
        check(loaded.repositories.count == 2, "count \(loaded.repositories.count)", test: test, failures: &failures)
        check(loaded.selectedID == 1, "selected", test: test, failures: &failures)
        let first = loaded.repositories.first(where: { $0.id == 1 })
        check(first?.alias == "A", "alias", test: test, failures: &failures)
        check(first?.missing == true, "missing survives", test: test, failures: &failures)
        check(first?.gitDir == "/a/.git", "gitDir survives", test: test, failures: &failures)
        check(first?.mainWorktreePath == "/main", "worktree survives", test: test, failures: &failures)
        check(first?.isTutorialRepository == true, "tutorial survives", test: test, failures: &failures)
        check(first?.workflowPreferences.forkContributionTarget == .parent, "prefs survive", test: test, failures: &failures)
    }

    static func testLegacyV1BlobCompat(_ failures: inout [Failure]) {
        let test = "legacy-v1-compat"
        // Hand-written v1 blob: only the four original keys.
        let json = #"[{"id":7,"path":"/old","alias":"Old","isTutorialRepository":false}]"#
        let decoded = try? JSONDecoder().decode([PersistedRepository].self, from: Data(json.utf8))
        check(decoded?.count == 1, "decodes", test: test, failures: &failures)
        let repository = decoded?.first?.toRepository()
        check(repository?.id == 7 && repository?.path == "/old", "fields", test: test, failures: &failures)
        check(repository?.missing == false, "missing defaults", test: test, failures: &failures)
        check(repository?.gitDir == nil, "gitDir defaults", test: test, failures: &failures)
        check(repository?.mainWorktreePath == nil, "worktree defaults", test: test, failures: &failures)
        check(repository?.workflowPreferences == WorkflowPreferences(), "prefs default", test: test, failures: &failures)
    }

    static func testDedupe(_ failures: inout [Failure]) {
        let test = "dedupe"
        let repos = [
            repo("/b", id: 2),
            repo("/a", id: 1),
            repo("/a/", id: 3), // same standardized path as /a → dropped
            repo("/c", id: 2), // duplicate id → dropped
        ]
        let deduped = deduplicatedRepositories(repos)
        check(deduped.map(\.id) == [1, 2], "keeps lowest id per path, got \(deduped.map(\.id))", test: test, failures: &failures)
        check(RepositoryPersistence.nextID(for: deduped) == 3, "next id", test: test, failures: &failures)
        check(RepositoryPersistence.matchExisting(repositories: deduped, toplevel: "/a/")?.id == 1, "match standardizes", test: test, failures: &failures)
    }

    // MARK: SwiftData CRUD

    static func testSwiftDataRoundtrip(_ failures: inout [Failure]) {
        let test = "swiftdata-roundtrip"
        do {
            let context = try makeContext()
            let repos = [
                repo("/a", id: 1, alias: "A", gitDir: "/a/.git", forkTarget: .self),
                repo("/b", id: 2, missing: true, mainWorktreePath: "/main", tutorial: true),
            ]
            try RepositoriesDatabase.save(repos, in: context)
            let loaded = try RepositoriesDatabase.fetchRepositories(in: context)
            check(loaded.count == 2, "count \(loaded.count)", test: test, failures: &failures)
            check(loaded.map(\.id) == [1, 2], "sorted by id", test: test, failures: &failures)
            check(loaded.first?.alias == "A", "alias", test: test, failures: &failures)
            check(loaded.first?.gitDir == "/a/.git", "gitDir", test: test, failures: &failures)
            check(loaded.first?.workflowPreferences.forkContributionTarget == .self, "prefs", test: test, failures: &failures)
            check(loaded.last?.missing == true, "missing", test: test, failures: &failures)
            check(loaded.last?.mainWorktreePath == "/main", "worktree", test: test, failures: &failures)
            check(loaded.last?.isTutorialRepository == true, "tutorial", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
    }

    static func testSwiftDataUpsertAndDelete(_ failures: inout [Failure]) {
        let test = "swiftdata-upsert-delete"
        do {
            let context = try makeContext()
            try RepositoriesDatabase.save([repo("/a", id: 1), repo("/b", id: 2)], in: context)
            // Update id 1, drop id 2, add id 3.
            try RepositoriesDatabase.save(
                [repo("/a", id: 1, alias: "Renamed"), repo("/c", id: 3)], in: context)
            let loaded = try RepositoriesDatabase.fetchRepositories(in: context)
            check(loaded.map(\.id) == [1, 3], "stale deleted, got \(loaded.map(\.id))", test: test, failures: &failures)
            check(loaded.first?.alias == "Renamed", "upsert updates", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
    }

    static func testSwiftDataDedupesOnSave(_ failures: inout [Failure]) {
        let test = "swiftdata-dedupe"
        do {
            let context = try makeContext()
            try RepositoriesDatabase.save([repo("/a", id: 1), repo("/a/", id: 9)], in: context)
            let loaded = try RepositoriesDatabase.fetchRepositories(in: context)
            check(loaded.map(\.id) == [1], "lowest id wins, got \(loaded.map(\.id))", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
    }

    // MARK: Migration

    static func testMigration(_ failures: inout [Failure]) {
        let test = "migration"
        let store = UserDefaults(suiteName: "PersistenceTestsMigration")!
        store.removePersistentDomain(forName: "PersistenceTestsMigration")
        defer { store.removePersistentDomain(forName: "PersistenceTestsMigration") }
        do {
            let context = try makeContext()
            RepositoryPersistence.save(
                [repo("/a", id: 1, alias: "A", gitDir: "/a/.git"), repo("/b", id: 2)],
                selectedID: 2, in: store)
            let migrated = try RepositoriesDatabase.migrateIfNeeded(in: context, defaults: store)
            check(migrated == true, "reports migration", test: test, failures: &failures)
            let loaded = try RepositoriesDatabase.fetchRepositories(in: context)
            check(loaded.count == 2, "rows imported", test: test, failures: &failures)
            check(loaded.first?.gitDir == "/a/.git", "fields survive", test: test, failures: &failures)
            check(store.data(forKey: Defaults.persistedRepositories) == nil, "blob removed", test: test, failures: &failures)
            check(store.object(forKey: Defaults.lastSelectedRepositoryID) as? Int == 2, "selection kept", test: test, failures: &failures)
            let again = try RepositoriesDatabase.migrateIfNeeded(in: context, defaults: store)
            check(again == false, "idempotent", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
    }

    static func testMigrationNoOpWhenPopulated(_ failures: inout [Failure]) {
        let test = "migration-noop"
        let store = UserDefaults(suiteName: "PersistenceTestsMigrationNoop")!
        store.removePersistentDomain(forName: "PersistenceTestsMigrationNoop")
        defer { store.removePersistentDomain(forName: "PersistenceTestsMigrationNoop") }
        do {
            let context = try makeContext()
            try RepositoriesDatabase.save([repo("/kept", id: 1)], in: context)
            RepositoryPersistence.save([repo("/other", id: 5)], selectedID: 5, in: store)
            let migrated = try RepositoriesDatabase.migrateIfNeeded(in: context, defaults: store)
            check(migrated == false, "does not overwrite", test: test, failures: &failures)
            let loaded = try RepositoriesDatabase.fetchRepositories(in: context)
            check(loaded.map(\.path) == ["/kept"], "rows untouched", test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
    }

    // MARK: Relocation (live git fixtures)

    private static func makeGitRepo() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func run(_ args: [String]) async throws {
            let result = try await GitProcess.run(args, workingDirectory: dir)
            guard result.exitCode == 0 else {
                throw GitError(
                    kind: nil, args: args, stdout: result.stdoutString,
                    stderr: result.stderrString, exitCode: result.exitCode)
            }
        }
        try await run(["-c", "init.defaultBranch=main", "init"])
        try await run(["config", "user.name", "Persistence Tests"])
        try await run(["config", "user.email", "persistence@example.com"])
        try await run(["commit", "--allow-empty", "-m", "init"])
        return dir
    }

    static func testRelocateResolvesIdentity(_ failures: inout [Failure]) async {
        let test = "relocate-identity"
        let dir: String
        do {
            dir = try await makeGitRepo()
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Stale identity from the old location must be replaced, not kept.
        let stale = repo("/gone", id: 1, alias: "Kept", missing: true,
                         gitDir: "/gone/.git", mainWorktreePath: "/old-main")
        do {
            let updated = try await relocatedRepository(stale, to: dir)
            check(updated.id == 1, "id preserved", test: test, failures: &failures)
            check(updated.alias == "Kept", "alias preserved", test: test, failures: &failures)
            check(updated.path == dir, "path \(updated.path)", test: test, failures: &failures)
            check(updated.missing == false, "clears missing", test: test, failures: &failures)
            check(updated.gitDir == (dir as NSString).appendingPathComponent(".git"),
                  "gitDir re-resolved, got \(updated.gitDir ?? "nil")", test: test, failures: &failures)
            check(updated.mainWorktreePath.map(canonicalRepoPath) == canonicalRepoPath(dir),
                  "main worktree re-resolved, got \(updated.mainWorktreePath ?? "nil")",
                  test: test, failures: &failures)
        } catch {
            check(false, "threw \(error)", test: test, failures: &failures)
        }
    }

    static func testRelocateRejectsNonRepo(_ failures: inout [Failure]) async {
        let test = "relocate-rejects-non-repo"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests-plain-\(UUID().uuidString)").path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            check(false, "fixture setup failed: \(error)", test: test, failures: &failures)
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            _ = try await relocatedRepository(repo("/gone", id: 2), to: dir)
            check(false, "non-repo should throw", test: test, failures: &failures)
        } catch let error as GitError {
            check(error.kind == .notAGitRepository, "kind \(String(describing: error.kind))", test: test, failures: &failures)
        } catch {
            check(false, "wrong error \(error)", test: test, failures: &failures)
        }
    }
}
