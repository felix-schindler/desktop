import Foundation

// MARK: - AppStore+Onboarding (Task 9 additive seam)
// Persistence + repository add/locate helpers. Task 1/2 own `AppState.swift`;
// this extension only adds Task 9 behavior so parallel tasks keep compiling.

@MainActor
public extension AppStore {
    // MARK: Persistence

    func persistRepositories() {
        let selectedID = selectedRepository?.id
        do {
            try RepositoriesDatabase.save(repositories, in: RepositoriesDatabase.sharedContext)
            // Selection stays in UserDefaults by design (the reference keeps
            // selection in local storage, not IndexedDB).
            if let selectedID {
                UserDefaults.standard.set(selectedID, forKey: Defaults.lastSelectedRepositoryID)
            } else {
                UserDefaults.standard.removeObject(forKey: Defaults.lastSelectedRepositoryID)
            }
            Defaults.setRecentIDs(repositories.prefix(3).map(\.id))
        } catch {
            NSLog("persistRepositories: SwiftData save failed, falling back to UserDefaults: \(error)")
            RepositoryPersistence.save(repositories, selectedID: selectedID)
        }
    }

    func restorePersistedRepositories() {
        let context = RepositoriesDatabase.sharedContext
        // One-time import of the v1 UserDefaults blob (no-op when SwiftData
        // already holds rows or no blob exists).
        _ = try? RepositoriesDatabase.migrateIfNeeded(in: context)
        let repos: [Repository]
        let selectedID: Int?
        if let stored = try? RepositoriesDatabase.fetchRepositories(in: context),
           !stored.isEmpty {
            repos = stored
            selectedID = UserDefaults.standard.object(forKey: Defaults.lastSelectedRepositoryID) as? Int
        } else {
            // Fallback: legacy blob (pre-migration installs, or SwiftData
            // unavailable after a failed save that wrote the blob instead).
            let legacy = RepositoryPersistence.load()
            guard !legacy.repositories.isEmpty else { return }
            repos = legacy.repositories
            selectedID = legacy.selectedID
        }
        // Drop entries whose paths vanished → mark missing (port of the
        // reference startup missing-repo scan).
        let checked = repos.map { repo -> Repository in
            var copy = repo
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDir) {
                copy.missing = true
            }
            return copy
        }
        setRepositories(checked)
        for repo in checked {
            if repositoryStates[repo.hash] == nil {
                repositoryStates[repo.hash] = RepositoryState(repository: repo)
            }
        }
        if let selectedID, let match = checked.first(where: { $0.id == selectedID }) {
            if match.missing {
                selectMissingRepository(match)
            } else {
                selectRepository(match)
            }
        } else if let first = checked.first {
            selectRepository(first)
        }
    }

    func nextRepositoryID() -> Int {
        RepositoryPersistence.nextID(for: repositories)
    }

    // MARK: Add / locate

    /// Add a local path: resolve toplevel, match existing else create.
    /// Returns the repository that was selected (or matched).
    @discardableResult
    func addLocalRepository(at path: String) async throws -> Repository {
        let normalized = normalizeRepositoryPath(path)
        let toplevel = try await toplevelForPath(normalized) ?? normalized
        if let existing = RepositoryPersistence.matchExisting(repositories: repositories, toplevel: toplevel) {
            selectRepository(existing)
            return existing
        }
        let type = try await repositoryType(at: toplevel)
        switch type {
        case .bare:
            throw GitError(kind: nil, args: ["add", toplevel], stdout: "", stderr: "The path is a bare repository, which cannot be opened.", exitCode: 128)
        case .unsafe(let unsafePath):
            throw GitError(kind: .unsafeDirectory, args: ["add", toplevel], stdout: "", stderr: "Git blocked this repository as dubiously owned: \(unsafePath)", exitCode: 128)
        case .missing:
            throw GitError(kind: .notAGitRepository, args: ["add", toplevel], stdout: "", stderr: "The path is not a git repository.", exitCode: 128)
        case .regular(let top, let gitDir):
            let repo = Repository(path: top, id: nextRepositoryID(), gitDir: gitDir)
            addRepositories([repo])
            persistRepositories()
            return repo
        }
    }

    /// Relocate a missing repository to a new path.
    func relocateRepository(_ repository: Repository, to newPath: String) async throws -> Repository {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else {
            return repository
        }
        // Identity (gitDir/main worktree) is re-resolved from disk; invalid
        // targets throw and leave the entry untouched.
        let updated = try await relocatedRepository(repositories[index], to: newPath)
        var merged = repositories
        merged[index] = updated
        setRepositories(merged)
        repositoryStates.removeValue(forKey: repository.hash)
        repositoryStates[updated.hash] = RepositoryState(repository: updated)
        // Drop the stale pipeline actor (bound to the old path); the
        // subsequent `selectRepository` creates a fresh Live service.
        gitStores.removeValue(forKey: repository.hash)
        refreshingRepositoryHashes.remove(repository.hash)
        if updated.missing {
            selectMissingRepository(updated)
        } else {
            selectRepository(updated)
        }
        persistRepositories()
        return updated
    }
}
