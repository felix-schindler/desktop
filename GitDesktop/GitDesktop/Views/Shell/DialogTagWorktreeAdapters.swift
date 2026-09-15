import SwiftUI

// MARK: - Tag + worktree dialog adapters (Task 13)

struct CreateTagDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var targetCommitSHA: String
    var initialName: String?
    @State private var isCreating = false
    @State private var existingTags: Set<String> = []
    @State private var targetSummary: String?

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                CreateTagForm(
                    targetCommitSha: targetCommitSHA,
                    targetSummary: targetSummary,
                    existingTags: existingTags,
                    initialName: initialName ?? "",
                    isCreating: isCreating,
                    onCancel: { store.closePopup(popup) },
                    onCreate: { name in
                        isCreating = true
                        Task {
                            await shellCreateTag(
                                store: store, repository: repository,
                                name: name, targetSHA: targetCommitSHA)
                            isCreating = false
                            store.closePopup(popup)
                        }
                    }
                )
                .task(id: repository.hash) { await load(repository) }
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }

    private func load(_ repository: Repository) async {
        let service = await store.gitService(for: repository)
        let tagDict: [String: String]? = try? await service.allTags()
        let tagKeys: [String] = tagDict.map { Array($0.keys) } ?? []
        existingTags = Set(tagKeys)
        if targetSummary == nil {
            let fetched: [Commit]? = try? await service.commits(range: nil, limit: 100)
            let commits = fetched ?? []
            var found: String?
            for commit in commits where commit.sha == targetCommitSHA {
                found = commit.summary
                break
            }
            targetSummary = found
        }
    }
}

struct DeleteTagDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var tagName: String
    @State private var isDeleting = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                DeleteTagDialog(
                    tagName: tagName,
                    isPushed: false,
                    isDeleting: isDeleting,
                    onDelete: {
                        isDeleting = true
                        Task {
                            await shellDeleteTag(store: store, repository: repository, name: tagName)
                            isDeleting = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct AddWorktreeDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var initialBranchName: String?
    @State private var isCreating = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                AddWorktreeDialog(
                    initialBranchName: initialBranchName,
                    isCreating: isCreating,
                    pathExists: { FileManager.default.fileExists(atPath: $0) },
                    onCreate: { path, createBranch, commitish in
                        isCreating = true
                        Task {
                            await shellAddWorktree(
                                store: store, repository: repository,
                                path: path, createBranch: createBranch, commitish: commitish)
                            isCreating = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct RenameWorktreeDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var worktreePath: String
    @State private var isWorking = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                RenameWorktreeDialog(
                    worktreePath: worktreePath,
                    isWorking: isWorking,
                    onRename: { newPath in
                        isWorking = true
                        Task {
                            await shellRenameWorktree(
                                store: store, repository: repository,
                                oldPath: worktreePath, newPath: newPath)
                            isWorking = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct DeleteWorktreeDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var worktreePath: String
    @State private var isDeleting = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                DeleteWorktreeDialog(
                    worktreePath: worktreePath,
                    isDeleting: isDeleting,
                    onDelete: { force in
                        isDeleting = true
                        Task {
                            // `shellRemoveWorktree` posts `.deleteWorktreeFailed`
                            // itself when the remove fails; close this sheet in
                            // both cases (the failed sheet stacks on top).
                            await shellRemoveWorktree(
                                store: store, repository: repository,
                                path: worktreePath, force: force)
                            isDeleting = false
                            store.closePopup(popup)
                            Task { await store.refreshRepository(repository) }
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}
