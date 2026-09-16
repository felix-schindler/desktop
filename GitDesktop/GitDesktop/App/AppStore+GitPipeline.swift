import Foundation

// MARK: - AppStore+GitPipeline (Task 11)
// Additive pipeline seam on top of Task-1 `AppStore` (see `AppState.swift`).
// Owns the `GitStore` actor cache, triggers `refresh()` on selection, and
// maps failures to `.error` / Missing — never crashing.
//
// Tasks 12–14 code against this contract (plus `MockGitService` for
// previews), never redefine it:
// - `gitStore(for:)` — cached actor for a repository (creates via
//   `makeService`, seeds from the current `RepositoryState`).
// - `gitService(for:)` — the actor's service for thin view adapters that
//   still need direct calls (diff contents, commit files).
// - `refreshRepository(_:)` — `await store.refresh()` + publish, with
//   missing/error routing.
// - `performPipelineMutation(for:work:)` — mutations through the actor.

@MainActor
public extension AppStore {
    // MARK: Cache

    /// Cached pipeline actor for `repository`, creating it on demand.
    /// The actor is seeded from the current `RepositoryState` so the first
    /// `refresh()` preserves drafts (`commitMessage`, `selection`).
    func gitStore(for repository: Repository) -> GitStore {
        if let existing = gitStores[repository.hash] {
            return existing
        }
        let store = GitStore(repository: repository, service: makeService(repository))
        if let state = repositoryStates[repository.hash] {
            let seed = state
            // `seed` is actor-isolated; fire-and-forget is fine — the
            // subsequent `refresh()` rebuilds from git anyway.
            Task { await store.seed(seed) }
        }
        gitStores[repository.hash] = store
        return store
    }

    /// Direct service for thin adapters (Tasks 12–14). Prefer
    /// `performPipelineMutation` for anything that changes git state.
    func gitService(for repository: Repository) async -> any GitService {
        await gitStore(for: repository).gitService()
    }

    var isRefreshingSelectedRepository: Bool {
        guard let repo = selectedRepository else { return false }
        return refreshingRepositoryHashes.contains(repo.hash)
    }

    func isRefreshing(_ repository: Repository) -> Bool {
        refreshingRepositoryHashes.contains(repository.hash)
    }

    // MARK: Refresh

    /// Refresh one repository through its `GitStore` actor and publish the
    /// resulting `RepositoryState`. Concurrent callers for the same hash
    /// collapse (the second returns early while the first is in flight).
    ///
    /// Failure routing (mirrors `performFailableOperation` + Missing scan):
    /// - missing path / `.notAGitRepository` / `.unsafeDirectory` → Missing
    ///   view via `selectMissingRepository` (no error popup; the Missing
    ///   view explains the move/delete).
    /// - every other failure → `.error` popup with `displayMessage`.
    func refreshRepository(_ repository: Repository, historyLimit: Int = 100) async {
        let key = repository.hash
        guard !refreshingRepositoryHashes.contains(key) else { return }
        refreshingRepositoryHashes.insert(key)
        defer { refreshingRepositoryHashes.remove(key) }

        let store = gitStore(for: repository)
        // Keep the actor's repository value in sync (alias/path edits
        // re-key the cache but reuse the actor; see `setAlias`).
        await store.updateRepository(repository)
        do {
            let state = try await store.refresh(historyLimit: historyLimit)
            updateRepositoryState(state)
        } catch {
            routeRefreshFailure(error, for: repository)
        }
    }

    /// Refresh whatever is currently selected (toolbar retry, focus regain).
    func refreshSelectedRepository(historyLimit: Int = 100) async {
        guard let repo = selectedRepository else { return }
        // Missing selections have no pipeline state to refresh.
        if case .missing = selection { return }
        await refreshRepository(repo, historyLimit: historyLimit)
    }

    // MARK: Mutations

    /// Run `work` through the repository's actor, re-refresh, publish, and
    /// return the operation result. Failures post `.error` (or route to
    /// Missing when the repo vanished) and return nil — never throw to views.
    @discardableResult
    func performPipelineMutation<T: Sendable>(
        for repository: Repository,
        historyLimit: Int = 100,
        work: @Sendable (any GitService) async throws -> T
    ) async -> T? {
        let store = gitStore(for: repository)
        await store.updateRepository(repository)
        do {
            let (result, state) = try await store.performAndRefresh(historyLimit: historyLimit, work: work)
            updateRepositoryState(state)
            return result
        } catch {
            routeRefreshFailure(error, for: repository)
            return nil
        }
    }

    // MARK: Failure routing

    /// Map a refresh/mutation failure to Missing or `.error`.
    /// Public for tests; views use `refreshRepository` / mutations.
    func routeRefreshFailure(_ error: Error, for repository: Repository) {
        // Vanished path always means Missing (covers `selectRepository`
        // racing a delete/move, plus dubious-ownership blocks).
        let pathExists = FileManager.default.fileExists(atPath: repository.path)
        if !pathExists {
            selectMissingRepository(repository)
            return
        }
        if let gitError = error as? GitError {
            switch gitError.kind {
            case .notAGitRepository, .unsafeDirectory:
                selectMissingRepository(repository)
                return
            default:
                showPopup(.error(message: gitError.displayMessage))
                return
            }
        }
        showPopup(.error(message: error.localizedDescription))
    }
}
