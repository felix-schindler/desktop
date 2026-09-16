import Foundation

/// Main vs linked worktree. Port of `WorktreeType`.
public enum WorktreeType: String, Codable, Sendable {
    case main
    case linked
}

/// One row of `git worktree list --porcelain -z`. Port of `WorktreeEntry`.
public struct WorktreeEntry: Sendable, Equatable, Identifiable {
    public var path: String
    public var head: String
    /// Full ref name (e.g. `refs/heads/main`), nil when HEAD is detached.
    public var branch: String?
    nonisolated public var isDetached: Bool { branch == nil }
    public var type: WorktreeType
    public var isLocked: Bool
    public var isPrunable: Bool

    nonisolated public init(
        path: String,
        head: String,
        branch: String?,
        type: WorktreeType,
        isLocked: Bool,
        isPrunable: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.type = type
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    nonisolated public var id: String { path }
}

nonisolated public func worktreeDisplayName(_ worktree: WorktreeEntry) -> String {
    (worktree.path as NSString).lastPathComponent
}

nonisolated public func worktreeDescription(_ worktree: WorktreeEntry) -> String {
    if let branch = worktree.branch {
        return branch.replacingOccurrences(of: #"^refs/heads/"#, with: "", options: .regularExpression)
    }
    return shortenSHA(worktree.head)
}
