import Foundation
import SwiftData

// MARK: - RepositoriesDatabase (SwiftData)
// Source of truth for the repository list. Selection + welcome flag stay in
// `UserDefaults` (see `Defaults`); only the repositories table lives here.
//
// Migration: v1 persisted a JSON blob under `Defaults.persistedRepositories`.
// `migrateIfNeeded(in:defaults:)` imports that blob once (deduplicated, full
// fields via `PersistedRepository`'s backward-compatible decoder), then
// removes the blob so later launches never re-import.

@MainActor
public enum RepositoriesDatabase {
    /// On-disk store location: `~/Library/Application Support/<bundle>/Repositories.store`.
    public static func storeURL(
        applicationSupport: URL? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        let base = applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(bundleIdentifier ?? "GitDesktop", isDirectory: true)
        return directory.appendingPathComponent("Repositories.store")
    }

    public static func makeContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema([RepositoryRecord.self])
        if inMemory {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        let url = storeURL ?? self.storeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Shared on-disk container. Falls back to in-memory (with a console
    /// note) when the store is corrupted so the app never fails to launch;
    /// callers then fall back to the legacy UserDefaults blob.
    public static var sharedContainer: ModelContainer = {
        do {
            return try makeContainer()
        } catch {
            NSLog("RepositoriesDatabase: falling back to in-memory container: \(error)")
            do {
                return try makeContainer(inMemory: true)
            } catch {
                fatalError("RepositoriesDatabase: in-memory container failed: \(error)")
            }
        }
    }()

    public static var sharedContext: ModelContext {
        sharedContainer.mainContext
    }

    // MARK: CRUD (operates on the caller's context; callers own `save()` errors)

    public static func fetchRepositories(in context: ModelContext) throws -> [Repository] {
        let descriptor = FetchDescriptor<RepositoryRecord>(
            sortBy: [SortDescriptor(\.repositoryID)])
        return try context.fetch(descriptor).map { $0.toRepository() }
    }

    /// Replace the table contents with `repositories` (upsert by id, delete
    /// stale rows). Input is deduplicated first so the `&path` uniqueness
    /// constraint from the Dexie schema can never fire.
    public static func save(_ repositories: [Repository], in context: ModelContext) throws {
        let deduped = deduplicatedRepositories(repositories)
        let descriptor = FetchDescriptor<RepositoryRecord>()
        let existing = try context.fetch(descriptor)
        var byID: [Int: RepositoryRecord] = [:]
        for record in existing { byID[record.repositoryID] = record }

        let wantedIDs = Set(deduped.map(\.id))
        for repository in deduped {
            if let record = byID[repository.id] {
                record.sync(from: repository)
            } else {
                context.insert(RepositoryRecord(repository))
            }
        }
        // Drop rows the caller no longer lists.
        for record in existing where !wantedIDs.contains(record.repositoryID) {
            context.delete(record)
        }
        // Resolve path collisions introduced by renames/relocates (keep the
        // lowest id, mirroring the legacy duplicate-prune upgrade step).
        try pruneDuplicatePaths(in: context)
        try context.save()
    }

    /// One-time import of the v1 UserDefaults JSON blob. Returns true when a
    /// migration ran. No-op when SwiftData already holds rows or when no blob
    /// exists. The selection keys are left untouched (still UserDefaults).
    @discardableResult
    public static func migrateIfNeeded(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Bool {
        let existing = try context.fetch(FetchDescriptor<RepositoryRecord>())
        guard existing.isEmpty else { return false }
        guard let data = defaults.data(forKey: Defaults.persistedRepositories),
              let snapshots = try? JSONDecoder().decode([PersistedRepository].self, from: data),
              !snapshots.isEmpty
        else { return false }
        let repositories = deduplicatedRepositories(snapshots.map { $0.toRepository() })
        for repository in repositories {
            context.insert(RepositoryRecord(repository))
        }
        try pruneDuplicatePaths(in: context)
        try context.save()
        defaults.removeObject(forKey: Defaults.persistedRepositories)
        return true
    }

    // MARK: Internals

    /// Enforce one row per standardized path (keep lowest id).
    static func pruneDuplicatePaths(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<RepositoryRecord>(
            sortBy: [SortDescriptor(\.repositoryID)])
        let records = try context.fetch(descriptor)
        var seen: Set<String> = []
        for record in records {
            let key = (record.path as NSString).standardizingPath
            if seen.contains(key) {
                context.delete(record)
            } else {
                seen.insert(key)
            }
        }
    }
}
