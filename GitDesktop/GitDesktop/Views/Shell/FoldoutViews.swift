import AppKit
import SwiftUI

// MARK: - FoldoutViews
// Popover contents for the one-open `Foldout` set (Docs/04-shell-toolbar.md
// §5). One open at a time is enforced by `AppStore.currentFoldout`; popovers
// dismiss via overlay click / Esc automatically.
//
// Task 13 composition: the branch dropdown hosts the real
// `BranchesContainerView` (checkout/create/rename/delete via the Task-11
// pipeline), the worktree dropdown hosts the real `WorktreeList` (+ switch),
// and the push/pull split menu runs real fetch/force-push.

// MARK: Repository foldout

struct RepositoryFoldoutContent: View {
    @ObservedObject var store: AppStore
    @State private var filter = ""

    var body: some View {
        RepoListView(store: store, filterText: $filter, autofocusFilter: true)
            .frame(width: 320, height: 440)
    }
}

// MARK: Branch foldout (BranchesContainer — Task 13)

struct BranchFoldoutContent: View {
    @ObservedObject var store: AppStore
    @State private var filter = ""
    @State private var isCheckingOut = false

    private var repository: Repository? { store.selectedRepository }
    private var state: RepositoryState? { store.selectedState }

    private var allBranches: [Branch] { state?.branches ?? [] }
    private var currentBranch: Branch? {
        if case .valid(let branch) = state?.tip { return branch }
        return nil
    }

    var body: some View {
        BranchesContainerView(
            allBranches: allBranches,
            defaultBranch: state?.defaultBranch,
            currentBranch: currentBranch,
            recentBranches: [],
            filterText: $filter,
            canCreateNewBranch: repository != nil,
            hideFilterRow: false,
            isCommitsDragActive: false,
            onSelect: { branch in select(branch) },
            onCreateNewBranch: { name in createNew(name) },
            onRename: { branch in rename(branch) },
            onDelete: { branch in remove(branch) },
            onCheckoutInNewWorktree: { branch in checkoutInNewWorktree(branch) },
            onDropCommits: { branch, shas in dropCommits(branch, shas) },
            onMergeIntoCurrent: { mergeIntoCurrent() }
        )
        .frame(width: 365, height: 380)
        .overlay {
            if isCheckingOut {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.6)
                    ProgressView("Checking out…")
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .disabled(isCheckingOut)
    }

    private func select(_ branch: Branch) {
        guard let repository, !isCheckingOut else { return }
        // Tapping the current branch just dismisses.
        if branch.ref == currentBranch?.ref {
            store.closeFoldout()
            return
        }
        isCheckingOut = true
        Task {
            await shellCheckoutBranch(store: store, repository: repository, branch: branch)
            isCheckingOut = false
            store.closeFoldout()
        }
    }

    private func createNew(_ name: String) {
        guard let id = repository?.id else { return }
        store.closeFoldout()
        store.showPopup(.createBranch(repositoryID: id, initialName: name, targetCommitSHA: nil))
    }

    private func rename(_ branch: Branch) {
        guard let id = repository?.id else { return }
        store.closeFoldout()
        store.showPopup(.renameBranch(repositoryID: id, branchRef: branch.ref))
    }

    private func remove(_ branch: Branch) {
        guard let id = repository?.id else { return }
        store.closeFoldout()
        // `existsOnRemote` drives the also-delete-remote checkbox.
        let existsOnRemote = branch.upstreamRemoteName != nil
        store.showPopup(.deleteBranch(repositoryID: id, branchRef: branch.ref, existsOnRemote: existsOnRemote))
    }

    private func checkoutInNewWorktree(_ branch: Branch) {
        guard let id = repository?.id else { return }
        store.closeFoldout()
        store.showPopup(.addWorktree(
            repositoryID: id,
            initialBranchName: branch.nameWithoutRemote,
            initialWorktreeName: nil))
    }

    private func dropCommits(_ branch: Branch, _ shas: [String]) {
        // Commit-drag → cherry-pick seam (Task 6 owns the full flow; the
        // shell runs the op + banner so the drop target is live).
        guard let repository, !shas.isEmpty else { return }
        store.closeFoldout()
        Task {
            await shellCherryPickCommits(
                store: store, repository: repository,
                targetBranch: branch, shas: shas)
        }
    }

    private func mergeIntoCurrent() {
        guard let id = repository?.id else { return }
        store.closeFoldout()
        store.showPopup(.merge(repositoryID: id))
    }
}

// MARK: Add menu foldout

struct AddMenuFoldoutContent: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            foldoutButton(title: "Clone Repository…", detail: "Clone from a URL") {
                store.showPopup(.cloneRepository(initialURL: nil))
                store.closeFoldout()
            }
            foldoutButton(title: "Create New Repository…", detail: "Create on your local drive") {
                store.showPopup(.createRepository(path: nil))
                store.closeFoldout()
            }
            foldoutButton(title: "Add Existing Repository…", detail: "Add from your local drive") {
                store.showPopup(.addRepository(path: nil))
                store.closeFoldout()
            }
        }
        .padding(6)
        .frame(width: 280)
    }

    private func foldoutButton(title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Push/pull foldout (Fetch / Force push — Task 13 runs the real ops)

struct PushPullFoldoutContent: View {
    @ObservedObject var store: AppStore
    var pushPull: PushPullViewState
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            foldoutButton(
                title: fetchTitle,
                detail: "Fetch the remote without merging"
            ) {
                runFetch()
            }
            .disabled(isWorking || repository == nil || remote == nil)
            if pushPull.showsForcePushMenuItem {
                foldoutButton(
                    title: forcePushTitle,
                    detail: "Overwrite the remote branch"
                ) {
                    confirmForcePush()
                }
                .disabled(isWorking || repository == nil || remote == nil)
            }
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    private var repository: Repository? { store.selectedRepository }
    private var remote: Remote? { store.selectedState?.remote }

    private var remoteName: String? { remote?.name }

    private var fetchTitle: String {
        remoteName.map { "Fetch \($0)" } ?? "Fetch"
    }

    private var forcePushTitle: String {
        remoteName.map { "Force push \($0)…" } ?? "Force push…"
    }

    private func runFetch() {
        guard let repository, let remote, !isWorking else {
            store.closeFoldout()
            return
        }
        isWorking = true
        Task {
            await shellFetch(store: store, repository: repository, remote: remote)
            isWorking = false
            store.closeFoldout()
        }
    }

    private func confirmForcePush() {
        guard let id = repository?.id, let remote else {
            store.closeFoldout()
            return
        }
        // The actual force push runs after the confirm dialog.
        let branchName = currentBranchName ?? "branch"
        store.closeFoldout()
        store.showPopup(.confirmForcePush(
            repositoryID: id, upstreamBranch: "\(remote.name)/\(branchName)"))
    }

    private var currentBranchName: String? {
        if case .valid(let branch) = store.selectedState?.tip { return branch.name }
        return nil
    }

    private func foldoutButton(title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Worktree foldout (WorktreeList — Task 13)

struct WorktreeFoldoutContent: View {
    @ObservedObject var store: AppStore
    @State private var worktrees: [WorktreeEntry] = []
    @State private var filter = ""
    @State private var isLoading = false

    private var repository: Repository? { store.selectedRepository }

    var body: some View {
        WorktreeList(
            worktrees: worktrees,
            currentPath: repository?.path,
            filterText: filter,
            canCreateNewWorktree: repository != nil,
            onFilterChanged: { filter = $0 },
            onSwitch: { entry in
                guard let repository else { return }
                shellSwitchWorktree(store: store, repository: repository, worktree: entry)
            },
            onCreateNew: {
                guard let id = repository?.id else { return }
                store.closeFoldout()
                store.showPopup(.addWorktree(
                    repositoryID: id, initialBranchName: nil, initialWorktreeName: nil))
            },
            onRename: { entry in
                guard let id = repository?.id else { return }
                store.closeFoldout()
                store.showPopup(.renameWorktree(repositoryID: id, worktreePath: entry.path))
            },
            onDelete: { entry in
                guard let id = repository?.id else { return }
                store.closeFoldout()
                store.showPopup(.deleteWorktree(repositoryID: id, worktreePath: entry.path))
            },
            onRevealInFinder: { entry in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
        )
        .frame(width: 320, height: 380)
        .overlay {
            if isLoading {
                ProgressView().padding(8)
            }
        }
        .task(id: repository?.hash) { await load() }
    }

    private func load() async {
        guard let repository else {
            worktrees = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let service = await store.gitService(for: repository)
        // `worktrees()` is a `GitService` requirement, so mocks work too.
        worktrees = (try? await service.worktrees()) ?? []
    }
}

#Preview {
    HStack {
        BranchFoldoutContent(store: makePreviewStore())
        WorktreeFoldoutContent(store: makePreviewStore())
    }
    .padding()
}
