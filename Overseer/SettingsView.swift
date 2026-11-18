import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(LinearStore.self) private var linear
    @AppStorage(LinearKey.defaultsKey) private var linearKey = ""

    var body: some View {
        @Bindable var linear = linear
        Form {
            AccountsSection()
            if !store.accounts.isEmpty {
                Section("GitHub Board") {
                    BoardPicker()
                    HStack {
                        Spacer()
                        Button("Reload Boards") { Task { await store.loadAvailableBoards() } }
                    }
                }
            }
            Section("Linear") {
                SecureField("API key", text: $linearKey)
                if !linear.teams.isEmpty {
                    Picker("Team", selection: $linear.teamID) {
                        ForEach(linear.teams) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                Text("Sign in to linear.app (Google SSO works), create a personal API key under Settings → Security & access, and paste it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Apply") { linear.resetAuth() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
