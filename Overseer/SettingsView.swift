import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage("org") private var org = "ambiapps"
    @AppStorage("boardNumber") private var boardNumber = 8
    @AppStorage(TokenProvider.defaultsKey) private var token = ""

    var body: some View {
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
            HStack {
                Spacer()
                Button("Apply") { store.resetAuth() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
