import Foundation

// MARK: - Task15Tests
// Tests for Task 15 (productionize services): Apple Intelligence status
// mapping, update-feed wiring/validation, and the clone dispatcher
// (bookkeeping + cancel-kills-process). Same harness style as Task10Tests:
// no test bundle needed.
//
// Async coverage runs through a small runloop bridge (`block(on:)`) because
// `runAll` is sync by harness convention while `CloneDispatcher` is
// MainActor-isolated.

public enum Task15Tests {
    public struct Failure: Sendable {
        public var test: String
        public var message: String
    }

    private static func check(_ condition: Bool, _ message: String, test: String, failures: inout [Failure]) {
        if !condition {
            failures.append(Failure(test: test, message: message))
        }
    }

    @discardableResult
    public static func runAll() -> Int {
        var failures: [Failure] = []
        testAISystemStatusMapping(&failures)
        testFeedURLLookup(&failures)
        testAppcastValidation(&failures)
        testAppcastDataDecode(&failures)
        testDispatcherIdle(&failures)
        testDispatcherValidationFailure(&failures)
        testDispatcherCancelKillsClone(&failures)
        if failures.isEmpty {
            print("Task15Tests: all tests passed")
        } else {
            print("Task15Tests: \(failures.count) failure(s)")
            for failure in failures {
                print("  FAIL [\(failure.test)] \(failure.message)")
            }
        }
        return failures.count
    }

    // MARK: - Apple Intelligence status mapping (pure)

    static func testAISystemStatusMapping(_ failures: inout [Failure]) {
        let test = "ai-system-status"
        check(aiAvailability(systemStatus: .available).isAvailable == true, "available", test: test, failures: &failures)
        check(aiAvailability(systemStatus: .deviceNotEligible).isAvailable == false, "ineligible gated", test: test, failures: &failures)
        if case .noOnDeviceModel = aiAvailability(systemStatus: .deviceNotEligible) {
        } else {
            check(false, "ineligible maps to noOnDeviceModel", test: test, failures: &failures)
        }
        check(aiAvailability(systemStatus: .appleIntelligenceNotEnabled).isAvailable == false, "toggle gated", test: test, failures: &failures)
        check(aiAvailability(systemStatus: .modelNotReady).isAvailable == false, "not-ready gated", test: test, failures: &failures)
        if case .modelUnavailable(let reason) = aiAvailability(systemStatus: .modelNotReady) {
            check(!reason.isEmpty, "reason non-empty", test: test, failures: &failures)
        } else {
            check(false, "not-ready maps to modelUnavailable", test: test, failures: &failures)
        }
        if case .modelUnavailable(let detail) = aiAvailability(systemStatus: .unknown("boom")) {
            check(detail == "boom", "unknown passthrough", test: test, failures: &failures)
        } else {
            check(false, "unknown maps to modelUnavailable", test: test, failures: &failures)
        }
        check(!aiAvailability(systemStatus: .available).statusText.isEmpty, "status text", test: test, failures: &failures)
    }

    // MARK: - Update feed URL lookup (pure)

    static func testFeedURLLookup(_ failures: inout [Failure]) {
        let test = "feed-url"
        check(
            feedURLFromInfoDictionary(["SUFeedURL": "https://example.com/appcast.xml"])?.absoluteString
                == "https://example.com/appcast.xml",
            "https accepted", test: test, failures: &failures)
        check(
            feedURLFromInfoDictionary(["SUFeedURL": "http://example.com/a.xml"]) != nil,
            "http accepted", test: test, failures: &failures)
        check(
            feedURLFromInfoDictionary([:]) == nil,
            "missing key is nil", test: test, failures: &failures)
        check(
            feedURLFromInfoDictionary(["SUFeedURL": "not a url"]) == nil,
            "garbage rejected", test: test, failures: &failures)
        check(
            feedURLFromInfoDictionary(["SUFeedURL": "ftp://example.com/a.xml"]) == nil,
            "non-http rejected", test: test, failures: &failures)
        check(
            feedURLFromInfoDictionary(["SUFeedURL": 42]) == nil,
            "non-string rejected", test: test, failures: &failures)
    }

    // MARK: - Appcast download validation (pure)

    static func testAppcastValidation(_ failures: inout [Failure]) {
        let test = "appcast-validation"
        let url = URL(string: "https://example.com/appcast.xml")!
        let body = "<rss><channel></channel></rss>".data(using: .utf8)!
        do {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let xml = try appcastXML(data: body, response: response)
            check(xml.contains("<rss>"), "200 passes through", test: test, failures: &failures)
        } catch {
            check(false, "200 must not throw: \(error)", test: test, failures: &failures)
        }
        do {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            _ = try appcastXML(data: body, response: response)
            check(false, "404 must throw", test: test, failures: &failures)
        } catch let error as UpdateError {
            check(error == .feedUnavailable(statusCode: 404), "404 maps (\(error))", test: test, failures: &failures)
        } catch {
            check(false, "404 maps to UpdateError, got \(error)", test: test, failures: &failures)
        }
        do {
            let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            _ = try appcastXML(data: body, response: response)
            check(false, "500 must throw", test: test, failures: &failures)
        } catch let error as UpdateError {
            check(error == .feedUnavailable(statusCode: 500), "500 maps", test: test, failures: &failures)
        } catch {
            check(false, "500 maps to UpdateError, got \(error)", test: test, failures: &failures)
        }
        do {
            // Non-HTTP responses (e.g. file:) carry no status — pass through.
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            let xml = try appcastXML(data: body, response: response)
            check(xml.contains("<rss>"), "non-http passes through", test: test, failures: &failures)
        } catch {
            check(false, "non-http must not throw: \(error)", test: test, failures: &failures)
        }
        do {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            _ = try appcastXML(data: Data([0xFF, 0xFE, 0x00]), response: response)
            check(false, "undecodable must throw", test: test, failures: &failures)
        } catch let error as UpdateError {
            check(error == .unreadableFeed, "undecodable maps", test: test, failures: &failures)
        } catch {
            check(false, "undecodable maps to UpdateError, got \(error)", test: test, failures: &failures)
        }
    }

    static func testAppcastDataDecode(_ failures: inout [Failure]) {
        let test = "appcast-data-decode"
        let xml = """
        <rss><channel>
        <item><enclosure sparkle:version="2.0" /></item>
        </channel></rss>
        """
        let data = xml.data(using: .utf8)!
        check(newestVersionInAppcast(data: data, current: "1.0") == "2.0", "data overload", test: test, failures: &failures)
        check(newestVersionInAppcast(data: data, current: "2.0") == nil, "up-to-date", test: test, failures: &failures)
        check(newestVersionInAppcast(data: Data([0xFF, 0xFE]), current: "1.0") == nil, "bad bytes nil", test: test, failures: &failures)
    }

    // MARK: - Clone dispatcher

    static func testDispatcherIdle(_ failures: inout [Failure]) {
        let test = "dispatcher-idle"
        let results = Checks()
        block { @MainActor in
            let dispatcher = CloneDispatcher()
            results.check(dispatcher.inFlightCount == 0, "idle count")
            results.check(dispatcher.isCloning(destinationPath: "/tmp/nowhere") == false, "idle query")
            dispatcher.cancel(id: UUID()) // unknown id: no-op, must not crash
            dispatcher.cancel(destinationPath: "/tmp/nowhere")
            dispatcher.cancelAll()
            results.check(dispatcher.inFlightCount == 0, "still idle")
        }
        results.drain(into: &failures, test: test)
    }

    /// A blocked-transport URL fails before git spawns: completion still
    /// fires exactly once and bookkeeping clears.
    static func testDispatcherValidationFailure(_ failures: inout [Failure]) {
        let test = "dispatcher-validation-failure"
        let results = Checks()
        block { @MainActor in
            let dispatcher = CloneDispatcher()
            let box = CompletionBox()
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitdesktop-t15-\(UUID().uuidString)").path
            _ = dispatcher.start(
                url: "ext::blocked-transport",
                destinationPath: dest,
                onCompletion: { result in
                    box.finish(with: result)
                })
            let completed = await box.wait(timeout: 15)
            results.check(completed, "completion fires")
            if case .failure(let error) = box.result {
                results.check(error is GitError, "GitError (got \(type(of: error)))")
            } else {
                results.check(false, "blocked transport must fail")
            }
            results.check(dispatcher.inFlightCount == 0, "count clears")
            results.check(dispatcher.isCloning(destinationPath: dest) == false, "query clears")
            results.check(!FileManager.default.fileExists(atPath: dest), "no dir created")
        }
        results.drain(into: &failures, test: test)
    }

    /// Cancel terminates the in-flight `git clone` process: completion
    /// delivers `CancellationError` quickly (not after the 30s hang) and
    /// the partial destination is removed.
    ///
    /// Deterministic hang: `GIT_SSH_COMMAND` points at a script that sleeps,
    /// so git blocks in connection setup without touching the network.
    static func testDispatcherCancelKillsClone(_ failures: inout [Failure]) {
        let test = "dispatcher-cancel-kills-clone"
        guard Thread.isMainThread else {
            print("Task15Tests: [\(test)] skipped (needs the main thread)")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: GitProcess.locateGit()) else {
            print("Task15Tests: [\(test)] skipped (no git binary)")
            return
        }
        let results = Checks()
        block { @MainActor in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitdesktop-t15-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                results.check(false, "tmp dir: \(error)")
                return
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("fake-ssh.sh")
            do {
                try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: script.path)
            } catch {
                results.check(false, "script setup: \(error)")
                return
            }
            setenv("GIT_SSH_COMMAND", script.path, 1)
            defer { unsetenv("GIT_SSH_COMMAND") }
            let dest = root.appendingPathComponent("victim").path

            let dispatcher = CloneDispatcher()
            let box = CompletionBox()
            let id = dispatcher.start(
                url: "ssh://localhost:2222/owner/repo.git",
                destinationPath: dest,
                onProgress: { _ in },
                onCompletion: { result in
                    box.finish(with: result)
                })
            // Let git spawn and block in the fake transport.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard dispatcher.isCloning(destinationPath: dest) else {
                results.check(false, "clone should be in flight before cancel")
                return
            }
            let cancelStart = Date()
            dispatcher.cancel(id: id)
            let completed = await box.wait(timeout: 15)
            let elapsed = Date().timeIntervalSince(cancelStart)
            results.check(completed, "completion fires after cancel")
            if case .failure(let error) = box.result {
                results.check(
                    error is CancellationError,
                    "CancellationError (got \(type(of: error)): \(error))")
            } else {
                results.check(false, "cancelled clone must fail")
            }
            results.check(
                elapsed < 10,
                "cancel returns promptly (\(String(format: "%.1f", elapsed))s, hang was 30s)")
            results.check(!FileManager.default.fileExists(atPath: dest), "partial dir removed")
            results.check(dispatcher.inFlightCount == 0, "count clears")
            results.check(dispatcher.isCloning(destinationPath: dest) == false, "query clears")
        }
        results.drain(into: &failures, test: test)
    }

    // MARK: - Harness bridge

    /// Sendable check collector: async test bodies record here, `runAll`
    /// drains into `failures` after the bridge returns (avoids capturing
    /// `inout` across isolation domains).
    private final class Checks: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func check(_ condition: Bool, _ message: String) {
            guard !condition else { return }
            lock.lock()
            defer { lock.unlock() }
            messages.append(message)
        }

        func drain(into failures: inout [Failure], test: String) {
            for message in messages {
                failures.append(Failure(test: test, message: message))
            }
        }
    }

    /// Run `operation` to completion from sync `runAll` by spinning the main
    /// runloop (services the MainActor) until the operation signals.
    private static func block(_ operation: @MainActor @Sendable @escaping () async -> Void) {
        let done = Flag()
        Task { @MainActor in
            await operation()
            done.set()
        }
        let deadline = Date(timeIntervalSinceNow: 60)
        while !done.isSet, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// MainActor completion capture for dispatcher tests.
    @MainActor
    private final class CompletionBox {
        var result: Result<Void, Error>?
        private var continuation: CheckedContinuation<Bool, Never>?

        func finish(with result: Result<Void, Error>) {
            self.result = result
            continuation?.resume(returning: true)
            continuation = nil
        }

        func wait(timeout: TimeInterval) async -> Bool {
            if result != nil { return true }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await MainActor.run {
                        if self.result == nil {
                            self.continuation?.resume(returning: false)
                            self.continuation = nil
                        }
                    }
                }
            }
        }
    }
}
