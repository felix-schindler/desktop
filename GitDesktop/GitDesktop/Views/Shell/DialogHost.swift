import AppKit
import SwiftUI

// MARK: - DialogHost
// Sheet stack for the pruned `Popup` set (Docs/04-shell-toolbar.md §7).
// Presents `AppStore.currentPopup` (top of the ≤50 stack) via
// `.sheet(item:)`: Esc dismisses (native), focus lands on the primary field
// or button, and stacked sheets restore in order.
//
// Task 13 composition: every popup owned by Tasks 5–8 renders its bespoke
// dialog (branch/merge/tag/worktree/unreachable + multi-commit + sync +
// stash/undo/reset/LFS). Only Task-3 commit-flow confirms still use
// `GenericPopupDialog` until the Changes composition lands.

struct DialogHost: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: popupBinding) { popup in
                PopupSheet(store: store, popup: popup)
            }
    }

    private var popupBinding: Binding<Popup?> {
        Binding(
            get: { store.currentPopup },
            set: { newValue in
                if newValue == nil, let current = store.currentPopup {
                    store.closePopup(current)
                }
            }
        )
    }
}

struct PopupSheet: View {
    @ObservedObject var store: AppStore
    var popup: Popup

    var body: some View {
        Group {
            switch popup {
            case .removeRepository(let repositoryID):
                RemoveRepositoryDialog(store: store, popup: popup, repositoryID: repositoryID)
            case .changeRepositoryAlias(let repositoryID):
                ChangeAliasDialog(store: store, popup: popup, repositoryID: repositoryID)
            case .about:
                AboutDialog(store: store, popup: popup)
            case .error(let message):
                ErrorDialog(store: store, popup: popup, message: message)
            case .acknowledgements:
                AcknowledgementsFullDialog(store: store, popup: popup)
            case .shortcuts:
                ShortcutsDialog(store: store, popup: popup)
            case .preferences(let initialTab):
                SettingsView(store: store, popup: popup, initialTab: settingsTab(for: initialTab))
            case .repositorySettings(let repositoryID, let initialTab):
                RepositorySettingsView(
                    store: store, popup: popup, repositoryID: repositoryID,
                    initialTab: repositorySettingsTab(for: initialTab))
            case .addRepository(let path):
                AddExistingRepositoryDialog(store: store, popup: popup, initialPath: path)
            case .createRepository(let path):
                CreateRepositoryDialog(store: store, popup: popup, initialPath: path)
            case .cloneRepository(let initialURL):
                CloneRepositoryDialog(store: store, popup: popup, initialURL: initialURL)
            case .createTutorialRepository:
                CreateTutorialRepositoryDialog(store: store, popup: popup)
            case .confirmExitTutorial:
                ConfirmExitTutorialDialog(store: store, popup: popup)
            case .moveToApplicationsFolder:
                MoveToApplicationsDialog(store: store, popup: popup)
            case .cliInstalled:
                CLIInstalledDialog(store: store, popup: popup)
            case .installingUpdate:
                InstallingUpdateDialog(store: store, popup: popup)
            case .installGit(let path):
                InstallGitDialog(store: store, popup: popup, path: path)
            case .releaseNotes:
                ReleaseNotesDialog(store: store, popup: popup)
            case .termsAndConditions:
                TermsDialog(store: store, popup: popup)
            case .thankYou:
                // Deleted surface per scope; never presented in practice.
                EmptyView()
            // MARK: Branches + merge (Task 5, composed in Task 13)
            case .createBranch(let repositoryID, let initialName, let targetCommitSHA):
                CreateBranchDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    initialName: initialName, targetCommitSHA: targetCommitSHA)
            case .renameBranch(let repositoryID, let branchRef):
                RenameBranchDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, branchRef: branchRef)
            case .deleteBranch(let repositoryID, let branchRef, let existsOnRemote):
                DeleteBranchDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    branchRef: branchRef, existsOnRemote: existsOnRemote)
            case .deleteRemoteBranch(let repositoryID, let branchRef):
                DeleteRemoteBranchDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, branchRef: branchRef)
            case .merge(let repositoryID):
                MergeDialogAdapter(store: store, popup: popup, repositoryID: repositoryID)
            case .unreachableCommits(let repositoryID):
                UnreachableCommitsDialogAdapter(store: store, popup: popup, repositoryID: repositoryID)
            case .commitConflictsWarning(_, let fileIDs):
                CommitConflictsWarningDialogAdapter(store: store, popup: popup, fileIDs: fileIDs)
            // MARK: Multi-commit (Task 6, composed in Task 13)
            case .multiCommitOperation(let repositoryID):
                MultiCommitOperationDialogAdapter(store: store, popup: popup, repositoryID: repositoryID)
            case .warnForcePush(let operation):
                WarnForcePushDialogAdapter(store: store, popup: popup, operation: operation)
            case .commitMessage(_, let dialogTitle, let dialogButtonText):
                CommitMessageDialogAdapter(
                    store: store, popup: popup,
                    dialogTitle: dialogTitle, dialogButtonText: dialogButtonText)
            // MARK: Sync (Task 7, composed in Task 13)
            case .pushNeedsPull(let repositoryID):
                PushNeedsPullDialogAdapter(store: store, popup: popup, repositoryID: repositoryID)
            case .confirmForcePush(let repositoryID, let upstreamBranch):
                ConfirmForcePushDialogAdapter(
                    store: store, popup: popup,
                    repositoryID: repositoryID, upstreamBranch: upstreamBranch)
            case .localChangesOverwritten(_, let files):
                LocalChangesOverwrittenDialogAdapter(store: store, popup: popup, files: files)
            case .upstreamAlreadyExists(_, let existingRemoteName):
                UpstreamAlreadyExistsDialogAdapter(
                    store: store, popup: popup, existingRemoteName: existingRemoteName)
            case .pushBranchCommits(let repositoryID, let branchRef, let unpushedCommits):
                PushBranchCommitsDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    branchRef: branchRef, unpushedCommits: unpushedCommits)
            case .genericGitAuthentication(let remoteURL, let username):
                GenericGitAuthDialogAdapter(
                    store: store, popup: popup, remoteURL: remoteURL, username: username)
            case .untrustedCertificate(let host, let certificateData):
                UntrustedCertificateDialogAdapter(
                    store: store, popup: popup, host: host, certificateData: certificateData)
            case .addSSHHost(let host, let fingerprint):
                AddSSHHostDialogAdapter(
                    store: store, popup: popup, host: host, fingerprint: fingerprint)
            case .sshKeyPassphrase(let keyPath):
                SSHKeyPassphraseDialogAdapter(store: store, popup: popup, keyPath: keyPath)
            case .sshUserPassword(let username):
                SSHUserPasswordDialogAdapter(store: store, popup: popup, username: username)
            // MARK: Stash / tags / worktrees / undo / LFS (Task 8, composed in Task 13)
            case .stashAndSwitchBranch(let repositoryID, let branchRef):
                StashAndSwitchDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, branchRef: branchRef)
            case .confirmOverwriteStash:
                ConfirmOverwriteStashDialogAdapter(store: store, popup: popup)
            case .confirmDiscardStash(let repositoryID, let stashName):
                ConfirmDiscardStashDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, stashName: stashName)
            case .createTag(let repositoryID, let targetCommitSHA, let initialName):
                CreateTagDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    targetCommitSHA: targetCommitSHA, initialName: initialName)
            case .deleteTag(let repositoryID, let tagName):
                DeleteTagDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, tagName: tagName)
            case .confirmCheckoutCommit(let repositoryID, let commitSHA):
                ConfirmCheckoutCommitDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, commitSHA: commitSHA)
            case .warningBeforeReset(let repositoryID, let commitSHA):
                WarningBeforeResetDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, commitSHA: commitSHA)
            case .warnLocalChangesBeforeUndo(let repositoryID, let commitSHA, let isClean):
                WarnLocalChangesBeforeUndoDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    commitSHA: commitSHA, isWorkingDirectoryClean: isClean)
            case .addWorktree(let repositoryID, let initialBranchName, _):
                AddWorktreeDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID,
                    initialBranchName: initialBranchName)
            case .renameWorktree(let repositoryID, let worktreePath):
                RenameWorktreeDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, worktreePath: worktreePath)
            case .deleteWorktree(let repositoryID, let worktreePath):
                DeleteWorktreeDialogAdapter(
                    store: store, popup: popup, repositoryID: repositoryID, worktreePath: worktreePath)
            case .deleteWorktreeFailed(_, let worktreePath, let message):
                DeleteWorktreeFailedDialog(
                    worktreePath: worktreePath, message: message,
                    onDismiss: { store.closePopup(popup) })
            case .initializeLFS(let repositoryIDs):
                InitializeLFSDialogAdapter(store: store, popup: popup, repositoryIDs: repositoryIDs)
            case .lfsAttributeMismatch:
                LFSAttributeMismatchDialogAdapter(store: store, popup: popup)
            default:
                GenericPopupDialog(store: store, popup: popup)
            }
        }
    }

    private func settingsTab(for initialTab: String?) -> SettingsTab {
        guard let initialTab else { return .git }
        return SettingsTab(rawValue: initialTab) ?? .git
    }

    private func repositorySettingsTab(for initialTab: String?) -> RepositorySettingsTab {
        guard let initialTab else { return .remote }
        return RepositorySettingsTab(rawValue: initialTab) ?? .remote
    }
}

// MARK: - ShellDialog container

/// Fixed-width dialog card: title, content, Cancel + primary buttons.
/// Enter confirms (`.defaultAction`), Esc cancels (`.cancelAction`).
struct ShellDialog<Content: View>: View {
    var title: String
    var primaryTitle: String
    var primaryAction: () -> Void
    var cancelTitle: String = "Cancel"
    var showsCancel: Bool = true
    var autoFocusPrimary: Bool = true
    var onCancel: () -> Void
    @ViewBuilder var content: () -> Content

    @FocusState private var primaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
                .font(.system(size: 12))
            HStack {
                Spacer()
                if showsCancel {
                    Button(cancelTitle, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(primaryTitle, action: primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .focused($primaryFocused)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if autoFocusPrimary {
                // Let sheet animation settle before grabbing focus.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    primaryFocused = true
                }
            }
        }
    }
}

// MARK: - Owned dialogs

struct RemoveRepositoryDialog: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    @State private var dontAskAgain = false

    private var repository: Repository? {
        store.repositories.first { $0.id == repositoryID }
    }

    var body: some View {
        ShellDialog(
            title: "Remove Repository",
            primaryTitle: "Remove",
            primaryAction: confirm,
            autoFocusPrimary: true,
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remove this repository from GitDesktop? This does not delete any files on disk.")
                Toggle("Don't ask again", isOn: $dontAskAgain)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func confirm() {
        if dontAskAgain {
            Defaults.setBool(false, Defaults.confirmRepoRemoval)
        }
        if let repository {
            store.removeRepository(repository)
            store.persistRepositories()
        }
        store.closePopup(popup)
    }
}

struct ChangeAliasDialog: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    @State private var alias: String = ""
    @FocusState private var fieldFocused: Bool

    private var repository: Repository? {
        store.repositories.first { $0.id == repositoryID }
    }

    var body: some View {
        ShellDialog(
            title: repository?.alias == nil ? "Create Alias" : "Change Alias",
            primaryTitle: "Save",
            primaryAction: save,
            autoFocusPrimary: false,
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Give \(repository?.name ?? "this repository") a short, memorable name. Leave empty to remove the alias.")
                TextField("Alias", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(save)
            }
        }
        .onAppear {
            alias = repository?.alias ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                fieldFocused = true
            }
        }
    }

    private func save() {
        if let repository {
            store.setAlias(alias, for: repository)
        }
        store.closePopup(popup)
    }
}

struct AboutDialog: View {
    @ObservedObject var store: AppStore
    var popup: Popup

    var body: some View {
        ShellDialog(
            title: "About GitDesktop",
            primaryTitle: "Close",
            primaryAction: { store.closePopup(popup) },
            showsCancel: false,
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("GitDesktop \(appVersion)")
                Text("A native macOS Git client.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Acknowledgements") {
                        store.closePopup(popup)
                        store.showPopup(.acknowledgements)
                    }
                    .buttonStyle(.link)
                    Button("Release Notes") {
                        store.closePopup(popup)
                        store.showPopup(.releaseNotes)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0 (dev)"
    }
}

struct ErrorDialog: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var message: String

    var body: some View {
        ShellDialog(
            title: "Error",
            primaryTitle: "Dismiss",
            primaryAction: { store.closePopup(popup) },
            showsCancel: false,
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .textSelection(.enabled)
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(.link)
            }
        }
    }
}

// MARK: - Generic dialog (owning tasks replace these)

struct GenericPopupDialog: View {
    @ObservedObject var store: AppStore
    var popup: Popup

    private var descriptor: PopupDescriptor { describePopup(popup) }

    var body: some View {
        ShellDialog(
            title: descriptor.title,
            primaryTitle: descriptor.primaryTitle,
            primaryAction: { store.closePopup(popup) },
            showsCancel: descriptor.showsCancel,
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let message = descriptor.message {
                    Text(message)
                }
                if let task = descriptor.owningTask {
                    Text("The full dialog lands in Task \(task).")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    PreviewDialogHost()
}

private struct PreviewDialogHost: View {
    @State var store: AppStore = makePreviewStore()

    var body: some View {
        VStack(spacing: 12) {
            Button("Show Error") { store.showPopup(.error(message: "Something went wrong.")) }
            Button("Show Remove") {
                if let id = store.repositories.first?.id {
                    store.showPopup(.removeRepository(repositoryID: id))
                }
            }
            Button("Show Alias") {
                if let id = store.repositories.first?.id {
                    store.showPopup(.changeRepositoryAlias(repositoryID: id))
                }
            }
        }
        .padding()
        .background(DialogHost(store: store))
    }
}
