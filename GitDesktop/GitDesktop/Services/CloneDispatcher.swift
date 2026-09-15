import Combine
import Foundation

// MARK: - CloneDispatcher (Task 15)
// Owns in-flight `git clone` operations so any surface can start, observe,
// or cancel them. Port of the reference `CloningRepositoriesStore`
// (`lib/stores/cloning-repositories-store.ts`) minus the GitHub retry
// actions (deleted per scope — failures surface as `GitError` instead).
//
// Cancellation path: `cancel(id:)` / `cancel(destinationPath:)` cancels the
// tracked child `Task`, which unwinds through the cancellation-aware
// `RepositoryManagement.clone` → `GitProcess.runCancellable`, terminating
// the underlying `git clone` process (SIGTERM) and throwing
// `CancellationError`. The partial destination is removed when the
// dispatcher created it (clone refuses non-empty dirs, so a pre-existing
// directory is never touched). Completion — success, `GitError`, or
// cancellation — is always delivered to the starter's `onCompletion` and
// clears the `active` entry.

/// One in-flight clone, published for progress observers (e.g. a future
/// `CloningRepositoryView` progress binding). Value-typed; the dispatcher
/// replaces the entry as progress events arrive.
public struct ActiveClone: Sendable, Equatable {
    public var id: UUID
    public var url: String
    public var destinationPath: String
    public var branch: String?
    public var progress: AppProgress?

    public init(
        id: UUID = UUID(),
        url: String,
        destinationPath: String,
        branch: String? = nil,
        progress: AppProgress? = nil
    ) {
        self.id = id
        self.url = url
        self.destinationPath = destinationPath
        self.branch = branch
        self.progress = progress
    }
}

/// Sendable weak handle so the `@Sendable` progress callback (invoked off
/// the main actor) can hop back to the MainActor-isolated dispatcher.
private struct WeakDispatcher: @unchecked Sendable {
    weak var value: CloneDispatcher?
}

@MainActor
public final class CloneDispatcher: ObservableObject {
    /// Shared instance used by the clone dialog and the cloning view.
    public static let shared = CloneDispatcher()

    /// In-flight clones keyed by job id. Empty when idle.
    @Published public private(set) var active: [UUID: ActiveClone] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Whether a clone to `destinationPath` is currently in flight.
    public func isCloning(destinationPath: String) -> Bool {
        active.values.contains { $0.destinationPath == destinationPath }
    }

    /// Start a clone. Progress events go to `onProgress` (invoked off the
    /// main actor — hop to `@MainActor` for UI state) and are mirrored into
    /// `active[id]`. `onCompletion` always fires exactly once, on the main
    /// actor, with success, `GitError`, or `CancellationError`. Returns the
    /// job id for `cancel(id:)`.
    @discardableResult
    public func start(
        url: String,
        destinationPath: String,
        branch: String? = nil,
        onProgress: (@Sendable (AppProgress) -> Void)? = nil,
        onCompletion: (@MainActor (Result<Void, Error>) -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        let existedBefore = FileManager.default.fileExists(atPath: destinationPath)
        active[id] = ActiveClone(id: id, url: url, destinationPath: destinationPath, branch: branch)
        let proxy = WeakDispatcher(value: self)
        let task = Task { @MainActor in
            let result: Result<Void, Error>
            do {
                try await RepositoryManagement.clone(
                    url: url,
                    destinationPath: destinationPath,
                    branch: branch,
                    progress: { event in
                        onProgress?(event)
                        Task { @MainActor in
                            proxy.value?.active[id]?.progress = event
                        }
                    })
                if Task.isCancelled {
                    result = .failure(CancellationError())
                } else {
                    result = .success(())
                }
            } catch is CancellationError {
                // The process was terminated mid-clone: drop the partial
                // directory we created so a retry starts clean. A
                // pre-existing directory is never removed.
                if !existedBefore {
                    try? FileManager.default.removeItem(atPath: destinationPath)
                }
                result = .failure(CancellationError())
            } catch {
                result = .failure(error)
            }
            self.tasks.removeValue(forKey: id)
            self.active.removeValue(forKey: id)
            onCompletion?(result)
        }
        tasks[id] = task
        return id
    }

    /// Cancel one in-flight clone. The tracked task unwinds, kills the git
    /// process, cleans up, and still delivers `.failure(CancellationError())`
    /// to its `onCompletion`. Unknown ids are a no-op.
    public func cancel(id: UUID) {
        tasks[id]?.cancel()
    }

    /// Cancel any in-flight clone writing to `destinationPath` (the
    /// `CloningRepositoryView` Cancel path — it knows the path, not the id).
    public func cancel(destinationPath: String) {
        for (id, clone) in active where clone.destinationPath == destinationPath {
            tasks[id]?.cancel()
        }
    }

    /// Cancel everything in flight (e.g. app teardown paths).
    public func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    // MARK: - Test seams

    /// Number of tracked tasks (bookkeeping check for `Task15Tests`).
    public var inFlightCount: Int { tasks.count }
}
