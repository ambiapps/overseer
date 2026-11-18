import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(LinearStore.self) private var linear
    @AppStorage("org") private var org = "ambiapps"
    @AppStorage("boardNumber") private var boardNumber = 8
    @AppStorage(TokenProvider.defaultsKey) private var token = ""
    @AppStorage(LinearKey.defaultsKey) private var linearKey = ""

    var body: some View {
        @Bindable var linear = linear
        Form {
            Section("GitHub") {
                TextField("Organization", text: $org)
                TextField("Board number", value: $boardNumber, format: .number)
                SecureField("Token (optional)", text: $token)
                Text(token.isEmpty
                     ? "Using the token from the gh CLI (`gh auth login`)."
                     : "Using the token above instead of the gh CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }
            HStack {
                Spacer()
                Button("Apply") {
                    store.resetAuth()
                    linear.resetAuth()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
