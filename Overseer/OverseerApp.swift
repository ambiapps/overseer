import SwiftUI

@main
struct OverseerApp: App {
    #if DEBUG
    @NSApplicationDelegateAdaptor(Snapshot.AppDelegate.self) private var snapshotDelegate
    #endif
    @State private var store = Store()
    @State private var linear = LinearStore()
    @AppStorage("boardSource") private var source = BoardSource.github
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
            Group {
                switch source {
                case .github: ContentView(showingNewTicket: $showingNewTicket, source: $source)
                case .linear: LinearContentView(source: $source)
                }
            }
            .environment(store)
            .environment(linear)
            .frame(minWidth: 960, minHeight: 560)
            #if DEBUG
            .background { if Snapshot.isRequested { Snapshot.WindowHider() } }
            #endif
            .task {
                guard !Self.isTesting else { return }
                #if DEBUG
                if Snapshot.isRequested {
                    Snapshot.run(store: store, linear: linear, source: $source)
                    return
                }
                #endif
                store.start()
                linear.start()
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
                    .disabled(source != .github)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task {
                        switch source {
                        case .github: await store.refresh()
                        case .linear: await linear.refresh()
                        }
                    }
                }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(linear)
        }
    }
}
