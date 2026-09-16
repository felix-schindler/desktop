import Foundation

/// A local repository.
/// Direct port of `electron/app/src/models/repository.ts` minus
/// `gitHubRepository` (deleted per scope: `RepositoryWithGitHubRepository`
/// collapses to `Repository`).
public struct Repository: Identifiable, Hashable, Sendable {
    public let path: String
    public let id: Int
    public var missing: Bool
    public var alias: String?
    public var workflowPreferences: WorkflowPreferences
    public var isTutorialRepository: Bool
    public var gitDir: String?
    public var mainWorktreePath: String?

    nonisolated public init(
        path: String,
        id: Int,
        missing: Bool = false,
        alias: String? = nil,
        workflowPreferences: WorkflowPreferences = WorkflowPreferences(),
        isTutorialRepository: Bool = false,
        gitDir: String? = nil,
        mainWorktreePath: String? = nil
    ) {
        self.path = path
        self.id = id
        self.missing = missing
        self.alias = alias
        self.workflowPreferences = workflowPreferences
        self.isTutorialRepository = isTutorialRepository
        self.gitDir = gitDir
        self.mainWorktreePath = mainWorktreePath
    }

    /// Display name: alias if set, else the basename of the path.
    /// (Original fell back to the GitHub repo name; that source is deleted.)
    nonisolated public var name: String {
        if let alias, !alias.isEmpty { return alias }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }

    /// Structural hash used for equality checks and state-cache keys.
    nonisolated public var hash: String {
        [
            path,
            String(id),
            String(missing),
            alias ?? "",
            workflowPreferences.forkContributionTarget?.rawValue ?? "",
            String(isTutorialRepository),
        ].joined(separator: "+")
    }

    /// Resolved path to the `.git` directory.
    nonisolated public var resolvedGitDir: String {
        gitDir ?? (path as NSString).appendingPathComponent(".git")
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }

    nonisolated public static func == (lhs: Repository, rhs: Repository) -> Bool {
        lhs.hash == rhs.hash
    }
}

/// Per-repository lightweight lookup data (mirrors `ILocalRepositoryState`).
public struct LocalRepositoryState: Sendable, Equatable {
    public var aheadBehind: AheadBehind?
    public var changedFilesCount: Int

    nonisolated public init(aheadBehind: AheadBehind? = nil, changedFilesCount: Int = 0) {
        self.aheadBehind = aheadBehind
        self.changedFilesCount = changedFilesCount
    }
}
