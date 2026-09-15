import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AppleIntelligenceService (Task 10)
// Swift replacement for the reference Copilot integration per
// Docs/01-scope.md §3. On-device only via `FoundationModels` (macOS 26+):
// commit-message generation (streaming) + conflict explanation (read-only).
// No network, no quota UI, no model picker, no keychain secrets.
//
// Gating: `#available(macOS 26, *)` + `SystemLanguageModel.default.isAvailable`
// + Settings toggle (`appleIntelligenceEnabled`). When unavailable the commit
// box hides the generate button (same as Copilot flag-gating) and the
// conflicts UI hides the Explain button. Auto-apply of conflict resolutions
// is explicitly out of scope.

// MARK: - Pure types (Foundation-only, unit-tested)

/// Why Apple Intelligence features are (un)available. Pure + testable.
/// NOTE: intentionally NOT `Equatable` — with the target's
/// `-default-isolation=MainActor` + `InferIsolatedConformances`, a synthesized
/// `==` infers as MainActor-isolated and cannot be used from nonisolated
/// contexts (future Swift 6 error). Test via `isAvailable` + `case` matching.
public enum AIAvailability: Sendable {
    case available
    case disabledInSettings
    case unsupportedOS
    case modelUnavailable(reason: String)
    case noOnDeviceModel

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var statusText: String {
        switch self {
        case .available:
            return "Available — runs on-device with Apple Intelligence. Diff content never leaves this Mac."
        case .disabledInSettings:
            return "Disabled — enable Apple Intelligence features in Settings."
        case .unsupportedOS:
            return "Requires macOS 26 or later for the on-device model."
        case .modelUnavailable(let reason):
            return "On-device model unavailable: \(reason)."
        case .noOnDeviceModel:
            return "On-device model not available on this Mac."
        }
    }
}

/// Context fed to the commit-message prompt. Pure value type.
public struct AIDiffContext: Sendable, Equatable {
    public var stagedFileNames: [String]
    public var diffStat: String
    public var recentSummaries: [String]
    public var branchName: String?

    public init(
        stagedFileNames: [String] = [],
        diffStat: String = "",
        recentSummaries: [String] = [],
        branchName: String? = nil
    ) {
        self.stagedFileNames = stagedFileNames
        self.diffStat = diffStat
        self.recentSummaries = recentSummaries
        self.branchName = branchName
    }
}

public enum AIError: Error, Sendable {
    case unavailable(AIAvailability)
    case cancelled
    case generationFailed(String)
}

/// Build the on-device prompt for commit-message generation.
/// Pure function: staged diff stat + file names + recent summaries + branch.
/// Keeps the prompt small (truncates diff stat) so it fits the on-device
/// context window and never ships file contents off-device.
public func buildCommitMessagePrompt(context: AIDiffContext) -> String {
    var lines: [String] = []
    lines.append("Write a git commit message for the staged changes below.")
    lines.append("Rules: first line is the summary, 72 characters or fewer, imperative mood, no trailing period.")
    lines.append("Then a blank line, then an optional short body (what + why, no bullets unless needed).")
    lines.append("Reply with ONLY the commit message, no quotes, no preamble.")
    if let branch = context.branchName, !branch.isEmpty {
        lines.append("Branch: \(branch)")
    }
    if !context.stagedFileNames.isEmpty {
        lines.append("Changed files:")
        for name in context.stagedFileNames.prefix(30) {
            lines.append("- \(name)")
        }
    }
    if !context.diffStat.isEmpty {
        lines.append("Diff stat:")
        lines.append(truncateDiffForPrompt(context.diffStat, limit: 4000))
    }
    if !context.recentSummaries.isEmpty {
        lines.append("Recent commit style (match tone):")
        for summary in context.recentSummaries.prefix(5) {
            lines.append("- \(summary)")
        }
    }
    return lines.joined(separator: "\n")
}

/// Truncate diff text to `limit` characters on a line boundary.
public func truncateDiffForPrompt(_ diff: String, limit: Int = 4000) -> String {
    guard diff.count > limit else { return diff }
    let prefix = diff.prefix(limit)
    if let lastNewline = prefix.lastIndex(of: "\n") {
        return String(prefix[..<lastNewline])
    }
    return String(prefix)
}

/// Split a generated message into summary (first line ≤72 warn, not block)
/// + body. Pure + tested.
public func splitGeneratedMessage(_ text: String) -> (summary: String, body: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = trimmed.components(separatedBy: .newlines)
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeFirst()
    }
    guard let first = lines.first else { return ("", "") }
    let summary = first.trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"`'"))
        .trimmingCharacters(in: .whitespaces)
    let body = lines.dropFirst().joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (summary, body)
}

/// Pure availability gate (test seam — the live check feeds `modelStatus`).
public func appleIntelligenceAvailability(
    enabledInSettings: Bool,
    osSupportsModel: Bool,
    modelStatus: AIAvailability? = nil
) -> AIAvailability {
    guard enabledInSettings else { return .disabledInSettings }
    guard osSupportsModel else { return .unsupportedOS }
    return modelStatus ?? .available
}

/// Whether the overwrite warning must be shown (summary/description
/// non-empty), mirroring the reference Copilot overwrite-warning dialog.
public func aiShouldWarnBeforeOverwrite(summary: String, description: String) -> Bool {
    !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Whether the first-run disclaimer must be shown.
public func aiShouldShowDisclaimer(acknowledged: Bool, dontAskAgain: Bool) -> Bool {
    !acknowledged && !dontAskAgain
}

// MARK: - System status mapping (pure, unit-tested)

/// FoundationModels-free mirror of
/// `SystemLanguageModel.Availability.UnavailableReason`. Keeps the
/// reason → `AIAvailability` mapping unit-testable without linking
/// FoundationModels (the live status feeds through this mapper).
public enum AISystemStatus: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown(String)
}

/// Map a system model status to the app-facing availability gate. Pure.
public func aiAvailability(systemStatus: AISystemStatus) -> AIAvailability {
    switch systemStatus {
    case .available:
        return .available
    case .deviceNotEligible:
        return .noOnDeviceModel
    case .appleIntelligenceNotEnabled:
        return .modelUnavailable(reason: "Apple Intelligence is turned off in System Settings")
    case .modelNotReady:
        return .modelUnavailable(reason: "the on-device model is still downloading or preparing")
    case .unknown(let detail):
        return .modelUnavailable(reason: detail)
    }
}

// MARK: - Live service (FoundationModels when available)

/// Thin wrapper over `FoundationModels.LanguageModelSession`.
/// The UI drives it via `generateCommitMessage` (streaming) +
/// `explainConflict` (read-only, no file writes).
@MainActor
public final class AppleIntelligenceService: ObservableObject {
    @Published public private(set) var isGenerating = false
    @Published public private(set) var availability: AIAvailability = .unsupportedOS

    private var cancelled = false

    public init() {
        refreshAvailability()
    }

    public func refreshAvailability(enabledOverride: Bool? = nil) {
        let enabled: Bool = {
            if let override = enabledOverride { return override }
            if UserDefaults.standard.object(forKey: Defaults.appleIntelligenceEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Defaults.appleIntelligenceEnabled)
        }()
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            availability = appleIntelligenceAvailability(
                enabledInSettings: enabled,
                osSupportsModel: true,
                modelStatus: Self.liveModelStatus())
        } else {
            availability = appleIntelligenceAvailability(
                enabledInSettings: enabled, osSupportsModel: false)
        }
        #else
        availability = appleIntelligenceAvailability(
            enabledInSettings: enabled, osSupportsModel: false)
        #endif
    }

    public func cancel() {
        cancelled = true
        isGenerating = false
    }

    /// Stream a commit message for `context`. Throws `.unavailable` when the
    /// gate is closed, `.cancelled` on cancel. Callers split the result with
    /// `splitGeneratedMessage` and set the `generatedByAppleIntelligence` flag.
    public func generateCommitMessage(context: AIDiffContext) -> AsyncThrowingStream<String, Error> {
        guard availability.isAvailable else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.unavailable(self.availability)) }
        }
        cancelled = false
        isGenerating = true
        let prompt = buildCommitMessagePrompt(context: context)
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    #if canImport(FoundationModels)
                    if #available(macOS 26, *) {
                        try await self.streamFoundationModel(
                            prompt: prompt, continuation: continuation)
                    } else {
                        continuation.finish(throwing: AIError.unavailable(.unsupportedOS))
                    }
                    #else
                    continuation.finish(throwing: AIError.unavailable(.unsupportedOS))
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
                self.isGenerating = false
            }
        }
    }

    /// Explain conflict markers for one file (read-only, no file writes).
    /// Returns plain-text explanation; never applies a resolution.
    public func explainConflict(path: String, markerExcerpt: String) async throws -> String {
        guard availability.isAvailable else {
            throw AIError.unavailable(availability)
        }
        let excerpt = String(markerExcerpt.prefix(2000))
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return try await self.runFoundationModel(
                prompt: "Explain these git merge conflict markers in \(path). "
                    + "Describe the OURS vs THEIRS sides and how to choose manually. "
                    + "Do NOT rewrite the file, only explain.\n\n\(excerpt)")
        }
        #endif
        throw AIError.unavailable(.unsupportedOS)
    }

    // MARK: - FoundationModels glue (isolated so the file compiles without it)

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func liveModelStatus() -> AIAvailability {
        // Real gate: `SystemLanguageModel.default.availability` reports
        // whether the on-device model can serve requests right now.
        // Mapped through the pure `aiAvailability(systemStatus:)` seam so
        // the reason strings stay unit-tested (see `Task15Tests`).
        let status: AISystemStatus
        switch SystemLanguageModel.default.availability {
        case .available:
            status = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                status = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                status = .appleIntelligenceNotEnabled
            case .modelNotReady:
                status = .modelNotReady
            @unknown default:
                status = .unknown("an unexpected model state (\(reason))")
            }
        }
        return aiAvailability(systemStatus: status)
    }

    @available(macOS 26, *)
    private func streamFoundationModel(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Real on-device streaming via `LanguageModelSession.streamResponse`.
        // Snapshots carry the full text so far — yield only the new suffix
        // so consumers can append tokens incrementally. Explain-only
        // contract holds: this never writes files, it only yields text.
        // Throws (never finishes-then-throws) so the caller in
        // `generateCommitMessage` settles the continuation exactly once.
        if cancelled || Task.isCancelled { throw AIError.cancelled }
        let session = LanguageModelSession()
        var emitted = ""
        do {
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                if cancelled || Task.isCancelled { throw AIError.cancelled }
                let partial: String = snapshot.content
                guard partial.hasPrefix(emitted) else {
                    // Defensive resync (String streams are append-only in
                    // practice): never emit duplicates, never crash.
                    emitted = partial
                    continue
                }
                let delta = String(partial.dropFirst(emitted.count))
                emitted = partial
                if !delta.isEmpty { continuation.yield(delta) }
            }
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.generationFailed(error.localizedDescription)
        }
        if cancelled || Task.isCancelled { throw AIError.cancelled }
        continuation.finish()
    }

    @available(macOS 26, *)
    private func runFoundationModel(prompt: String) async throws -> String {
        // Real on-device single response for conflict explanations.
        // Read-only: returns explanation text, never touches the workdir.
        if cancelled || Task.isCancelled { throw AIError.cancelled }
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            if cancelled || Task.isCancelled { throw AIError.cancelled }
            return response.content
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.generationFailed(error.localizedDescription)
        }
    }
    #else
    private static func liveModelStatus() -> AIAvailability { .noOnDeviceModel }
    #endif
}
