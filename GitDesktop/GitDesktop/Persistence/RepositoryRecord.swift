import Foundation
import SwiftData

// MARK: - RepositoryRecord (SwiftData)
// Persistent counterpart to the in-memory `Repository` struct.
// Schema ports the in-scope columns of the reference Dexie table
// (`electron/app/src/lib/databases/repositories-database.ts`):
// `repositories: '++id, &path'` + alias/missing/gitDir/mainWorktreePath/
// workflowPreferences/isTutorialRepository.
//
// Out of scope per AGENTS.md (no GitHub integration): `gitHubRepositories`,
// `owners`, and `protectedBranches` tables are NOT ported.
//
// Selection (`lastSelectedRepositoryID`, recent IDs, welcome flag) stays in
// `UserDefaults` via `Defaults` — the reference keeps selection in local
// storage, not in IndexedDB.

@Model
public final class RepositoryRecord {
    @Attribute(.unique) public var repositoryID: Int
    @Attribute(.unique) public var path: String
    public var alias: String?
    public var missing: Bool
    public var gitDir: String?
    public var mainWorktreePath: String?
    public var isTutorialRepository: Bool
    public var forkContributionTargetRaw: String?

    public init(
        repositoryID: Int,
        path: String,
        alias: String? = nil,
        missing: Bool = false,
        gitDir: String? = nil,
        mainWorktreePath: String? = nil,
        isTutorialRepository: Bool = false,
        forkContributionTargetRaw: String? = nil
    ) {
        self.repositoryID = repositoryID
        self.path = path
        self.alias = alias
        self.missing = missing
        self.gitDir = gitDir
        self.mainWorktreePath = mainWorktreePath
        self.isTutorialRepository = isTutorialRepository
        self.forkContributionTargetRaw = forkContributionTargetRaw
    }

    public convenience init(_ repository: Repository) {
        self.init(
            repositoryID: repository.id,
            path: repository.path,
            alias: repository.alias,
            missing: repository.missing,
            gitDir: repository.gitDir,
            mainWorktreePath: repository.mainWorktreePath,
            isTutorialRepository: repository.isTutorialRepository,
            forkContributionTargetRaw: repository.workflowPreferences.forkContributionTarget?.rawValue
        )
    }

    public func toRepository() -> Repository {
        let target = forkContributionTargetRaw.flatMap(ForkContributionTarget.init(rawValue:))
        return Repository(
            path: path,
            id: repositoryID,
            missing: missing,
            alias: alias,
            workflowPreferences: WorkflowPreferences(forkContributionTarget: target),
            isTutorialRepository: isTutorialRepository,
            gitDir: gitDir,
            mainWorktreePath: mainWorktreePath
        )
    }

    /// Sync mutable fields from an in-memory value (upsert path).
    public func sync(from repository: Repository) {
        path = repository.path
        alias = repository.alias
        missing = repository.missing
        gitDir = repository.gitDir
        mainWorktreePath = repository.mainWorktreePath
        isTutorialRepository = repository.isTutorialRepository
        forkContributionTargetRaw = repository.workflowPreferences.forkContributionTarget?.rawValue
    }
}
