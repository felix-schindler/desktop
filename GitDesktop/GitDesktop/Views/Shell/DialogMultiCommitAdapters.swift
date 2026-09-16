import SwiftUI

// MARK: - Multi-commit dialog adapters (Task 13)
// Minimal but live wiring for the Task-6 flows so banner reopen actions and
// the `.multiCommitOperation` / `.warnForcePush` popups show bespoke dialogs
// instead of `GenericPopupDialog`. The full drag-drop + keyboard-reorder
// seams stay in the feature views (Task 6); the shell only drives
// choose → begin → banner + refresh.

struct MultiCommitOperationDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var kind: MultiCommitOperationKind
    var initialBranchName: String?
    @State private var pickedBase: Branch?
    @State private var isWorking = false

    var body: some View {
        Group {
            switch kind {
            case .merge, .squash:
                // Merge flows own a dedicated wizard (with squash preset);
                // reuse its adapter so banner fixup + refresh stay in one place.
                MergeDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    initialSquash: kind == .squash,
                    initialBranchName: initialBranchName)
            case .rebase, .cherryPick, .reorder:
                rebaseChooser
            }
        }
    }

    /// Rebase choose-branch step. Cherry-pick/reorder have no choose-branch
    /// entry in the reference (they start from commits); they fall back here
    /// because the shell keeps no in-flight operation state to render true
    /// conflict-reopen steps yet — the previously shown UI is unchanged.
    @ViewBuilder
    private var rebaseChooser: some View {
        if let repository = repositoryForID(repositoryID, in: store),
           let state = store.repositoryStates[repository.hash],
           case .valid(let current) = state.tip {
            MultiCommitWizardView(
                step: .chooseBranch(kind: .rebase),
                currentBranch: current,
                branches: state.branches,
                initialBranchName: initialBranchName,
                defaultBranchName: state.defaultBranch?.name,
                onPickBaseBranch: { pickedBase = $0 },
                onBegin: { beginRebase(repository: repository, current: current) },
                onDismiss: { store.closePopup(popup) }
            )
            .overlay {
                if isWorking {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor).opacity(0.6)
                        ProgressView("Rebasing…").padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .disabled(isWorking)
        } else {
            ErrorDialog(store: store, popup: popup, message: "No current branch for this operation.")
        }
    }

    private func beginRebase(repository: Repository, current: Branch) {
        guard let base = pickedBase, !isWorking else { return }
        // Force-push gate first (mirrors the reference warn-force-push step).
        if Defaults.bool(Defaults.confirmForcePush, default: true) {
            store.showPopup(.warnForcePush(operation: MultiCommitOperationKind.rebase.rawValue))
            return
        }
        isWorking = true
        Task {
            let service = LiveMultiCommitService()
            do {
                let result = try await service.rebase(
                    repositoryPath: repository.path,
                    baseBranch: base.name, targetBranch: current.name)
                await store.refreshRepository(repository)
                if let banner = rebaseResultBanner(
                    result, targetBranch: current.name, baseBranch: base.name) {
                    store.setBanner(banner)
                }
            } catch {
                if let gitError = error as? GitError {
                    store.showPopup(.error(message: gitError.displayMessage))
                } else {
                    store.showPopup(.error(message: error.localizedDescription))
                }
            }
            isWorking = false
            store.closePopup(popup)
        }
    }
}

struct WarnForcePushDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var operation: String

    var body: some View {
        let kind = MultiCommitOperationKind(rawValue: operation) ?? .rebase
        WarnForcePushView(
            operation: kind,
            askForConfirmationOnForcePush: Defaults.bool(Defaults.confirmForcePush, default: true),
            onBegin: {
                // Persisted inside the view too; close and let the caller
                // continue (the rebase adapter re-checks the default).
                store.closePopup(popup)
            },
            onConfirmSetting: { Defaults.setBool($0, Defaults.confirmForcePush) },
            onDismiss: { store.closePopup(popup) }
        )
    }
}

struct CommitMessageDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var dialogTitle: String
    var dialogButtonText: String
    @State private var message = ""

    var body: some View {
        ShellDialog(
            title: dialogTitle,
            primaryTitle: dialogButtonText,
            primaryAction: { store.closePopup(popup) },
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter a commit message for this operation.")
                    .foregroundStyle(.secondary)
                TextField("Commit message", text: $message)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
