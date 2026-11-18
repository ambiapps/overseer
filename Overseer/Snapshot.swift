#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: writes the app to PNGs, for PR screenshots where screen recording isn't available.
///
/// - `OVERSEER_SNAPSHOT=/path/board.png` writes the main window, then quits.
/// - With `OVERSEER_SNAPSHOT_UPDATE=/path/update.png` too, it writes the update window instead.
/// - With `OVERSEER_SNAPSHOT_SIGNIN=/path/signin.png` too, it writes the sign-in sheet with a made-up code.
/// - `OVERSEER_APPEARANCE=dark|light` picks the appearance.
/// - `OVERSEER_LINEAR_DEMO=1` shows the Linear board filled with made-up issues instead, and
///   `OVERSEER_SELECT=1` with it writes the first started issue's detail view.
/// - `OVERSEER_SELECT=<column>` also writes the first ticket of that column's detail view to
///   `/path/board-ticket.png`. The inspector pane can't be captured from inside the process, so
///   the same view is rendered in a window of the inspector's width.
enum Snapshot {
    static let isRequested = ProcessInfo.processInfo.environment["OVERSEER_SNAPSHOT"] != nil

    /// Keeps a snapshot run from flashing windows or stealing focus: no Dock icon or activation,
    /// and every window fully transparent and click-through. `cacheDisplay` still renders them.
    static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.hasShadow = false
        window.ignoresMouseEvents = true
    }

    static func run(store: Store, linear: LinearStore, source: Binding<BoardSource>) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OVERSEER_SNAPSHOT"] else { return }
        if let appearance = env["OVERSEER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let signInPath = env["OVERSEER_SNAPSHOT_SIGNIN"] {
            Task { @MainActor in
                let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                hide(window)
                window.contentViewController = NSHostingController(rootView: SignInView(
                    phase: .waiting(code: "4F2A-9C1E", url: URL(string: "https://github.com/login/device")!), isPreview: true)
                    .environment(store)
                    .background(Color(nsColor: .windowBackgroundColor)))
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(1))
                write(window.contentView!, to: signInPath)
                NSApp.terminate(nil)
            }
            return
        }
        if let updatePath = env["OVERSEER_SNAPSHOT_UPDATE"] {
            Task { @MainActor in
                let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                hide(window)
                window.contentViewController = NSHostingController(rootView: UpdateAvailableView(
                    newVersion: "0.1.0 (12)", currentVersion: "0.1.0 (11)", canInstall: true,
                    releaseNotes: URL(string: "https://github.com/ambiapps/overseer/releases")!, choose: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor)))
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(1))
                write(window.contentView!, to: updatePath)
                NSApp.terminate(nil)
            }
            return
        }
        if env["OVERSEER_LINEAR_DEMO"] != nil {
            source.wrappedValue = .linear
            linear.fillWithDemo()
            Task { @MainActor in
                guard let window = await mainWindow() else { return }
                write(window.contentView?.superview ?? window.contentView!, to: path)
                if env["OVERSEER_SELECT"] != nil,
                   let started = linear.states.first(where: { $0.type == "started" }),
                   let issue = linear.issues(in: started).first {
                    linear.selection = issue.id
                    // Let the selection change (which clears the detail) settle first.
                    try? await Task.sleep(for: .milliseconds(300))
                    linear.detail = issue
                    linear.detailComments = LinearStore.demoComments
                    await writeDetail(LinearIssueDetailView(issue: issue).environment(linear), to: path)
                }
                NSApp.terminate(nil)
            }
            return
        }
        source.wrappedValue = .github
        store.start()
        Task { @MainActor in
            while store.lastRefresh == nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                NSApp.terminate(nil)
                return
            }
            window.setContentSize(NSSize(width: 1500, height: 860))
            try? await Task.sleep(for: .seconds(1.5))
            write(window.contentView?.superview ?? window.contentView!, to: path)

            if let name = env["OVERSEER_SELECT"], let column = BoardColumn(rawValue: name),
               let id = store.tickets(in: column).first?.id {
                store.selection = id
                while store.detail == nil { try? await Task.sleep(for: .milliseconds(200)) }
                let detail = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 860),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                hide(detail)
                detail.contentView = NSHostingView(rootView: TicketDetailView(ticket: store.selectedTicket!)
                    .environment(store)
                    .background(.background))
                detail.orderBack(nil)
                try? await Task.sleep(for: .seconds(1.5))
                write(detail.contentView!, to: path.replacingOccurrences(of: ".png", with: "-ticket.png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func mainWindow() async -> NSWindow? {
        try? await Task.sleep(for: .milliseconds(500))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            NSApp.terminate(nil)
            return nil
        }
        window.setContentSize(NSSize(width: 1500, height: 860))
        try? await Task.sleep(for: .seconds(1.5))
        return window
    }

    private static func writeDetail(_ view: some View, to path: String) async {
        let detail = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 860),
                              styleMask: [.titled], backing: .buffered, defer: false)
        hide(detail)
        detail.contentView = NSHostingView(rootView: view.background(.background))
        detail.orderBack(nil)
        try? await Task.sleep(for: .seconds(1.5))
        write(detail.contentView!, to: path.replacingOccurrences(of: ".png", with: "-ticket.png"))
    }

    /// Hides the hosting window as soon as SwiftUI puts the view in it, before it's first drawn.
    struct WindowHider: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { HiderView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class HiderView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { Snapshot.hide(window) }
            }
        }
    }

    final class AppDelegate: NSObject, NSApplicationDelegate {
        func applicationWillFinishLaunching(_ notification: Notification) {
            guard Snapshot.isRequested else { return }
            NSApp.setActivationPolicy(.accessory)
            // Don't restore the installed Overseer's windows (same bundle ID); a snapshot needs a
            // fresh main window. The argument domain is per process, so nothing is saved.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["ApplePersistenceIgnoreState"] = true
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }

    private static func write(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
