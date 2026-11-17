import SwiftUI

@main
struct OverseerApp: App {
    @State private var store = Store()
    @State private var showingNewTicket = false

    var body: some Scene {
        WindowGroup("Overseer") {
            ContentView(showingNewTicket: $showingNewTicket)
                .environment(store)
                .frame(minWidth: 960, minHeight: 560)
                .task { store.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Ticket…") { showingNewTicket = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
