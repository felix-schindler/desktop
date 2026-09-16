import Foundation

// MARK: - DefaultBranchOperations
// Port of `electron/app/src/lib/find-default-branch.ts` +
// `lib/git/refs.ts#getSymbolicRef` + `lib/git/remote.ts#getRemoteHEAD`.
//
// The pipeline previously used a local-only heuristic (`main` → `master` →
// first sorted). That stays as the fallback, but `GitStore.refresh` now
// resolves `refs/remotes/<remote>/HEAD` via `symbolic-ref` first so a repo
// whose default is `develop`/`trunk`/etc. picks the right branch.

/// Read a symbolic ref (nil when missing/not-a-symref).
/// Port of `getSymbolicRef`: exit 1/128 in quiet mode mean "no such symref".
nonisolated public func getSymbolicRef(repositoryPath: String, ref: String) async -> String? {
    do {
        let result = try await GitProcess.run(
            ["symbolic-ref", "-q", ref],
            workingDirectory: repositoryPath)
        if result.exitCode == 1 || result.exitCode == 128 {
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        return RefsParser.parseSymbolicRef(result.stdoutString)
    } catch {
        return nil
    }
}

/// Resolve the default branch name for `remote` via `refs/remotes/<remote>/HEAD`.
/// Port of `getRemoteHEAD` in `remote.ts`.
nonisolated public func getRemoteHEAD(repositoryPath: String, remote: String) async -> String? {
    let namespace = "refs/remotes/\(remote)/"
    guard let match = await getSymbolicRef(repositoryPath: repositoryPath, ref: "\(namespace)HEAD") else {
        return nil
    }
    guard match.hasPrefix(namespace), match.count > namespace.count else {
        return nil
    }
    return String(match.dropFirst(namespace.count))
}

/// Reference-priority resolution: local branch tracking the remote default
/// first, then local branch matching the default name, then the remote
/// branch itself. Pure so the `swiftc` harness covers it without git.
nonisolated public func resolveDefaultBranch(
    branches: [Branch],
    defaultBranchName: String,
    remoteRef: String?
) -> Branch? {
    var localHit: Branch?
    var localTrackingHit: Branch?
    var remoteHit: Branch?
    for branch in branches {
        if branch.type == .local {
            if branch.name == defaultBranchName {
                localHit = branch
            }
            if let remoteRef, branch.upstream == remoteRef {
                if case .none = localTrackingHit {
                    localTrackingHit = branch
                } else if branch.name == defaultBranchName {
                    localTrackingHit = branch
                }
            }
        } else if let remoteRef, branch.name == remoteRef {
            remoteHit = branch
        }
    }
    return localTrackingHit ?? localHit ?? remoteHit
}

// MARK: - Remote HEAD resolving (mockable seam)

/// Additive seam so `GitStore.refresh` resolves `origin/HEAD` without
/// branching on concrete service types (mirrors `SyncOperations`):
/// `LiveGitService` runs real `symbolic-ref`, `MockGitService` returns its
/// stub. Services that don't conform (e.g. test failure injectors) skip
/// remote resolution and fall back to the local heuristic.
public protocol RemoteHEADResolving: GitService {
    func remoteHEAD(remote: String) async -> String?
    /// Global `init.defaultBranch` fallback (port of `getDefaultBranch`).
    /// Mock returns its stub with no git I/O so previews/tests stay hermetic.
    func defaultBranchFallbackName() async -> String
}

extension LiveGitService: RemoteHEADResolving {
    public func remoteHEAD(remote: String) async -> String? {
        await getRemoteHEAD(repositoryPath: repositoryPath, remote: remote)
    }

    public func defaultBranchFallbackName() async -> String {
        await getDefaultBranch()
    }
}

extension MockGitService: RemoteHEADResolving {
    public func remoteHEAD(remote: String) async -> String? {
        _ = remote
        return stubRemoteHEAD
    }

    public func defaultBranchFallbackName() async -> String {
        stubDefaultBranchName
    }
}
