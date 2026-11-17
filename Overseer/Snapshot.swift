#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: writes the app to PNGs, for PR screenshots where screen recording isn't available.
///
/// - `OVERSEER_SNAPSHOT=/path/board.png` writes the main window, then quits.
/// - `OVERSEER_APPEARANCE=dark|light` picks the appearance.
/// - `OVERSEER_SELECT=<column>` also writes the first ticket of that column's detail view to
///   `/path/board-ticket.png`. The inspector pane can't be captured from inside the process, so
///   the same view is rendered in a window of the inspector's width.
enum Snapshot {
    static func runIfRequested(store: Store) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OVERSEER_SNAPSHOT"] else { return }
        if let appearance = env["OVERSEER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
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

    private static func write(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
