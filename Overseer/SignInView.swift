import AppKit
import SwiftUI

/// Signs in a GitHub account with the device flow: shows the code, opens github.com/login/device,
/// and waits for the user to approve.
struct SignInView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Phase: Equatable {
        case starting
        case waiting(code: String, url: URL)
        case failed(String)
    }

    @State var phase: Phase = .starting
    /// Debug snapshots show a fixed code and never call GitHub.
    var isPreview = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Sign in to GitHub").font(.title2.weight(.semibold))
            content
        }
        .padding(28)
        .frame(width: 420)
        .task {
            guard !isPreview else { return }
            await signIn()
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .starting:
            ProgressView().controlSize(.small)
            cancel
        case .waiting(let code, let url):
            Text("Enter this code on GitHub to let Overseer use your account. Each account you add sees only what it has access to.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for GitHub…").foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
                cancel
                Spacer()
                Button("Copy Code and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    openURL(url)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                cancel
                Spacer()
                Button("Try Again") {
                    phase = .starting
                    Task { await signIn() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var cancel: some View {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
    }

    private func signIn() async {
        do {
            let code = try await DeviceFlow.start()
            phase = .waiting(code: code.userCode, url: code.verificationURI)
            let token = try await DeviceFlow.token(for: code)
            let login = try await GitHubClient(token: token).viewerLogin()
            try store.accounts.add(login, token: token)
            store.resetAuth()
            dismiss()
        } catch is CancellationError {
            // The sheet closed.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Lists the signed-in accounts with buttons to add and remove them.
struct AccountsSection: View {
    @Environment(Store.self) private var store
    @State private var signingIn = false

    var body: some View {
        Section {
            if store.accounts.isEmpty {
                Text("No accounts. Sign in to see your boards.").foregroundStyle(.secondary)
            }
            ForEach(store.accounts.logins, id: \.self) { login in
                HStack {
                    Label(login, systemImage: "person.crop.circle")
                    Spacer()
                    Button("Sign Out") {
                        store.accounts.remove(login)
                        store.resetAuth()
                    }
                }
            }
            HStack {
                Spacer()
                Button(store.accounts.isEmpty ? "Sign In to GitHub…" : "Add Account…") { signingIn = true }
            }
        } header: {
            Text("GitHub Accounts")
        } footer: {
            Text("Add every account whose boards you want. Sign-ins are kept in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $signingIn) { SignInView() }
    }
}

/// Picks the board shown, from every board the signed-in accounts can see.
struct BoardPicker: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Board", selection: $store.boardRef) {
            if store.boardRef == nil { Text("Choose a board").tag(BoardRef?.none) }
            ForEach(groups, id: \.self) { account in
                Section(account) {
                    ForEach(store.availableBoards.filter { $0.account == account }, id: \.self) { ref in
                        Text("\(ref.title) — \(ref.owner)").tag(BoardRef?.some(ref))
                    }
                }
            }
            // Keep the current board selectable while the list loads.
            if let ref = store.boardRef, !store.availableBoards.contains(ref) {
                Text("\(ref.title) — \(ref.owner)").tag(BoardRef?.some(ref))
            }
        }
    }

    private var groups: [String] {
        store.accounts.logins.filter { login in store.availableBoards.contains { $0.account == login } }
    }
}
