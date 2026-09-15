import AppKit
import SwiftUI

// MARK: - ToolbarView
// Dark toolbar strip (Docs/04-shell-toolbar.md §2, `toolbar/*`).
// Layout: [Repo foldout][Branch dropdown][Push/Pull split][Fetch state] + worktree.
// Height 50, dark gray-900 bg with white text; an open foldout inverts its
// button (white bg + dark text). Tooltips via `help()`.
// Task 13: primary + split-menu actions run real fetch/pull/push via the
// Task-11 pipeline with progress wired to the button (`syncTitle`).

struct ToolbarView: View {
    @ObservedObject var store: AppStore
    /// In-flight sync title (`Fetching…`/`Pulling…`/`Pushing…`). While non-nil
    /// the push/pull button renders the `.progress` state (disabled + spinner)
    /// via `derivePushPullState(progressTitle:)`.
    @State private var syncTitle: String?
    /// Last successful fetch/pull timestamp per repository hash (feeds the
    /// `Last fetched …` detail line).
    @State private var lastFetchedByRepo: [String: Date] = [:]

    private var state: RepositoryState? { store.selectedState }
    private var repository: Repository? { store.selectedRepository }

    private var pushPull: PushPullViewState {
        derivePushPullState(
            tip: state?.tip ?? .unknown,
            remoteName: state?.remote?.name,
            aheadBehind: state?.aheadBehind,
            progressTitle: syncTitle,
            lastFetched: repository.map { lastFetchedByRepo[$0.hash] } ?? nil)
    }

    private var branchButton: BranchButtonState {
        deriveBranchButtonState(tip: state?.tip ?? .unknown)
    }

    var body: some View {
        HStack(spacing: 0) {
            repositoryButton
            ToolbarDivider()
            branchDropdownButton
            ToolbarDivider()
            pushPullButton
            Spacer(minLength: 8)
            worktreeButton
        }
        .frame(height: ToolbarMetrics.height)
        .background(ToolbarMetrics.background)
        .onAppear { loadToolbarWidths() }
    }

    // MARK: Repository foldout button

    private var repositoryButton: some View {
        ToolbarItemButton(
            title: repository?.name ?? "No repository",
            detail: repository?.path ?? "Add a repository to get started",
            systemIcon: "folder",
            isActive: store.currentFoldout == .repository,
            isEnabled: true,
            tooltip: repository.map { "\($0.name)\n\($0.path)" } ?? "Select a repository",
            action: { store.toggleFoldout(.repository) }
        )
        .frame(width: 220)
        .popover(
            isPresented: foldoutBinding(.repository),
            arrowEdge: .top
        ) {
            RepositoryFoldoutContent(store: store)
        }
    }

    // MARK: Branch dropdown

    private var branchDropdownButton: some View {
        ToolbarItemButton(
            title: branchButton.title,
            detail: branchButton.detail,
            systemIcon: branchButton.systemIcon,
            isActive: store.currentFoldout == .branch,
            isEnabled: branchButton.isEnabled && repository != nil,
            tooltip: repository == nil
                ? "No repository selected"
                : "\(branchButton.title) — \(branchButton.detail)",
            action: { store.toggleFoldout(.branch) },
            trailing: AnyView(
                Text("▾")
                    .font(.caption)
                    .foregroundStyle(ToolbarMetrics.secondaryText)
            )
        )
        .frame(width: max(store.widths.branchDropdown.clamped, store.widths.branchDropdown.min))
        .popover(
            isPresented: foldoutBinding(.branch),
            arrowEdge: .top
        ) {
            BranchFoldoutContent(store: store)
        }
        .overlay(alignment: .trailing) {
            ToolbarWidthHandle(
                store: store,
                width: store.widths.branchDropdown,
                setWidth: { store.widths.branchDropdown.value = $0 },
                defaultsKey: Defaults.branchDropdownWidth,
                defaultValue: PaneWidths().branchDropdown.value
            )
        }
    }

    // MARK: Push / pull

    private var pushPullButton: some View {
        HStack(spacing: 0) {
            ToolbarItemButton(
                title: pushPullTitle,
                detail: pushPullDetail,
                systemIcon: pushPullIcon,
                isActive: store.currentFoldout == .pushPull,
                isEnabled: pushPull.isEnabled && repository != nil,
                tooltip: pushPullTooltip,
                action: pushPullPrimaryAction,
                trailing: pushPullBadge
            )
            if pushPull.showsSplitMenu && repository != nil {
                Button {
                    store.toggleFoldout(.pushPull)
                } label: {
                    Text("▾")
                        .font(.caption)
                        .foregroundStyle(ToolbarMetrics.secondaryText)
                        .frame(width: 22, height: ToolbarMetrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Push, pull, fetch options")
                .popover(
                    isPresented: foldoutBinding(.pushPull),
                    arrowEdge: .top
                ) {
                    PushPullFoldoutContent(store: store, pushPull: pushPull)
                }
            }
        }
        .frame(width: max(store.widths.pushPullButton.clamped, store.widths.pushPullButton.min))
        .overlay(alignment: .trailing) {
            ToolbarWidthHandle(
                store: store,
                width: store.widths.pushPullButton,
                setWidth: { store.widths.pushPullButton.value = $0 },
                defaultsKey: Defaults.pushPullButtonWidth,
                defaultValue: PaneWidths().pushPullButton.value
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pushPullTitle). \(pushPullDetail)")
    }

    private var pushPullTitle: String {
        switch pushPull.action {
        case .publishRepository: return "Publish repository"
        case .publishBranch: return "Publish branch"
        case .fetch(let remote): return "Fetch \(remote)"
        case .pull(let remote, let rebase): return rebase ? "Pull \(remote) with rebase" : "Pull \(remote)"
        case .push(let remote): return "Push \(remote)"
        case .forcePush(let remote): return "Force push \(remote)"
        case .progress(let title): return title
        case .detached: return "Publish branch"
        }
    }

    private var pushPullDetail: String {
        switch pushPull.action {
        case .publishRepository: return "Publish to the remote"
        case .publishBranch: return "Publish to the remote"
        case .detached(let rebase): return rebase ? "Rebase in progress" : "Cannot push detached HEAD"
        case .progress: return "Hang on…"
        default:
            if let lastFetched = pushPull.lastFetched {
                return "Last fetched \(RelativeDateTimeFormatter().localizedString(for: lastFetched, relativeTo: Date()))"
            }
            return "Never fetched"
        }
    }

    private var pushPullIcon: String {
        switch pushPull.action {
        case .publishRepository, .publishBranch: return "arrow.up"
        case .fetch: return "arrow.clockwise"
        case .pull: return "arrow.down"
        case .push: return "arrow.up"
        case .forcePush: return "arrow.up.arrow.down"
        case .progress: return "arrow.clockwise"
        case .detached: return "arrow.up"
        }
    }

    private var pushPullTooltip: String {
        switch pushPull.action {
        case .detached(let rebase):
            return rebase ? "Rebase in progress" : "Cannot publish detached HEAD"
        default:
            return "\(pushPullTitle) — \(pushPullDetail)"
        }
    }

    private var pushPullBadge: AnyView {
        if case .progress = pushPull.action {
            return AnyView(
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            )
        }
        if let aheadBehind = pushPull.aheadBehind,
           let badge = aheadBehindBadgeText(
               ahead: aheadBehind.ahead,
               behind: aheadBehind.behind,
               tagsToPush: pushPull.numTagsToPush) {
            return AnyView(
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ToolbarMetrics.badge)
                    .clipShape(Capsule())
            )
        }
        return AnyView(EmptyView())
    }

    private func pushPullPrimaryAction() {
        guard syncTitle == nil else { return }
        guard let repository, let currentState = state else {
            store.closeFoldout()
            return
        }
        switch pushPull.action {
        case .publishRepository:
            // No remote yet — open Repository Settings so the user can add one.
            store.closeFoldout()
            store.showPopup(.repositorySettings(repositoryID: repository.id, initialTab: nil))
        case .publishBranch:
            guard let remote = currentState.remote ?? currentState.remotes.first,
                  let branchName = currentBranchName
            else {
                store.closeFoldout()
                store.showPopup(.repositorySettings(repositoryID: repository.id, initialTab: nil))
                return
            }
            runSync(title: "Pushing…") {
                await shellPush(
                    store: store, repository: repository, remote: remote,
                    localBranch: branchName, remoteBranch: nil, forceWithLease: false)
            }
        case .fetch(let remoteName):
            guard let remote = resolveRemote(named: remoteName) else {
                store.closeFoldout()
                return
            }
            runSync(title: "Fetching…") {
                let ok = await shellFetch(store: store, repository: repository, remote: remote)
                if ok { markFetched(repository) }
            }
        case .pull(let remoteName, _):
            guard let remote = resolveRemote(named: remoteName) else {
                store.closeFoldout()
                return
            }
            runSync(title: "Pulling…") {
                let ok = await shellPull(store: store, repository: repository, remote: remote)
                if ok { markFetched(repository) }
            }
        case .push(let remoteName):
            guard let remote = resolveRemote(named: remoteName),
                  let branchName = currentBranchName
            else {
                store.closeFoldout()
                return
            }
            // Push to the tracked upstream when present, else set-upstream.
            let remoteBranch = currentUpstreamWithoutRemote
            runSync(title: "Pushing…") {
                await shellPush(
                    store: store, repository: repository, remote: remote,
                    localBranch: branchName, remoteBranch: remoteBranch,
                    forceWithLease: false)
            }
        case .forcePush(let remoteName):
            guard let remote = resolveRemote(named: remoteName),
                  let branchName = currentBranchName
            else {
                store.closeFoldout()
                return
            }
            // Gate on the force-push confirm (mirrors the reference
            // `confirmOrForcePush` + `Defaults.confirmForcePush`).
            if Defaults.bool(Defaults.confirmForcePush, default: true) {
                store.closeFoldout()
                let upstream = currentUpstream ?? "\(remote.name)/\(branchName)"
                store.showPopup(.confirmForcePush(repositoryID: repository.id, upstreamBranch: upstream))
            } else {
                let remoteBranch = currentUpstreamWithoutRemote ?? branchName
                runSync(title: "Force pushing…") {
                    await shellPush(
                        store: store, repository: repository, remote: remote,
                        localBranch: branchName, remoteBranch: remoteBranch,
                        forceWithLease: true)
                }
            }
        case .progress, .detached:
            break
        }
    }

    private var currentBranchName: String? {
        if case .valid(let branch) = state?.tip { return branch.name }
        return nil
    }

    private var currentUpstream: String? {
        if case .valid(let branch) = state?.tip { return branch.upstream }
        return nil
    }

    private var currentUpstreamWithoutRemote: String? {
        if case .valid(let branch) = state?.tip { return branch.upstreamWithoutRemote }
        return nil
    }

    private func resolveRemote(named name: String) -> Remote? {
        if let remote = state?.remotes.first(where: { $0.name == name }) { return remote }
        if state?.remote?.name == name { return state?.remote }
        return nil
    }

    private func runSync(title: String, work: @escaping () async -> Void) {
        store.closeFoldout()
        syncTitle = title
        Task {
            await work()
            syncTitle = nil
        }
    }

    private func markFetched(_ repository: Repository) {
        lastFetchedByRepo[repository.hash] = Date()
    }

    // MARK: Worktree dropdown (ships enabled)

    private var worktreeButton: some View {
        ToolbarItemButton(
            title: repository?.name ?? "No worktree",
            detail: "Current worktree",
            systemIcon: "tree",
            isActive: store.currentFoldout == .worktree,
            isEnabled: repository != nil,
            tooltip: "Current worktree",
            action: { store.toggleFoldout(.worktree) },
            trailing: AnyView(
                Text("▾")
                    .font(.caption)
                    .foregroundStyle(ToolbarMetrics.secondaryText)
            )
        )
        .frame(width: 180)
        .popover(
            isPresented: foldoutBinding(.worktree),
            arrowEdge: .top
        ) {
            WorktreeFoldoutContent(store: store)
        }
    }

    // MARK: Helpers

    private func foldoutBinding(_ foldout: Foldout) -> Binding<Bool> {
        Binding(
            get: { store.currentFoldout == foldout },
            set: { isOpen in
                if isOpen { store.showFoldout(foldout) }
                else if store.currentFoldout == foldout { store.closeFoldout() }
            }
        )
    }

    private func loadToolbarWidths() {
        let branch = Defaults.double(
            Defaults.branchDropdownWidth,
            default: store.widths.branchDropdown.value)
        store.widths.branchDropdown.value = min(
            max(branch, store.widths.branchDropdown.min),
            store.widths.branchDropdown.max)
        let pushPullWidth = Defaults.double(
            Defaults.pushPullButtonWidth,
            default: store.widths.pushPullButton.value)
        store.widths.pushPullButton.value = min(
            max(pushPullWidth, store.widths.pushPullButton.min),
            store.widths.pushPullButton.max)
    }
}

// MARK: - Metrics

enum ToolbarMetrics {
    static let height: CGFloat = 50
    static let background = Color(red: 0x1F / 255, green: 0x24 / 255, blue: 0x28 / 255)
    static let text = Color.white
    static let secondaryText = Color(red: 0xC9 / 255, green: 0xD1 / 255, blue: 0xD9 / 255)
    static let hover = Color(red: 0x2D / 255, green: 0x33 / 255, blue: 0x39 / 255)
    static let badge = Color(red: 0x58 / 255, green: 0x61 / 255, blue: 0x6A / 255)
    static let activeBackground = Color.white
    static let activeText = Color(red: 0x1F / 255, green: 0x24 / 255, blue: 0x28 / 255)
    static let progressFill = Color(red: 0x2D / 255, green: 0x33 / 255, blue: 0x39 / 255)
}

// MARK: - ToolbarItemButton

/// Title + detail + icon button. Active (open foldout) inverts to white bg.
struct ToolbarItemButton: View {
    var title: String
    var detail: String
    var systemIcon: String
    var isActive: Bool = false
    var isEnabled: Bool = true
    var tooltip: String?
    var action: () -> Void
    var trailing: AnyView = AnyView(EmptyView())

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemIcon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? ToolbarMetrics.activeText.opacity(0.7) : ToolbarMetrics.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                trailing
            }
            .foregroundStyle(isActive ? ToolbarMetrics.activeText : ToolbarMetrics.text)
            .padding(.horizontal, 10)
            .frame(height: ToolbarMetrics.height)
            .contentShape(Rectangle())
            .background(
                isActive
                    ? ToolbarMetrics.activeBackground
                    : (isHovering && isEnabled ? ToolbarMetrics.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .help(tooltip ?? title)
    }
}

struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 32)
    }
}

// MARK: - ToolbarWidthHandle
// Right-edge drag resize for toolbar dropdown buttons (dbl-click resets,
// width persisted to UserDefaults). Mirrors `Resizable` for toolbar buttons.

struct ToolbarWidthHandle: View {
    @ObservedObject var store: AppStore
    var width: ConstrainedWidth
    var setWidth: (Double) -> Void
    var defaultsKey: String
    var defaultValue: Double

    /// Width when the current drag started (body re-renders mid-drag, so the
    /// `width` snapshot in `body` would otherwise go stale and jump).
    @State private var dragBaseWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragBaseWidth == nil { dragBaseWidth = width.value }
                        let proposed = (dragBaseWidth ?? width.value) + value.translation.width
                        setWidth(min(max(proposed, width.min), width.max))
                    }
                    .onEnded { _ in
                        dragBaseWidth = nil
                        Defaults.setDouble(width.value, defaultsKey)
                    }
            )
            .onTapGesture(count: 2) {
                setWidth(defaultValue)
                Defaults.setDouble(defaultValue, defaultsKey)
            }
            .accessibilityLabel("Resize toolbar button")
    }
}

#Preview {
    VStack(spacing: 0) {
        ToolbarView(store: makePreviewStore())
        Spacer()
    }
    .frame(width: 900, height: 200)
}
