import Foundation

// MARK: - GitProcess
// Swift port of `electron/app/src/lib/git/core.ts` + `spawn.ts` + `environment.ts`.
// Invokes the bundled/system `git` via `Process` with identical args/env to
// the reference app (see Docs/09-git-layer.md).

/// Result of a git invocation. Port of dugite's `IExecResult`.
public struct GitResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    nonisolated public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    nonisolated public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    nonisolated public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public enum GitProcessError: Error, Sendable {
    case gitNotFound
    case launchFailed(String)
    case terminatedBySignal(Int32)
}

/// Shared handle letting a Task-cancellation handler terminate an in-flight
/// `Process` from any thread (Task 15: clone cancel). Lock-guarded and
/// `Sendable`; all members are `nonisolated` so both the spawning queue and
/// the cancellation handler can use it under the target's default
/// MainActor isolation.
private final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var process: Process?
    private nonisolated(unsafe) var cancelled = false

    /// Publish a spawned process. Terminates it immediately when Cancel
    /// already arrived, closing the spawn/registration race.
    nonisolated func register(_ value: Process) {
        lock.lock()
        process = value
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate { value.terminate() }
    }

    /// Mark cancelled and terminate the registered process, if any.
    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        let value = process
        lock.unlock()
        value?.terminate()
    }

    nonisolated var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// `Process`-based git execution with Desktop-compatible environment.
public enum GitProcess {
    /// Terminal output cap for error messages (256 KB; log last 1024 chars).
    nonisolated public static let maxTerminalOutputSize = 256 * 1024
    nonisolated public static let terminalLogTailLength = 1024

    /// Locate the git binary: `GIT_PATH` override, then `/usr/bin/git`,
    /// then `xcrun -f git`, falling back to `git` on PATH.
    nonisolated public static func locateGit() -> String {
        if let override_ = ProcessInfo.processInfo.environment["GIT_PATH"],
           !override_.isEmpty,
           FileManager.default.isExecutableFile(atPath: override_) {
            return override_
        }
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "git"
    }

    /// Base environment applied to every git call.
    /// Mirrors `core.ts` + `authentication.ts` + `trampoline-environment.ts`:
    /// `TERM=dumb`, `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_PARAMETERS`
    /// (unsets the user credential helper, adds the Desktop helper),
    /// `GIT_USER_AGENT`, SSH askpass suppression.
    nonisolated public static func defaultEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["GIT_TERMINAL_PROMPT"] = "0"
        if env["GIT_TRACE"] == nil { env["GIT_TRACE"] = "0" }
        let existing = env["GIT_CONFIG_PARAMETERS"] ?? ""
        let helperParams = "'credential.helper=' 'credential.helper=desktop'"
        env["GIT_CONFIG_PARAMETERS"] = existing.isEmpty
            ? helperParams
            : "\(existing) \(helperParams)"
        if env["GIT_USER_AGENT"] == nil {
            let gitVersion = "2.0"
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
            env["GIT_USER_AGENT"] = "git/\(gitVersion) (GitDesktop/\(appVersion); mac arm64)"
        }
        // Never prompt interactively; background callers rely on this.
        env["GIT_ASKPASS"] = ""
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }

    /// Run git with the given args in `workingDirectory`.
    /// - Parameters:
    ///   - args: Arguments after the `git` binary.
    ///   - workingDirectory: Repository path (nil = no cwd override).
    ///   - stdin: Optional data piped to stdin (e.g. commit message via `-F -`).
    ///   - environment: Extra env vars merged over `defaultEnvironment()`.
    nonisolated public static func run(
        _ args: [String],
        workingDirectory: String? = nil,
        stdin: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runBlocking(
                        args,
                        workingDirectory: workingDirectory,
                        stdin: stdin,
                        environment: environment)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run git, terminating the underlying `Process` when the surrounding
    /// `Task` is cancelled (Task 15: clone cancel). Cancellation surfaces as
    /// `CancellationError` so callers' `Task.isCancelled` / `catch is
    /// CancellationError` paths trigger; a process that already exited
    /// normally before Cancel still returns its result unless the flag was
    /// set first (cancel wins ties — documented, predictable).
    nonisolated public static func runCancellable(
        _ args: [String],
        workingDirectory: String? = nil,
        stdin: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> GitResult {
        // Fail fast when already cancelled (e.g. Cancel tapped before git
        // spawned) so callers never leak a process.
        try Task.checkCancellation()
        let box = CancellableProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try runBlocking(
                            args,
                            workingDirectory: workingDirectory,
                            stdin: stdin,
                            environment: environment,
                            cancellation: box)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    nonisolated private static func runBlocking(
        _ args: [String],
        workingDirectory: String?,
        stdin: Data?,
        environment: [String: String]
    ) throws -> GitResult {
        try runBlocking(
            args, workingDirectory: workingDirectory, stdin: stdin,
            environment: environment, cancellation: nil)
    }

    nonisolated private static func runBlocking(
        _ args: [String],
        workingDirectory: String?,
        stdin: Data?,
        environment: [String: String],
        cancellation: CancellableProcessBox?
    ) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: locateGit())
        process.arguments = args
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.environment = defaultEnvironment(extra: environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw GitProcessError.launchFailed(error.localizedDescription)
        }
        // Publish the process BEFORE waiting so a concurrent Cancel can
        // terminate it (`register` terminates immediately if Cancel already
        // arrived — no kill-window between spawn and registration).
        cancellation?.register(process)

        if let stdin, let pipe = stdinPipe {
            pipe.fileHandleForWriting.write(stdin)
            pipe.fileHandleForWriting.closeFile()
        }

        process.waitUntilExit()

        if cancellation?.wasCancelled == true {
            // We (or a racing Cancel) killed it: report cancellation, not a
            // signal exit, so structured-concurrency cancellation propagates.
            throw CancellationError()
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationReason != .exit {
            throw GitProcessError.terminatedBySignal(process.terminationStatus)
        }
        return GitResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Last N chars of terminal output for error display (mirrors the
    /// "log last 1024 chars" rule in Docs/09-git-layer.md).
    nonisolated public static func terminalTail(_ output: String) -> String {
        guard output.count > terminalLogTailLength else { return output }
        return String(output.suffix(terminalLogTailLength))
    }

    /// Truncate oversized terminal output to the 256 KB cap.
    nonisolated public static func truncateTerminalOutput(_ data: Data) -> Data {
        guard data.count > maxTerminalOutputSize else { return data }
        return data.suffix(maxTerminalOutputSize)
    }
}
