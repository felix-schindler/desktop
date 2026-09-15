import SwiftUI

// MARK: - Sync dialog adapters (Task 13)
// Bespoke sheets for the Task-7 sync error chain + auth challenges. All run
// through the pipeline helpers so menu and toolbar share one code path
// (Task 14 reuses `shellFetch`/`shellPull`/`shellPush`).

struct PushNeedsPullDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    @State private var isFetching = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                let remote = store.repositoryStates[repository.hash]?.remote
                ShellDialog(
                    title: "Push Needs Pull",
                    primaryTitle: "Fetch",
                    primaryAction: {
                        guard let remote, !isFetching else {
                            store.closePopup(popup)
                            return
                        }
                        isFetching = true
                        Task {
                            await shellFetch(store: store, repository: repository, remote: remote)
                            isFetching = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The remote contains work that you do not have locally. Fetch and merge the remote changes, then push again.")
                        if isFetching { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct ConfirmForcePushDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var upstreamBranch: String
    @State private var isPushing = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store) {
                ShellDialog(
                    title: "Confirm Force Push",
                    primaryTitle: "Force Push",
                    primaryAction: {
                        guard !isPushing else { return }
                        // Parse "remote/branch" from the upstream label.
                        let parts = upstreamBranch.split(separator: "/", maxSplits: 1).map(String.init)
                        guard parts.count == 2,
                              let state = store.repositoryStates[repository.hash],
                              let remote = state.remotes.first(where: { $0.name == parts[0] }) ?? state.remote,
                              case .valid(let branch) = state.tip
                        else {
                            store.closePopup(popup)
                            return
                        }
                        isPushing = true
                        Task {
                            await shellPush(
                                store: store, repository: repository, remote: remote,
                                localBranch: branch.name, remoteBranch: parts[1],
                                forceWithLease: true)
                            isPushing = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Force pushing will overwrite \(upstreamBranch) on the remote. This cannot be undone.")
                        if isPushing { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct LocalChangesOverwrittenDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var files: [String]

    var body: some View {
        ShellDialog(
            title: "Local Changes Overwritten",
            primaryTitle: "Close",
            primaryAction: { store.closePopup(popup) },
            showsCancel: false,
            onCancel: { store.closePopup(popup) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(files.count) file(s) with local changes would be overwritten. Commit or stash them first.")
                if !files.isEmpty {
                    ForEach(files.prefix(10), id: \.self) { path in
                        Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    if files.count > 10 {
                        Text("…and \(files.count - 10) more").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct UpstreamAlreadyExistsDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var existingRemoteName: String

    var body: some View {
        ShellDialog(
            title: "Upstream Already Exists",
            primaryTitle: "Close",
            primaryAction: { store.closePopup(popup) },
            showsCancel: false,
            onCancel: { store.closePopup(popup) }
        ) {
            Text("The remote '\(existingRemoteName)' already exists.")
        }
    }
}

struct PushBranchCommitsDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var repositoryID: Int
    var branchRef: String
    var unpushedCommits: Int?
    @State private var isPushing = false

    var body: some View {
        Group {
            if let repository = repositoryForID(repositoryID, in: store),
               let state = store.repositoryStates[repository.hash],
               let remote = state.remote ?? state.remotes.first,
               case .valid(let branch) = state.tip {
                ShellDialog(
                    title: "Push Branch",
                    primaryTitle: "Push",
                    primaryAction: {
                        guard !isPushing else { return }
                        isPushing = true
                        Task {
                            await shellPush(
                                store: store, repository: repository, remote: remote,
                                localBranch: branch.name,
                                remoteBranch: branch.upstreamWithoutRemote,
                                forceWithLease: false)
                            isPushing = false
                            store.closePopup(popup)
                        }
                    },
                    onCancel: { store.closePopup(popup) }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        let count = unpushedCommits.map { "\($0) unpushed commit(s) on " } ?? ""
                        Text("Push \(count)\(branch.name) to \(remote.name)?")
                        if isPushing { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                ErrorDialog(store: store, popup: popup, message: "Repository not found.")
            }
        }
    }
}

struct GenericGitAuthDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var remoteURL: String
    var username: String?

    var body: some View {
        GenericGitAuthenticationView(
            remoteURL: remoteURL,
            fixedUsername: username,
            onSave: { _, _ in
                // Credentials go to the macOS keychain via the next git
                // invocation (`fillCredential`); the shell just dismisses and
                // lets the user retry the sync operation.
                store.closePopup(popup)
            },
            onDismiss: { store.closePopup(popup) }
        )
    }
}

struct UntrustedCertificateDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var host: String
    var certificateData: String

    var body: some View {
        UntrustedCertificateView(
            host: host,
            certificateData: certificateData,
            onContinue: { store.closePopup(popup) },
            onDismiss: { store.closePopup(popup) }
        )
    }
}

struct AddSSHHostDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var host: String
    var fingerprint: String

    var body: some View {
        AddSSHHostView(
            host: host, fingerprint: fingerprint,
            onSubmit: { _ in },
            onDismiss: { store.closePopup(popup) }
        )
    }
}

struct SSHKeyPassphraseDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var keyPath: String

    var body: some View {
        SSHKeyPassphraseView(
            keyPath: keyPath,
            onSubmit: { _, _ in },
            onDismiss: { store.closePopup(popup) }
        )
    }
}

struct SSHUserPasswordDialogAdapter: View {
    @ObservedObject var store: AppStore
    var popup: Popup
    var username: String

    var body: some View {
        SSHUserPasswordView(
            username: username,
            onSubmit: { _, _ in },
            onDismiss: { store.closePopup(popup) }
        )
    }
}
