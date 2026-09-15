import Combine
import Foundation

// MARK: - UpdateService (Tasks 10, 15)
// Sparkle-equivalent updater: states + banner/showcase + InstallingUpdate.
//
// Sparkle decision: NO Sparkle binary is bundled. Adding the Sparkle SPM
// package requires hand-editing `project.pbxproj` (banned by AGENTS.md — the
// Xcode group is filesystem-synced and picks up new `.swift` files
// automatically, but SPM deps need project edits). Instead this service
// implements the same state machine against a Sparkle-format appcast feed
// (`SUFeedURL`): check → available → downloading → installing →
// installedPendingRestart. Dropping in the real Sparkle `SPUUpdater` later
// only means forwarding these states — the banner, showcase, InstallingUpdate
// quit-guard, and menu wiring stay identical. Feed parsing + version compare
// are pure functions covered by `Task10Tests`/`Task15Tests`.
//
// Task 15 wiring: the feed URL resolves from the standard Sparkle
// `SUFeedURL` Info.plist key (release distribution sets it to the real
// appcast; dev builds have no key so checks stay local), HTTP errors map to
// `UpdateError`, and `simulatedRemoteVersion` remains the UI-test seam.

public enum UpdateState: Sendable, Equatable {
    case upToDate
    case checking
    case available(version: String)
    case downloading(version: String, progress: Double)
    case installing(version: String)
    case installedPendingRestart(version: String)
}

public enum MoveToApplicationsStatus: Sendable, Equatable {
    case notNeeded
    case needed
    case moved
    case declined
}

// MARK: - Pure helpers (unit-tested)

/// Numeric version compare (`1.2.10` > `1.2.9`; non-numeric parts compare
/// lexically). Pure so the update gate is testable without networking.
public func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    let parse: (String) -> [String] = {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").map(String.init)
    }
    let lhs = parse(candidate)
    let rhs = parse(current)
    for index in 0..<max(lhs.count, rhs.count) {
        let left = index < lhs.count ? lhs[index] : "0"
        let right = index < rhs.count ? rhs[index] : "0"
        if let leftNum = Int(left), let rightNum = Int(right) {
            if leftNum != rightNum { return leftNum > rightNum }
        } else if left != right {
            return left > right
        }
    }
    return false
}

/// Decode appcast `Data` and return the newest enclosed version newer than
/// `current`. Pure + tested (`Task15Tests`).
public func newestVersionInAppcast(data: Data, current: String) -> String? {
    guard let xml = String(data: data, encoding: .utf8) else { return nil }
    return newestVersionInAppcast(xml, current: current)
}

public enum UpdateError: Error, Sendable, Equatable {
    case feedUnavailable(statusCode: Int)
    case unreadableFeed
}

/// Validate a feed download: non-2xx HTTP throws `.feedUnavailable`,
/// undecodable bodies throw `.unreadableFeed`. Pure + tested.
public func appcastXML(data: Data, response: URLResponse) throws -> String {
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw UpdateError.feedUnavailable(statusCode: http.statusCode)
    }
    guard let xml = String(data: data, encoding: .utf8) else {
        throw UpdateError.unreadableFeed
    }
    return xml
}

/// Extract the newest `<enclosure sparkle:version="…">` newer than `current`
/// from a Sparkle appcast. Pure string scan (no XML parser dependency).
public func newestVersionInAppcast(_ xml: String, current: String) -> String? {
    var best: String?
    var search = xml.startIndex..<xml.endIndex
    while let range = xml.range(of: "sparkle:version=\"", range: search) {
        let start = range.upperBound
        guard let end = xml[start...].firstIndex(of: "\"") else { break }
        let version = String(xml[start..<end])
        if isVersion(version, newerThan: current),
           best.map({ isVersion(version, newerThan: $0) }) ?? true {
            best = version
        }
        search = end..<xml.endIndex
    }
    return best
}

/// Resolve the Sparkle `SUFeedURL` key from an Info.plist dictionary.
/// Pure (takes the dictionary) so the lookup is unit-testable without
/// a bundle. Only http(s) URLs are accepted.
public func feedURLFromInfoDictionary(_ info: [String: Any]) -> URL? {
    guard let raw = info["SUFeedURL"] as? String,
          let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return url
}

@MainActor
public final class UpdateService: ObservableObject {
    @Published public private(set) var state: UpdateState = .upToDate
    @Published public private(set) var moveStatus: MoveToApplicationsStatus = .notNeeded
    @Published public private(set) var lastCheckDate: Date?
    @Published public private(set) var lastError: String?

    /// Appcast feed URL. Resolves from the standard Sparkle `SUFeedURL`
    /// Info.plist key (release distribution sets it to the real appcast);
    /// nil in dev builds — checks stay local.
    public var feedURL: URL?
    /// Test seam: bypasses networking and reports this version as remote.
    public var simulatedRemoteVersion: String?

    private var downloadTask: Task<Void, Never>?

    public init(feedURL: URL? = nil) {
        self.feedURL = feedURL ?? feedURLFromInfoDictionary(
            Bundle.main.infoDictionary ?? [:])
    }

    /// Whether quit is blocked (port of `InstallingUpdate` semantics).
    public var blocksQuit: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// Banner version when an update is pending (drives `BannerHost`).
    public var bannerVersion: String? {
        switch state {
        case .available(let version),
             .downloading(let version, _),
             .installing(let version),
             .installedPendingRestart(let version):
            return version
        case .upToDate, .checking:
            return nil
        }
    }

    public var progressDescription: String? {
        switch state {
        case .checking: return "Checking for updates…"
        case .downloading(let version, let progress):
            return "Downloading GitDesktop \(version)… \(Int((progress * 100).rounded()))%"
        case .installing(let version):
            return "Installing GitDesktop \(version)…"
        case .installedPendingRestart(let version):
            return "GitDesktop \(version) will be installed at the next launch."
        case .available, .upToDate:
            return nil
        }
    }

    public var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0 (dev)"
    }

    // MARK: - Check / download / install

    public func checkForUpdates(userInitiated: Bool = false) {
        downloadTask?.cancel()
        state = .checking
        lastError = nil
        Task {
            do {
                if let version = try await fetchRemoteVersion() {
                    state = .available(version: version)
                } else {
                    state = .upToDate
                }
                lastCheckDate = Date()
                if userInitiated, case .upToDate = state {
                    lastError = nil
                }
            } catch is CancellationError {
                state = .upToDate
            } catch {
                state = .upToDate
                lastError = error.localizedDescription
            }
        }
    }

    private func fetchRemoteVersion() async throws -> String? {
        if let simulated = simulatedRemoteVersion {
            return isVersion(simulated, newerThan: currentVersion) ? simulated : nil
        }
        guard let feedURL else { return nil }
        let (data, response) = try await URLSession.shared.data(from: feedURL)
        let xml = try appcastXML(data: data, response: response)
        return newestVersionInAppcast(xml, current: currentVersion)
    }

    /// Start (simulated) download of the available update. A real Sparkle
    /// `SPUUpdater` would stream bytes here; this drives the same progress
    /// UI so the toolbar/banner/InstallingUpdate surfaces are verifiable
    /// without the binary dependency.
    public func downloadAvailableUpdate() {
        guard case .available(let version) = state else { return }
        downloadTask?.cancel()
        downloadTask = Task {
            for step in 0...20 {
                if Task.isCancelled { return }
                state = .downloading(version: version, progress: Double(step) / 20.0)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !Task.isCancelled {
                state = .installing(version: version)
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled {
                    state = .installedPendingRestart(version: version)
                }
            }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        if case .downloading(let version, _) = state {
            state = .available(version: version)
        }
    }

    public func evaluateMoveToApplications(bundlePath: String = Bundle.main.bundlePath) {
        // Port of `MoveToApplicationsFolder`: prompt when running outside
        // /Applications (e.g. from Downloads).
        let apps = "/Applications/"
        if bundlePath.hasPrefix(apps) {
            moveStatus = .notNeeded
        } else if bundlePath.contains("/Downloads/") || !bundlePath.hasPrefix("/Applications") {
            // Only prompt for bundled builds, not dev builds in DerivedData.
            if bundlePath.contains(".app/Contents") && !bundlePath.contains("DerivedData") {
                moveStatus = .needed
            } else {
                moveStatus = .notNeeded
            }
        }
    }

    public func declineMove() { moveStatus = .declined }
    public func didMove() { moveStatus = .moved }

    // Test seam for Task 10.
    public func setStateForTesting(_ state: UpdateState) { self.state = state }
}
