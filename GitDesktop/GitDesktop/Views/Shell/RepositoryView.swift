import AppKit
import SwiftUI

// MARK: - RepositoryView (Task 12)
// Main detail for a selected repository (Docs/04-shell-toolbar.md §1,
// `repository.tsx`). Left `repository-sidebar` TabBar (Changes + History,
// Ctrl+Tab toggles, Cmd+1/2 via menu); right detail hosts the real feature
// views fed by the Task-11 pipeline state:
//
// - Changes tab → `ChangesTabView` (with a per-repo `ChangesStore` built from
//   the pipeline service) beside `SeamlessDiffSwitcher` (editable).
// - History tab → `CompareSidebarView` (with `CommitListView` inside) +
//   `SelectedCommitsView` with a read-only `SeamlessDiffSwitcher`.
//
// Empty states come from Task 10 (`NoChangesEmptyState`,
// `MultiSelectionEmptyState`, no-commit-selected / noncontiguous inside
// `SelectedCommitsView`) where the feature views don't already cover them.
// Thin adapters only — feature views are used as-is via explicit props.

enum RepositoryTab: String, CaseIterable {
    case changes = "Changes"
    case history = "History"
}

struct RepositoryView: View {
    @ObservedObject var store: AppStore
    var repository: Repository
    @State private var tab: RepositoryTab = .changes

    // Per-repo Changes tab state (recreated when the repo changes).
    @State private var changesStore: ChangesStore?
    // Per-repo History tab state.
    @State private var historySelectedSHAs: Set<String> = []
    @State private var historyFilterText = ""
    @State private var historyFileSelection = HistoryFileSelection()
    @State private var historyIsContiguous = true
    @State private var didAutoSelectHistory = false
    @State private var didAutoSelectChanges = false

    // Diff prefs (global, persisted via `Defaults` like the reference).
    @State private var hideWhitespaceChanges = Defaults.bool(
        Defaults.hideWhitespaceInChangesDiff, default: false)
    @State private var hideWhitespaceHistory = Defaults.bool(
        Defaults.hideWhitespaceInHistoryDiff, default: false)
    @State private var showSideBySide = Defaults.bool(
        Defaults.showSideBySideDiff, default: false)
    @State private var imageDiffType: ImageDiffType = ImageDiffType(
        rawValue: Defaults.integer(Defaults.imageDiffType, default: 0)) ?? .twoUp
    @State private var showCheckMarks = Defaults.bool(
        Defaults.showDiffCheckMarks, default: true)

    private var state: RepositoryState {
        store.repositoryStates[repository.hash] ?? RepositoryState(repository: repository)
    }

    private var changedCount: Int { state.workingDirectory.files.count }
    private var recentCommits: [Commit] { state.recentCommits }

    private var filteredHistoryCommits: [Commit] {
        filterHistoryCommits(recentCommits, filterText: historyFilterText)
    }

    private var historyLocalSHAs: Set<String> {
        localCommitSHAs(commits: recentCommits, ahead: state.aheadBehind?.ahead)
    }

    private var orderedHistorySelection: [Commit] {
        orderedSelectedCommits(commits: recentCommits, selectedSHAs: historySelectedSHAs)
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, maxWidth: 350)
            detail
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: .gitDesktopMenuAction)) { note in
            guard let action = GitDesktopMenuAction.from(note) else { return }
            switch action {
            case .showChanges: tab = .changes
            case .showHistory: tab = .history
            case .goToCommitMessage: tab = .changes
            // Task 14: Compare to Branch opens the History tab (reference
            // `showHistory(false, true)`). Preselecting the comparison branch
            // list lands with Task 12's CompareSidebar wiring.
            case .compareToBranch: tab = .history
            default: break
            }
        }
        // Per-repo state lifecycle: (re)build the ChangesStore and reset
        // history selection when the selected repository changes. The
        // pipeline service comes from `makeService` so previews/tests keep
        // their injected `MockGitService` (see `PreviewData`).
        .task(id: repository.hash) {
            historySelectedSHAs = []
            historyFilterText = ""
            historyFileSelection = HistoryFileSelection()
            historyIsContiguous = true
            didAutoSelectHistory = false
            didAutoSelectChanges = false
            let service = store.makeService(repository)
            let adapter = ChangesStore(
                store: store,
                repository: repository,
                gitService: service)
            syncChangesStore(adapter)
            changesStore = adapter
            autoSelectHistoryIfNeeded()
            autoSelectChangesIfNeeded(adapter: adapter)
        }
        .onChange(of: state.tip) { _, _ in
            if let adapter = changesStore, adapter.repository.hash == repository.hash {
                syncChangesStore(adapter)
            }
        }
        .onChange(of: state.branches) { _, _ in
            if let adapter = changesStore, adapter.repository.hash == repository.hash {
                syncChangesStore(adapter)
            }
        }
        .onChange(of: state.recentCommits) { _, _ in
            if let adapter = changesStore, adapter.repository.hash == repository.hash {
                syncChangesStore(adapter)
            }
            autoSelectHistoryIfNeeded()
        }
        .onChange(of: state.workingDirectory) { _, _ in
            autoSelectChangesIfNeeded()
        }
    }

    // MARK: Sidebar with TabBar

    private var sidebar: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabSidebarContent
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RepositoryTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                        if item == .changes, changedCount > 0 {
                            FilesChangedBadge(count: changedCount)
                        }
                    }
                    .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                    .foregroundStyle(tab == item ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(tab == item ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : Color.clear)
                }
                .buttonStyle(.plain)
                .help("Show \(item.rawValue) (Ctrl+Tab to switch)")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // Ctrl+Tab toggles Changes/History (mirrors `repository.tsx`).
            // Cmd+1/2 arrive via `GitDesktopMenuAction` from the menu.
            Button("Toggle tab") {
                tab = tab == .changes ? .history : .changes
            }
            .keyboardShortcut("\t", modifiers: .control)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var tabSidebarContent: some View {
        Group {
            switch tab {
            case .changes:
                if let adapter = changesStore {
                    ChangesTabView(changes: adapter)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Loading changes")
                }
            case .history:
                CompareSidebarView(
                    commits: filteredHistoryCommits,
                    selectedSHAs: $historySelectedSHAs,
                    mode: .history,
                    comparisonMode: .behind,
                    behindCount: 0,
                    aheadCount: 0,
                    filterText: $historyFilterText,
                    showBranchList: false,
                    shasToHighlight: [],
                    localCommitSHAs: historyLocalSHAs,
                    listActions: historyListActions,
                    onSelectionChanged: { _, contiguous in
                        historyIsContiguous = contiguous
                        // Reset the file selection so the detail shows the
                        // first file of the new commit selection.
                        historyFileSelection = HistoryFileSelection()
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail

    private var detail: some View {
        Group {
            switch tab {
            case .changes:
                if let adapter = changesStore {
                    ChangesDetailPane(
                        store: store,
                        repository: repository,
                        changes: adapter,
                        hideWhitespace: $hideWhitespaceChanges,
                        showSideBySide: $showSideBySide,
                        imageDiffType: $imageDiffType,
                        showCheckMarks: $showCheckMarks)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Loading diff")
                }
            case .history:
                HistoryDetailPane(
                    store: store,
                    repository: repository,
                    allCommits: recentCommits,
                    selectedSHAs: historySelectedSHAs,
                    fileSelection: $historyFileSelection,
                    isContiguous: historyIsContiguous,
                    hideWhitespace: $hideWhitespaceHistory,
                    showSideBySide: $showSideBySide,
                    imageDiffType: $imageDiffType,
                    showCheckMarks: $showCheckMarks)
            }
        }
    }

    // MARK: - Adapters

    /// Keep the per-repo `ChangesStore` in sync with pipeline state without
    /// rewriting the feature view: branch + author + suggestions come from
    /// `RepositoryState`, drafts stay owned by the store.
    private func syncChangesStore(_ adapter: ChangesStore) {
        adapter.branch = repositoryBranchName(tip: state.tip)
        adapter.commitAuthor = repositoryCommitAuthor(state: state)
        adapter.branches = state.branches
        adapter.localAuthors = repositoryLocalAuthors(commits: state.recentCommits)
        adapter.mostRecentLocalCommit = repositoryMostRecentCommit(state: state)
        adapter.showCommitLengthWarning = Defaults.bool(
            Defaults.showCommitLengthWarning, default: true)
        // Keep the pipeline service fresh (alias/path edits re-key the
        // cache; Live services track the path).
        adapter.gitService = store.makeService(repository)
        autoSelectChangesIfNeeded(adapter: adapter)
    }

    private var historyListActions: CommitListActions {
        CommitListActions(
            onCopySHA: { sha in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sha, forType: .string)
            })
    }

    private func autoSelectHistoryIfNeeded() {
        guard !didAutoSelectHistory,
              historySelectedSHAs.isEmpty,
              let first = recentCommits.first
        else { return }
        didAutoSelectHistory = true
        historySelectedSHAs = [first.sha]
    }

    private func autoSelectChangesIfNeeded(adapter: ChangesStore? = nil) {
        guard !didAutoSelectChanges else { return }
        let target = adapter ?? changesStore
        guard let target,
              target.repository.hash == repository.hash,
              target.selectedFileIDs.isEmpty,
              let first = target.visibleFiles.first ?? target.allFiles.first
        else { return }
        didAutoSelectChanges = true
        target.selectedFileIDs = [first.id]
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repository.path)])
    }

    private func createBranch() {
        store.showPopup(.createBranch(
            repositoryID: repository.id, initialName: nil, targetCommitSHA: nil))
    }
}

// NOTE (Tasks 2+3 merge): the Task-2 shell declared a placeholder
// `FilesChangedBadge` here. Task 3 owns the real spec port of
// `files-changed-badge.tsx` (count pill capped at `300+`, system number
// formatting) as `public struct FilesChangedBadge` in
// `Views/Changes/ChangesSidebarView.swift`; the shell twin was removed to fix
// the duplicate declaration, and `tabBar` above uses the Task 3 type.

// MARK: - Changes detail (file list → diff)

private struct ChangesDetailPane: View {
    @ObservedObject var store: AppStore
    var repository: Repository
    @ObservedObject var changes: ChangesStore
    @Binding var hideWhitespace: Bool
    @Binding var showSideBySide: Bool
    @Binding var imageDiffType: ImageDiffType
    @Binding var showCheckMarks: Bool

    @State private var diff: Diff?
    @State private var contents: DiffFileContents?
    @State private var didLoadFileID: String?

    private var selectedFiles: [WorkingDirectoryFileChange] {
        let ids = changes.selectedFileIDs
        guard !ids.isEmpty else { return [] }
        return changes.allFiles.filter { ids.contains($0.id) }
    }

    private var effectiveFile: WorkingDirectoryFileChange? {
        if selectedFiles.count == 1 { return selectedFiles[0] }
        return nil
    }

    private var loadID: String {
        // Reload when the file, repo, or whitespace pref changes. Prefs that
        // only affect rendering (side-by-side, check marks) don't reload git.
        "\(repository.hash)\u{1F}\(effectiveFile?.id ?? "none")\u{1F}\(hideWhitespace)"
    }

    var body: some View {
        Group {
            if changes.allFiles.isEmpty {
                NoChangesEmptyState(
                    onShowInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: repository.path)])
                    },
                    onCreateBranch: {
                        store.showPopup(.createBranch(
                            repositoryID: repository.id,
                            initialName: nil,
                            targetCommitSHA: nil))
                    })
            } else if selectedFiles.count > 1 {
                MultiSelectionEmptyState(count: selectedFiles.count)
            } else if let file = effectiveFile {
                SeamlessDiffSwitcher(
                    file: DiffFileDescriptor(workingDirectoryFile: file),
                    diff: diff,
                    fileContents: contents,
                    readOnly: false,
                    repositoryPath: repository.path,
                    imageDiffType: imageDiffType,
                    hideWhitespace: hideWhitespace,
                    showSideBySide: showSideBySide,
                    showCheckMarks: showCheckMarks,
                    askForConfirmationOnDiscard: Defaults.bool(
                        Defaults.confirmDiscardChanges, default: true),
                    selection: file.selection,
                    onIncludeChanged: { updateFileSelection(file, selection: $0) },
                    onDiscardChanges: { _ in
                        changes.requestDiscard(files: [file])
                    },
                    onHideWhitespaceChanged: { newValue in
                        hideWhitespace = newValue
                        Defaults.setBool(newValue, Defaults.hideWhitespaceInChangesDiff)
                    },
                    onShowSideBySideChanged: { newValue in
                        showSideBySide = newValue
                        Defaults.setBool(newValue, Defaults.showSideBySideDiff)
                    },
                    onChangeImageDiffType: { newValue in
                        imageDiffType = newValue
                        Defaults.setInteger(newValue.rawValue, Defaults.imageDiffType)
                    },
                    onOpenSubmodule: { _ in
                        changes.revealInFinder(path: file.path)
                    },
                    onRevealBinary: { _ in
                        changes.revealInFinder(path: file.path)
                    })
                .task(id: loadID) {
                    await load(file: file)
                }
            } else {
                // Files exist but nothing is selected (user cleared the
                // selection after auto-select). Prompt instead of guessing.
                EmptyStateView(
                    systemIcon: "doc.text.magnifyingglass",
                    title: "No file selected",
                    detail: "Select a file in the Changes list to preview its diff.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: changes.selectedFileIDs) { _, _ in
            // Clear stale diffs immediately; the `.task(id:)` reloads.
            if effectiveFile?.id != didLoadFileID {
                diff = nil
                contents = nil
            }
        }
    }

    private func load(file: WorkingDirectoryFileChange) async {
        diff = nil
        contents = nil
        do {
            let result = try await RepositoryDetailLoading.workingDirectoryDiff(
                repositoryPath: repository.path,
                file: file,
                hideWhitespace: hideWhitespace)
            guard !Task.isCancelled else { return }
            // Only publish when this file is still the effective selection
            // (guards the no-index/HEAD race on rapid arrow-key moves).
            guard effectiveFile?.id == file.id else { return }
            diff = result.diff
            contents = result.contents
            didLoadFileID = file.id
        } catch {
            guard !Task.isCancelled else { return }
            guard effectiveFile?.id == file.id else { return }
            // Never crash or spam `.error` for previews/missing workdirs —
            // the switcher renders the unrenderable state with the header.
            diff = .unrenderable
            contents = nil
            didLoadFileID = file.id
        }
    }

    private func updateFileSelection(
        _ file: WorkingDirectoryFileChange,
        selection: DiffSelection
    ) {
        // Line-level gutter toggles write back to the pipeline-owned
        // `RepositoryState` so the tri-state checkboxes stay in sync
        // (commit still stages full files until Task 4 adds patch staging).
        guard var state = store.repositoryStates[repository.hash] else { return }
        let updated = state.workingDirectory.files.map {
            $0.id == file.id ? $0.withSelection(selection) : $0
        }
        state.workingDirectory = .fromFiles(updated)
        store.updateRepositoryState(state)
    }
}

// MARK: - History detail (commits → files → read-only diff)

private struct HistoryDetailPane: View {
    @ObservedObject var store: AppStore
    var repository: Repository
    var allCommits: [Commit]
    var selectedSHAs: Set<String>
    @Binding var fileSelection: HistoryFileSelection
    var isContiguous: Bool
    @Binding var hideWhitespace: Bool
    @Binding var showSideBySide: Bool
    @Binding var imageDiffType: ImageDiffType
    @Binding var showCheckMarks: Bool

    @State private var files: [CommittedFileChange] = []
    @State private var linesAdded = 0
    @State private var linesDeleted = 0
    @State private var diff: Diff?
    @State private var contents: DiffFileContents?
    @State private var loadedSHAsID = ""
    @State private var loadedDiffID = ""

    private var selectedCommits: [Commit] {
        orderedSelectedCommits(commits: allCommits, selectedSHAs: selectedSHAs)
    }

    private var selectedFile: CommittedFileChange? {
        guard let path = fileSelection.selectedFilePath else { return files.first }
        return files.first(where: { $0.path == path }) ?? files.first
    }

    private var filesID: String {
        selectedSHAs.sorted().joined(separator: ",")
    }

    private var diffID: String {
        "\(filesID)\u{1F}\(selectedFile?.id ?? "none")\u{1F}\(hideWhitespace)"
    }

    var body: some View {
        SelectedCommitsView(
            selectedCommits: selectedCommits,
            shasInDiff: selectedSHAs,
            files: files,
            linesAdded: linesAdded,
            linesDeleted: linesDeleted,
            isContiguous: isContiguous,
            showDragOverlay: false,
            fileSelection: $fileSelection,
            onRevealInFinder: { reveal(path: $0) },
            onCopyPaths: { copy(paths: $0) },
            diffContent: { file in
                Group {
                    if let file {
                        SeamlessDiffSwitcher(
                            file: DiffFileDescriptor(committedFile: file),
                            diff: diff,
                            fileContents: contents,
                            readOnly: true,
                            repositoryPath: repository.path,
                            imageDiffType: imageDiffType,
                            hideWhitespace: hideWhitespace,
                            showSideBySide: showSideBySide,
                            showCheckMarks: showCheckMarks,
                            selection: nil,
                            onHideWhitespaceChanged: { newValue in
                                hideWhitespace = newValue
                                Defaults.setBool(newValue, Defaults.hideWhitespaceInHistoryDiff)
                            },
                            onShowSideBySideChanged: { newValue in
                                showSideBySide = newValue
                                Defaults.setBool(newValue, Defaults.showSideBySideDiff)
                            },
                            onChangeImageDiffType: { newValue in
                                imageDiffType = newValue
                                Defaults.setInteger(newValue.rawValue, Defaults.imageDiffType)
                            },
                            onOpenSubmodule: { _ in
                                reveal(path: file.path)
                            },
                            onRevealBinary: { _ in
                                reveal(path: file.path)
                            })
                    } else {
                        HistoryDiffPlaceholder(file: nil)
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            })
        .task(id: "\(repository.hash)\u{1F}\(filesID)") {
            await loadFiles()
        }
        .task(id: "\(repository.hash)\u{1F}\(diffID)") {
            await loadDiff()
        }
        .onChange(of: selectedSHAs) { _, _ in
            // New commit selection → stale files/diffs clear at once; the
            // tasks above reload. File selection resets in the sidebar's
            // `onSelectionChanged` (kept here as a backstop for programmatic
            // selection changes like auto-select).
            files = []
            linesAdded = 0
            linesDeleted = 0
            diff = nil
            contents = nil
        }
    }

    private func loadFiles() async {
        let id = filesID
        guard !selectedCommits.isEmpty, isContiguous else {
            // Empty / noncontiguous selections render the blankslates inside
            // `SelectedCommitsView` — no git call needed.
            files = []
            linesAdded = 0
            linesDeleted = 0
            loadedSHAsID = id
            return
        }
        do {
            let changeset = try await RepositoryDetailLoading.commitChangedFiles(
                repositoryPath: repository.path,
                selected: selectedCommits)
            guard !Task.isCancelled else { return }
            guard filesID == id else { return }
            files = changeset.files
            linesAdded = changeset.linesAdded
            linesDeleted = changeset.linesDeleted
            loadedSHAsID = id
        } catch {
            guard !Task.isCancelled else { return }
            guard filesID == id else { return }
            // Previews (no git dir) and unborn SHAs land here — show the
            // commit summary with an empty file list, never crash.
            files = []
            linesAdded = 0
            linesDeleted = 0
            loadedSHAsID = id
        }
    }

    private func loadDiff() async {
        let id = diffID
        guard let file = selectedFile, isContiguous, !selectedCommits.isEmpty else {
            diff = nil
            contents = nil
            loadedDiffID = id
            return
        }
        // Wait for the files load when it is still in flight (previews and
        // rapid selection changes): the files task shares `filesID`, so a
        // missing file here means files haven't arrived yet — the next
        // `diffID` change (when `files` publishes) retries.
        diff = nil
        contents = nil
        do {
            let result = try await RepositoryDetailLoading.commitDiff(
                repositoryPath: repository.path,
                file: file,
                selected: selectedCommits,
                hideWhitespace: hideWhitespace)
            guard !Task.isCancelled else { return }
            guard diffID == id else { return }
            diff = result.diff
            contents = result.contents
            loadedDiffID = id
        } catch {
            guard !Task.isCancelled else { return }
            guard diffID == id else { return }
            diff = .unrenderable
            contents = nil
            loadedDiffID = id
        }
    }

    private func reveal(path: String) {
        let url = URL(fileURLWithPath:
            (repository.path as NSString).appendingPathComponent(path))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(paths: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}

#Preview {
    let store = makePreviewStore()
    return RepositoryView(store: store, repository: store.repositories[0])
        .frame(width: 900, height: 560)
}
