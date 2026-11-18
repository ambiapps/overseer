import AppKit
import Foundation
import Observation

/// A release version: the marketing version from `VERSION` plus CI's build number, as in the
/// release tag `v0.1.0(7)` or the bundle's `CFBundleShortVersionString`/`CFBundleVersion`.
nonisolated struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]
    let build: Int

    init(components: [Int], build: Int) {
        self.components = components
        self.build = build
    }

    /// Parses `v0.1.0(7)`, `0.1.0(7)` or `0.1.0` (build 0).
    init?(tag: String) {
        var text = Substring(tag.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        var build = 0
        if let open = text.firstIndex(of: "("), text.last == ")" {
            guard let number = Int(text[text.index(after: open)..<text.index(before: text.endIndex)]) else { return nil }
            build = number
            text = text[..<open]
        }
        self.init(marketing: String(text), build: build)
    }

    init?(marketing: String, build: Int) {
        let parts = marketing.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.init(components: parts.map { $0! }, build: build)
    }

    /// The running app's version.
    static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
        return AppVersion(marketing: marketing, build: build)
    }

    var marketing: String { components.map(String.init).joined(separator: ".") }
    var description: String { build > 0 ? "\(marketing) (\(build))" : marketing }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return lhs.build < rhs.build
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A GitHub release, as returned by `GET /repos/{owner}/{repo}/releases/latest`.
nonisolated struct Release: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        /// The public download link. It redirects to GitHub's storage host.
        let url: URL

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var version: AppVersion? { AppVersion(tag: tagName) }
    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
}

/// Checks GitHub for a newer release, offers it in a window and installs it in place.
///
/// Installing downloads the release DMG, copies the app out of it and hands the swap to a small
/// shell script that waits for Overseer to quit, replaces the bundle and relaunches it. The same
/// mechanism as Orchard's updater. The repository is public, so no token is involved.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case installing
    }

    nonisolated static let repository = "ambiapps/overseer"
    nonisolated static let bundleIdentifier = "se.ambi.overseer"
    nonisolated static let checkInterval: Duration = .seconds(60 * 60)

    private(set) var state: State = .idle
    /// The newer release found by the last check, if any.
    private(set) var available: Release?

    @ObservationIgnored let current: AppVersion?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let skippedKey = "skippedUpdateTag"
    /// The release an install was started for, so the next launch can tell whether it took.
    @ObservationIgnored private let pendingKey = "pendingUpdateTag"
    @ObservationIgnored private var isPrompting = false
    @ObservationIgnored private var started = false
    /// Releases a background check already offered, so the hourly check doesn't bring one back
    /// after "Later".
    @ObservationIgnored private var promptedTags: Set<String> = []

    init(current: AppVersion? = .current(), defaults: UserDefaults? = .standard) {
        self.current = current
        self.defaults = defaults
    }

    /// Checks shortly after launch and then hourly.
    func start() {
        guard current != nil, !started else { return }
        started = true
        #if DEBUG
        // A debug build from Xcode isn't a release; don't offer to replace it.
        guard ProcessInfo.processInfo.environment["OVERSEER_CHECK_UPDATES"] != nil else { return }
        #endif
        reportFailedInstall()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Looks for a newer release. Background checks only speak up about a version the user
    /// hasn't skipped, once per launch; a check from the menu always reports its result.
    func check(userInitiated: Bool) async {
        guard state == .idle else { return }
        state = .checking
        let result: Result<Release, Error>
        do {
            result = .success(try await Self.fetchLatest())
        } catch {
            result = .failure(error)
        }
        state = .idle

        switch result {
        case .failure(let error):
            if userInitiated { showError("Couldn't check for updates", error) }
        case .success(let release):
            guard let version = release.version, Self.isNewer(version, than: current) else {
                available = nil
                if userInitiated { showUpToDate() }
                return
            }
            available = release
            if userInitiated {
                prompt(release)
            } else if release.tagName != defaults?.string(forKey: skippedKey),
                      promptedTags.insert(release.tagName).inserted {
                prompt(release)
            }
        }
    }

    /// Whether `version` should be offered over `current`. A local build has build number 0 (CI
    /// stamps run numbers from 1), so it's compared by marketing version only: the release of the
    /// version you just built isn't offered as an update.
    nonisolated static func isNewer(_ version: AppVersion, than current: AppVersion?) -> Bool {
        guard let current else { return true }
        if current.build == 0 {
            return AppVersion(components: version.components, build: 0)
                > AppVersion(components: current.components, build: 0)
        }
        return version > current
    }

    nonisolated static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Overseer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    nonisolated static func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(for: request(url, accept: "application/vnd.github+json"))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError(http.statusCode == 404
                ? "\(repository) hasn't published a release yet."
                : "GitHub answered with HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Window

    /// Shows the update window for whatever was found last.
    func promptAvailable() {
        if let available { prompt(available) }
    }

    private func prompt(_ release: Release) {
        guard !isPrompting else { return }
        isPrompting = true
        let canInstall = Self.installLocation() != nil && release.dmg != nil
        UpdateWindow.show({ choose in
            UpdateAvailableView(newVersion: release.version?.description ?? release.tagName,
                                currentVersion: self.current?.description, canInstall: canInstall,
                                releaseNotes: release.htmlURL, choose: choose)
        }) { [weak self] choice in
            guard let self else { return }
            isPrompting = false
            switch choice {
            case .install:
                if canInstall {
                    Task { await self.install(release) }
                } else {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            case .skip:
                defaults?.set(release.tagName, forKey: skippedKey)
            case .later:
                break
            }
        }
    }

    /// If the last launch quit to install an update but this is still an older version, the
    /// swap script couldn't replace the app (for example, macOS blocked it). Say so once.
    private func reportFailedInstall() {
        guard let version = takeFailedInstall() else { return }
        showError("Couldn't install the update",
                  UpdateError("Overseer \(version) was downloaded, but the app at \(Bundle.main.bundlePath) couldn't be replaced. Download it from GitHub instead."))
    }

    /// The version the last launch quit to install, if this launch is still older than it.
    func takeFailedInstall() -> AppVersion? {
        guard let tag = defaults?.string(forKey: pendingKey) else { return nil }
        defaults?.removeObject(forKey: pendingKey)
        guard let version = AppVersion(tag: tag), Self.isNewer(version, than: current) else { return nil }
        return version
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Overseer \(current?.description ?? "") is the newest version."
        alert.runModal()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Install

    /// The running .app, when Overseer can replace it: a bundled app whose folder is writable.
    static func installLocation(bundle: Bundle = .main) -> URL? {
        let app = bundle.bundleURL
        guard app.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
        else { return nil }
        return app
    }

    private func install(_ release: Release) async {
        guard state == .idle, let destination = Self.installLocation(), let dmg = release.dmg else { return }
        state = .installing
        do {
            let staged = try await Self.download(dmg.url, expecting: release.version)
            try Self.relaunch(replacing: destination, with: staged)
            defaults?.set(release.tagName, forKey: pendingKey)
            NSApp.terminate(nil)
        } catch {
            state = .idle
            showError("Couldn't install the update", error)
        }
    }

    /// Downloads the DMG and copies the app out of it into a temporary folder, after checking
    /// it's an intact Overseer of the expected version.
    nonisolated static func download(_ url: URL, expecting version: AppVersion?) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverseerUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            return try await stage(into: work, from: url, expecting: version)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private nonisolated static func stage(into work: URL, from url: URL, expecting version: AppVersion?) async throws -> URL {
        let dmg = work.appendingPathComponent("Overseer.dmg")
        let (downloaded, response) = try await URLSession.shared.download(for: request(url, accept: "application/octet-stream"))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed with HTTP \(http.statusCode).")
        }
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        let mount = work.appendingPathComponent("mount")
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                           "-noautoopen", "-mountpoint", mount.path])
        let staged = work.appendingPathComponent("Overseer.app")
        var copyError: Error?
        do {
            try await run("/usr/bin/ditto", [mount.appendingPathComponent("Overseer.app").path, staged.path])
        } catch {
            copyError = error
        }
        // Detach before anything can delete `work`, or the image stays mounted inside it.
        if (try? await run("/usr/bin/hdiutil", ["detach", mount.path])) == nil {
            try await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }
        if let copyError { throw copyError }

        try validate(staged, expecting: version)
        try await run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        return staged
    }

    /// Checks that `app` is Overseer and, when known, the version the release promised.
    nonisolated static func validate(_ app: URL, expecting version: AppVersion?) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier
        else { throw UpdateError("The downloaded app isn't Overseer.") }
        if let version, AppVersion.current(bundle: bundle) != version {
            throw UpdateError("The downloaded app isn't version \(version).")
        }
    }

    /// Runs a tool and throws with its output if it fails.
    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(text)")
            }
        }.value
    }

    /// Starts a helper that waits for this process to exit, swaps `destination` for `staged`
    /// (restoring the old app if the copy fails) and opens the result. It has to outlive Overseer.
    static func relaunch(replacing destination: URL, with staged: URL, opener: String = "/usr/bin/open",
                         waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "overseer-update", String(pid), destination.path, staged.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// `$1` pid to wait for, `$2` installed app, `$3` new app (inside the temporary work folder),
    /// `$4` the command that opens it (tests pass `/usr/bin/true`).
    nonisolated static let swapScript = #"""
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        work="$(dirname "$3")"
        if mv "$2" "$work/Previous.app"; then
            if /usr/bin/ditto "$3" "$2"; then
                rm -rf "$work"
            else
                # Put the old app back. If that fails, keep $work: it holds the only copy.
                rm -rf "$2"
                if [ ! -e "$2" ] && mv "$work/Previous.app" "$2"; then rm -rf "$work"; fi
            fi
        else
            # Couldn't move the app (macOS may block it); the next launch reports it.
            rm -rf "$work"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        "$4" "$2"
        """#
}

nonisolated struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
