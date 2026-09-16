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

    /// Rebase choose-branch step (plus the live conflicts step). Cherry-pick
    /// and reorder have no choose-branch entry in the reference (they start
    /// from commits), so a fresh dialog for them still falls back to the
    /// rebase chooser — but while an operation is actually in flight
    /// (sequencer state on disk) the conflicts step renders instead, with
    /// live Continue / Abort driving the real git state.
    @ViewBuilder
    private var rebaseChooser: some View {
        if let repository = repositoryForID(repositoryID, in: store),
           let state = store.repositoryStates[repository.hash],
           case .valid(let current) = state.tip,
           let inFlight = store.inFlightMultiCommitOps[repository.hash],
           inFlightConflicts(repositoryPath: repository.path, kind: inFlight.kind) {
            let files = state.workingDirectory.files
                .filter { $0.status.isConflicted }
                .map { MultiCommitConflictFile(path: $0.path, isResolved: true) }
            MultiCommitWizardView(
                step: .showConflicts(kind: inFlight.kind, files: files),
                currentBranch: current,
                branches: state.branches,
                conflictFiles: files,
                onContinue: {
                    Task {
                        await shellContinueMultiCommitOp(
                            store: store, repository: repository, popup: popup)
                    }
                },
                onAbort: {
                    Task {
                        await shellAbortMultiCommitOp(
                            store: store, repository: repository, popup: popup)
                    }
                },
                onDismiss: { store.closePopup(popup) }
            )
        } else if let repository = repositoryForID(repositoryID, in: store),
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
        // Force-push gate (mirrors `startRebase`): warn only when the setting
        // is on AND the target's upstream actually has commits outside the
        // target tip. Confirming continues without re-warning.
        isWorking = true
        Task {
            let warn: Bool
            if Defaults.bool(Defaults.confirmForcePush, default: true) {
                warn = await warnAboutRemoteCommits(
                    repositoryPath: repository.path,
                    upstream: current.upstream,
                    oldestCommitRef: current.tip.sha)
            } else {
                warn = false
            }
            if warn {
                isWorking = false
                store.showPopup(.warnForcePush(
                    operation: MultiCommitOperationKind.rebase.rawValue,
                    repositoryID: repository.id,
                    baseBranchName: base.name,
                    targetBranchName: current.name))
                return
            }
            await shellRebaseBranch(
                store: store, repository: repository, popup: popup,
                baseBranchName: base.name, targetBranchName: current.name)
            isWorking = false
        }
    }
}

struct WarnForcePushDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var operation: String
    var repositoryID: Int
    var baseBranchName: String
    var targetBranchName: String

    var body: some View {
        let kind = MultiCommitOperationKind(rawValue: operation) ?? .rebase
        WarnForcePushView(
            operation: kind,
            askForConfirmationOnForcePush: Defaults.bool(Defaults.confirmForcePush, default: true),
            onBegin: {
                // Continue without re-warning (reference `continueWithForcePush`):
                // the gate already ran, so this path executes directly.
                guard let repository = repositoryForID(repositoryID, in: store) else {
                    store.closePopup(popup)
                    return
                }
                Task {
                    await shellRebaseBranch(
                        store: store, repository: repository, popup: popup,
                        baseBranchName: baseBranchName, targetBranchName: targetBranchName)
                }
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
