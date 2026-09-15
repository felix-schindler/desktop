import SwiftUI

// MARK: - Stash / undo / reset / LFS dialog adapters (Task 13)
// Bespoke sheets for the Task-8 popups. Destructive git work runs through
// the pipeline (`performPipelineMutation`) so the UI refreshes coherently;
// "Do not show again" prefs persist via `Defaults` in the feature views.

struct StashAndSwitchDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var branchRef: String
    @State private var isWorking = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let state = store.repositoryStates[repository.hash]
                let currentName: String = {
                    if case .valid(let b) = state?.tip { return b.name }
                    return "current branch"
                }()
                let targetName = branchRef
                    .replacingOccurrences(of: #"^refs/heads/"#, with: "", options: .regularExpression)
                StashAndSwitchDialog(
                    currentBranchName: currentName,
                    targetBranchName: targetName,
                    hasAssociatedStash: false,
                    isWorking: isWorking,
                    onStashOnCurrentBranch: {
                        isWorking = true
                        Task {
                            _ = await store.performPipelineMutation(for: repository) { service in
                                _ = try await service.createStash(branchName: currentName)
                                return true
                            }
                            // After stashing, check out the target.
                            if let target = state?.branches.first(where: { $0.ref == branchRef }) {
                                await shellCheckoutBranch(store: store, repository: repository, branch: target)
                            }
                            isWorking = false
                            store.closePopup(popup)
                        }
                    },
                    onBringToNewBranch: {
                        // Leave changes in the working directory and switch.
                        isWorking = true
                        Task {
                            if let target = state?.branches.first(where: { $0.ref == branchRef }) {
                                await shellCheckoutBranch(store: store, repository: repository, branch: target)
                            }
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

struct ConfirmOverwriteStashDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    @State private var isWorking = false

    var body: some View {
        ConfirmOverwriteStashDialog(
            branchName: branchName,
            isWorking: isWorking,
            onOverwrite: { store.closePopup(popup) },
            onCancel: { store.closePopup(popup) }
        )
    }

    private var branchName: String {
        if case .confirmOverwriteStash(_, let ref) = popup { return ref ?? "this branch" }
        return "this branch"
    }
}

struct ConfirmDiscardStashDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var stashName: String
    @State private var isDiscarding = false

    var body: some View {
        Group {
            if repositoryForID(repositoryID, in: store) != nil {
                ConfirmDiscardStashDialog(
                    stashName: stashName,
                    isDiscarding: isDiscarding,
                    onDiscard: { doNotShowAgain in
                        if doNotShowAgain {
                            Defaults.setBool(false, Defaults.confirmDiscardStash)
                        }
                        store.closePopup(popup)
                    },
                    onCancel: { store.closePopup(popup) }
                )
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct ConfirmCheckoutCommitDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var commitSHA: String
    @State private var isWorking = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let summary = store.repositoryStates[repository.hash]?.recentCommits
                    .first { $0.sha == commitSHA }?.summary
                ConfirmCheckoutCommitDialog(
                    commitSha: commitSHA,
                    commitSummary: summary,
                    isWorking: isWorking,
                    onCheckout: {
                        isWorking = true
                        Task {
                            _ = await store.performPipelineMutation(for: repository) { service in
                                try await service.checkoutCommit(sha: commitSHA)
                                return true
                            }
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

struct WarningBeforeResetDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var commitSHA: String
    @State private var isWorking = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let state = store.repositoryStates[repository.hash]
                let summary = state?.recentCommits.first { $0.sha == commitSHA }?.summary
                let isClean = state?.workingDirectory.files.isEmpty ?? true
                WarningBeforeResetDialog(
                    commitSha: commitSHA,
                    commitSummary: summary,
                    isWorkingDirectoryClean: isClean,
                    isWorking: isWorking,
                    onReset: { mode in
                        isWorking = true
                        Task {
                            _ = await store.performPipelineMutation(for: repository) { service in
                                try await service.reset(mode: mode, ref: commitSHA)
                                return true
                            }
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

struct WarnLocalChangesBeforeUndoDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var commitSHA: String
    var isWorkingDirectoryClean: Bool
    @State private var isWorking = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let commit = store.repositoryStates[repository.hash]?.recentCommits
                    .first { $0.sha == commitSHA }
                WarnLocalChangesBeforeUndoDialog(
                    commitSha: commitSHA,
                    isMergeCommit: (commit?.parentSHAs.count ?? 0) > 1,
                    isWorkingDirectoryClean: isWorkingDirectoryClean,
                    isWorking: isWorking,
                    onContinue: { doNotShowAgain in
                        if doNotShowAgain {
                            Defaults.setBool(false, Defaults.confirmUndoCommit)
                        }
                        isWorking = true
                        Task {
                            if let commit {
                                _ = await store.performPipelineMutation(for: repository) { service in
                                    try await service.undoCommit(commit)
                                    return true
                                }
                            }
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

struct InitializeLFSDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryIDs: [Int]
    @State private var isInstalling = false

    var body: some View {
        InitializeLFSView(
            isInstalling: isInstalling,
            onInstall: {
                isInstalling = true
                Task {
                    for id in repositoryIDs {
                        if let repository = repositoryForID(id, in: store) {
                            _ = await store.performPipelineMutation(for: repository) { service in
                                try await service.installLFSHooks(force: false)
                                return true
                            }
                        }
                    }
                    isInstalling = false
                    store.closePopup(popup)
                }
            },
            onDismiss: { store.closePopup(popup) }
        )
    }
}

struct LFSAttributeMismatchDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup

    var body: some View {
        ShellDialog(
            title: "Git LFS Configuration",
            primaryTitle: "Close",
            primaryAction: { store.closePopup(popup) },
            showsCancel: false,
            onCancel: { store.closePopup(popup) }
        ) {
            LFSAttributeMismatchView(onDismiss: { store.closePopup(popup) })
        }
    }
}
