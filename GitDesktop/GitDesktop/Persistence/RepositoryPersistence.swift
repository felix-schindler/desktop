import Foundation

// MARK: - RepositoryPersistence
// Task 9 persistence for the repository list + selection.
//
// SwiftData migration (done): `RepositoriesDatabase` is the source of truth
// for the repository list (`Persistence/RepositoryRecord.swift`,
// `Persistence/RepositoriesDatabase.swift`). The `save`/`load` UserDefaults
// JSON snapshot below is the legacy v1 path — kept as the one-time migration
// source (`migrateIfNeeded`) and as the fallback when the SwiftData store is
// unavailable, plus the existing `Task9Tests` coverage. New code must go
// through `RepositoriesDatabase` / `AppStore.persistRepositories()` instead.
//
// Selection (`lastSelectedRepositoryID`, recent IDs) and the tutorial flag
// stay in UserDefaults by design (the reference keeps selection in local
// storage, not IndexedDB).

/// Deduplicate repositories by standardized path, keeping the lowest id.
/// Port of the reference `removeDuplicateGitHubRepositories` prune step,
/// applied to local paths (Dexie `&path` uniqueness).
nonisolated public func deduplicatedRepositories(_ repositories: [Repository]) -> [Repository] {
    let ordered = repositories.sorted { $0.id < $1.id }
    var seenIDs = Set<Int>()
    var seenPaths = Set<String>()
    var result: [Repository] = []
    result.reserveCapacity(repositories.count)
    for repository in ordered {
        guard !seenIDs.contains(repository.id) else { continue }
        let key = (repository.path as NSString).standardizingPath
        guard !seenPaths.contains(key) else { continue }
        seenIDs.insert(repository.id)
        seenPaths.insert(key)
        result.append(repository)
    }
    return result
}

public struct PersistedRepository: Codable, Sendable, Equatable {
    public var id: Int
    public var path: String
    public var alias: String?
    public var isTutorialRepository: Bool
    public var missing: Bool
    public var gitDir: String?
    public var mainWorktreePath: String?
    public var workflowPreferences: WorkflowPreferences

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case alias
        case isTutorialRepository
        case missing
        case gitDir
        case mainWorktreePath
        case workflowPreferences
    }

    nonisolated public init(
        id: Int,
        path: String,
        alias: String? = nil,
        isTutorialRepository: Bool = false,
        missing: Bool = false,
        gitDir: String? = nil,
        mainWorktreePath: String? = nil,
        workflowPreferences: WorkflowPreferences = WorkflowPreferences()
    ) {
        self.id = id
        self.path = path
        self.alias = alias
        self.isTutorialRepository = isTutorialRepository
        self.missing = missing
        self.gitDir = gitDir
        self.mainWorktreePath = mainWorktreePath
        self.workflowPreferences = workflowPreferences
    }

    nonisolated public init(_ repository: Repository) {
        self.id = repository.id
        self.path = repository.path
        self.alias = repository.alias
        self.isTutorialRepository = repository.isTutorialRepository
        self.missing = repository.missing
        self.gitDir = repository.gitDir
        self.mainWorktreePath = repository.mainWorktreePath
        self.workflowPreferences = repository.workflowPreferences
    }

    nonisolated public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        // v1 blobs only carried these four keys; everything else defaults so
        // old snapshots keep decoding after the SwiftData migration.
        isTutorialRepository = try container.decodeIfPresent(Bool.self, forKey: .isTutorialRepository) ?? false
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
        gitDir = try container.decodeIfPresent(String.self, forKey: .gitDir)
        mainWorktreePath = try container.decodeIfPresent(String.self, forKey: .mainWorktreePath)
        workflowPreferences = try container.decodeIfPresent(WorkflowPreferences.self, forKey: .workflowPreferences)
            ?? WorkflowPreferences()
    }

    nonisolated public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encode(isTutorialRepository, forKey: .isTutorialRepository)
        try container.encode(missing, forKey: .missing)
        try container.encodeIfPresent(gitDir, forKey: .gitDir)
        try container.encodeIfPresent(mainWorktreePath, forKey: .mainWorktreePath)
        try container.encode(workflowPreferences, forKey: .workflowPreferences)
    }

    nonisolated public func toRepository() -> Repository {
        Repository(
            path: path, id: id, missing: missing, alias: alias,
            workflowPreferences: workflowPreferences,
            isTutorialRepository: isTutorialRepository,
            gitDir: gitDir, mainWorktreePath: mainWorktreePath)
    }
}

public enum RepositoryPersistence {
    /// Legacy v1 snapshot write (migration source + SwiftData fallback).
    /// New code must use `RepositoriesDatabase.save(_:in:)` instead.
    public static func save(
        _ repositories: [Repository],
        selectedID: Int?,
        in store: UserDefaults = .standard
    ) {
        let snapshots = deduplicatedRepositories(repositories).map(PersistedRepository.init)
        if let data = try? JSONEncoder().encode(snapshots) {
            store.set(data, forKey: Defaults.persistedRepositories)
        }
        if let selectedID {
            store.set(selectedID, forKey: Defaults.lastSelectedRepositoryID)
        } else {
            store.removeObject(forKey: Defaults.lastSelectedRepositoryID)
        }
        Defaults.setRecentIDs(repositories.prefix(3).map(\.id), in: store)
    }

    /// Legacy v1 snapshot read (migration source + SwiftData fallback).
    public static func load(in store: UserDefaults = .standard) -> (repositories: [Repository], selectedID: Int?) {
        guard let data = store.data(forKey: Defaults.persistedRepositories),
              let snapshots = try? JSONDecoder().decode([PersistedRepository].self, from: data)
        else { return ([], nil) }
        let repositories = snapshots.map { $0.toRepository() }
        let selectedID = store.object(forKey: Defaults.lastSelectedRepositoryID) as? Int
        return (repositories, selectedID)
    }

    /// Next repository ID (max + 1, starting at 1). Port of the auto-increment
    /// in `repositories-database.ts`.
    public static func nextID(for repositories: [Repository]) -> Int {
        (repositories.map(\.id).max() ?? 0) + 1
    }

    /// Match an existing repository by resolved toplevel path.
    public static func matchExisting(repositories: [Repository], toplevel: String) -> Repository? {
        let normalized = (toplevel as NSString).standardizingPath
        return repositories.first {
            ($0.path as NSString).standardizingPath == normalized
        }
    }

    public static var hasShownWelcomeFlow: Bool {
        Defaults.bool(Defaults.hasShownWelcomeFlow, default: false)
    }

    public static func setHasShownWelcomeFlow(_ value: Bool = true) {
        Defaults.setBool(value, Defaults.hasShownWelcomeFlow)
    }
}
