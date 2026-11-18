import SwiftUI

@main
struct OverseerApp: App {
    #if DEBUG
    @NSApplicationDelegateAdaptor(Snapshot.AppDelegate.self) private var snapshotDelegate
    #endif
    @State private var store = Store()
    @State private var showingNewTicket = false

    var body: some Scene {
        WindowGroup("Overseer") {
            ContentView(showingNewTicket: $showingNewTicket)
                .environment(store)
                .frame(minWidth: 960, minHeight: 560)
                #if DEBUG
                .background { if Snapshot.isRequested { Snapshot.WindowHider() } }
                #endif
                .task {
                    store.start()
                    #if DEBUG
                    Snapshot.runIfRequested(store: store)
                    #endif
                }
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
