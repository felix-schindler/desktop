import SwiftUI

// MARK: - Branch + merge dialog adapters (Task 13)
// Thin shell adapters around the Task-5 branch/merge views. They resolve the
// repository + `RepositoryState` from the popup's `repositoryID`, feed the
// feature views explicit props, and run mutations through the Task-11
// pipeline (`ShellPipelineActions`) — never git directly.

struct CreateBranchDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var initialName: String?
    var targetCommitSHA: String?
    @State private var isCreating = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let state = store.repositoryStates[repository.hash]
                let branches = state?.branches ?? []
                let currentName: String? = {
                    if case .valid(let b) = state?.tip { return b.name }
                    return nil
                }()
                CreateBranchDialog(
                    initialName: initialName ?? "",
                    existingNames: branches.map(\.name),
                    defaultBranchName: state?.defaultBranch?.name,
                    currentBranchName: currentName,
                    fixedTargetCommitSHA: targetCommitSHA,
                    isCreating: isCreating,
                    onCreate: { name, startPoint in
                        isCreating = true
                        Task {
                            await shellCreateBranch(
                                store: store, repository: repository,
                                name: name, startPoint: startPoint,
                                fixedTargetSHA: targetCommitSHA,
                                currentBranchName: currentName,
                                defaultBranchName: state?.defaultBranch?.name)
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

struct RenameBranchDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var branchRef: String
    @State private var isRenaming = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store),
               let branch = store.repositoryStates[repository.hash]?.branches.first(where: { $0.ref == branchRef }) {
                let existing = (store.repositoryStates[repository.hash]?.branches ?? []).map(\.name)
                RenameBranchDialog(
                    branch: branch,
                    existingNames: existing,
                    isRenaming: isRenaming,
                    onRename: { newName in
                        isRenaming = true
                        Task {
                            await shellRenameBranch(
                                store: store, repository: repository,
                                branch: branch, newName: newName)
                            isRenaming = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Branch not found.")
            }
        }
    }
}

struct DeleteBranchDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var branchRef: String
    var existsOnRemote: Bool
    @State private var isDeleting = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store),
               let branch = store.repositoryStates[repository.hash]?.branches.first(where: { $0.ref == branchRef }) {
                DeleteBranchDialog(
                    branch: branch,
                    existsOnRemote: existsOnRemote,
                    isDeleting: isDeleting,
                    onDelete: { includeRemote in
                        isDeleting = true
                        Task {
                            await shellDeleteBranch(
                                store: store, repository: repository,
                                branch: branch, deleteRemote: includeRemote && existsOnRemote)
                            isDeleting = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Branch not found.")
            }
        }
    }
}

struct DeleteRemoteBranchDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var branchRef: String
    @State private var isDeleting = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let shortName = branchRef
                    .replacingOccurrences(of: #"^refs/remotes/"#, with: "", options: .regularExpression)
                ShellDialog(
                    title: "Delete Remote Branch",
                    primaryTitle: "Delete",
                    primaryAction: {
                        isDeleting = true
                        Task {
                            // Best-effort remote delete via push refspec.
                            let parts = shortName.split(separator: "/", maxSplits: 1).map(String.init)
                            if parts.count == 2 {
                                let remoteName = parts[0]
                                let branchName = parts[1]
                                let service = await store.gitService(for: repository)
                                let remotes = (try? await service.remotes()) ?? []
                                let remote = remotes.first { $0.name == remoteName } ?? Remote(name: remoteName, url: "")
                                do {
                                    let args = ["push", remoteName, ":\(branchName)"]
                                    let result = try await GitProcess.run(
                                        args, workingDirectory: repository.path,
                                        environment: envForRemoteOperation(remote.url))
                                    if let error = classifyGitResult(result, args: args, successExitCodes: [0]) {
                                        throw error
                                    }
                                    await store.refreshRepository(repository)
                                } catch {
                                    store.routeRefreshFailure(error, for: repository)
                                }
                            }
                            isDeleting = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete the remote branch '\(shortName)'? This cannot be undone.")
                        if isDeleting { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct MergeDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store),
               let state = store.repositoryStates[repository.hash],
               case .valid(let ourBranch) = state.tip {
                MergeWizardView(
                    repositoryPath: repository.path,
                    ourBranch: ourBranch,
                    allBranches: state.branches,
                    recentBranches: [],
                    defaultBranch: state.defaultBranch,
                    service: LiveMergeService(),
                    onBanner: { banner in
                        // Fix the Task-5 placeholder (`repositoryID: 0`) to the
                        // real repository so the banner can reopen this dialog.
                        let fixed: Banner = {
                            if case .mergeConflictsFound(let our, let inner) = banner,
                               case .multiCommitOperation(let rid) = inner, rid == 0 {
                                _ = inner
                                return .mergeConflictsFound(
                                    ourBranch: our, popup: .merge(repositoryID: repository.id))
                            }
                            return banner
                        }()
                        store.setBanner(fixed)
                    },
                    onShowPopup: { store.showPopup($0) },
                    onFinished: { _ in
                        store.closePopup(popup)
                        Task { await store.refreshRepository(repository) }
                    },
                    onCancel: {
                        store.closePopup(popup)
                        Task { await store.refreshRepository(repository) }
                    }
                )
            } else if repositoryForID(repositoryID, in: store) != nil {
                ErrorDialog(store: store, popup: popup, message: "No current branch to merge into.")
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct UnreachableCommitsDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let commits = store.repositoryStates[repository.hash]?.recentCommits ?? []
                // First commit reachable, the rest unreachable — enough to
                // exercise both tabs on a fixture repo.
                let reachable: Set<String> = {
                    guard let first = commits.first else { return [] }
                    return [first.sha]
                }()
                UnreachableCommitsDialog(
                    selectedCommits: commits,
                    shasInDiff: reachable,
                    localCommitSHAs: Set(commits.map(\.sha)),
                    onDismiss: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct CommitConflictsWarningDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var fileIDs: [String]

    var body: some View {
        CommitConflictsWarningView(
            filePaths: fileIDs,
            onCancel: { store.closePopup(popup) },
            onCommitAnyway: { store.closePopup(popup) }
        )
    }
}
