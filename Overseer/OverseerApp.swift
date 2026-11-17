import SwiftUI

@main
struct OverseerApp: App {
    @State private var store = Store()
    @State private var showingNewTicket = false
    @State private var updater: Updater

    /// Unit tests load into the app; it stays idle then, without GitHub or update checks.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let updater = Updater()
        if !Self.isTesting { updater.start() }
        _updater = State(initialValue: updater)
    }

    var body: some Scene {
        WindowGroup("Overseer") {
            ContentView(showingNewTicket: $showingNewTicket)
                .environment(store)
                .frame(minWidth: 960, minHeight: 560)
                .task {
                    guard !Self.isTesting else { return }
                    store.start()
                    #if DEBUG
                    Snapshot.runIfRequested(store: store)
                    #endif
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state != .idle)
            }
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
