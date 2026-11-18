import AppKit
import Foundation

/// Offers, at launch, to move Overseer into the Applications folder when it's run from somewhere
/// else (the DMG, Downloads). Updates install in place, so the app should live somewhere stable.
///
/// Moving copies the bundle into `/Applications` (or `~/Applications` when that isn't writable),
/// trashes the original when it can, and relaunches from the new copy.
enum AppMover {
    private static let suppressKey = "suppressMoveToApplications"

    /// Asks once per launch, unless the user ticked "Don't ask again".
    static func offerIfNeeded(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        #if DEBUG
        // Builds from Xcode run from DerivedData; only ask when explicitly testing this.
        guard ProcessInfo.processInfo.environment["OVERSEER_OFFER_MOVE"] != nil else { return }
        #endif
        let app = bundle.bundleURL
        guard app.pathExtension == "app", !defaults.bool(forKey: suppressKey),
              !isInApplications(app) else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "Overseer can move itself to your Applications folder, where it can update itself and stays out of Downloads."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(true, forKey: suppressKey) }
        guard response == .alertFirstButtonReturn else { return }

        do {
            let destination = try move(app)
            try relaunch(destination)
            NSApp.terminate(nil)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move Overseer"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.runModal()
        }
    }

    /// Whether `app` is already inside an Applications folder (directly or in a subfolder).
    static func isInApplications(_ app: URL) -> Bool {
        let path = app.resolvingSymlinksInPath().path
        let roots = FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask)
            .map { $0.resolvingSymlinksInPath().path }
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// The folder to move into: `/Applications` if writable, otherwise `~/Applications`.
    static func applicationsFolder() throws -> URL {
        let system = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    /// Copies `app` into the Applications folder, replacing (trashing) any older copy there, and
    /// trashes the original when it's on a writable volume (not the DMG). Returns the new location.
    static func move(_ app: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = try applicationsFolder().appendingPathComponent(app.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: app, to: destination)
        // The copy keeps the download's quarantine flag; Gatekeeper already approved this app.
        try? Process.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                         arguments: ["-dr", "com.apple.quarantine", destination.path]).waitUntilExit()
        if !isTranslocated(app), fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            try? fileManager.trashItem(at: app, resultingItemURL: nil)
        }
        return destination
    }

    /// A quarantined app opened from Downloads runs from a read-only randomized path.
    static func isTranslocated(_ app: URL) -> Bool {
        app.path.contains("/AppTranslocation/")
    }

    /// Opens `app` once this process has exited, so the new copy isn't refused as already running.
    static func relaunch(_ app: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; /usr/bin/open "$2""#,
                             "overseer-move", String(pid), app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
