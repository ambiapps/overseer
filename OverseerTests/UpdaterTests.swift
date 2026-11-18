import Foundation
import Testing
@testable import Overseer

struct AppVersionTests {
    @Test func parsesReleaseTags() {
        #expect(AppVersion(tag: "v0.1.0(12)") == AppVersion(components: [0, 1, 0], build: 12))
        #expect(AppVersion(tag: "1.2(3)") == AppVersion(components: [1, 2], build: 3))
        #expect(AppVersion(tag: "1.2.3") == AppVersion(components: [1, 2, 3], build: 0))
        #expect(AppVersion(tag: "v1.x(3)") == nil)
        #expect(AppVersion(tag: "v1.0(x)") == nil)
    }

    @Test func comparesMarketingVersionThenBuild() {
        #expect(AppVersion(tag: "0.1.0(12)")! < AppVersion(tag: "0.1.0(13)")!)
        #expect(AppVersion(tag: "0.1.9(99)")! < AppVersion(tag: "0.2.0(1)")!)
        #expect(AppVersion(tag: "1.0")! == AppVersion(tag: "1.0.0")!)
    }

    @Test func describesWithBuild() {
        #expect(AppVersion(tag: "v0.1.0(12)")!.description == "0.1.0 (12)")
    }
}

struct UpdaterTests {
    @Test func offersOnlyNewerReleases() {
        let installed = AppVersion(tag: "0.1.0(12)")!
        #expect(Updater.isNewer(AppVersion(tag: "0.1.0(13)")!, than: installed))
        #expect(!Updater.isNewer(AppVersion(tag: "0.1.0(12)")!, than: installed))
        #expect(!Updater.isNewer(AppVersion(tag: "0.1.0(11)")!, than: installed))
    }

    @Test func aLocalBuildIsComparedByMarketingVersionOnly() {
        let local = AppVersion(tag: "0.1.0")!
        #expect(!Updater.isNewer(AppVersion(tag: "0.1.0(40)")!, than: local))
        #expect(Updater.isNewer(AppVersion(tag: "0.2.0(41)")!, than: local))
    }

    @Test func theFirstReleaseStillGetsTheNextOne() {
        #expect(Updater.isNewer(AppVersion(tag: "0.1.0(2)")!, than: AppVersion(tag: "0.1.0(1)")!))
    }

    @Test func picksTheDMGFromARelease() throws {
        let json = """
        {"tag_name": "v0.1.0(12)", "html_url": "https://github.com/ambiapps/overseer/releases/tag/v0.1.0(12)",
         "assets": [{"name": "notes.txt", "browser_download_url": "https://github.com/ambiapps/overseer/releases/download/v0.1.0(12)/notes.txt"},
                    {"name": "Overseer-0.1.0-12.dmg", "browser_download_url": "https://github.com/ambiapps/overseer/releases/download/v0.1.0(12)/Overseer-0.1.0-12.dmg"}]}
        """
        let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        #expect(release.version == AppVersion(tag: "0.1.0(12)"))
        #expect(release.dmg?.url.lastPathComponent == "Overseer-0.1.0-12.dmg")
    }

    @Test func rejectsAnAppThatIsNotOverseer() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(in: folder, name: "Other.app", identifier: "com.example.other", version: "0.1.0", build: "12")
        #expect(throws: UpdateError.self) { try Updater.validate(app, expecting: nil) }

        let overseer = try makeApp(in: folder, name: "Overseer.app", identifier: Updater.bundleIdentifier, version: "0.1.0", build: "12")
        try Updater.validate(overseer, expecting: AppVersion(tag: "0.1.0(12)"))
        #expect(throws: UpdateError.self) { try Updater.validate(overseer, expecting: AppVersion(tag: "0.1.0(13)")) }
    }

    @Test func theSwapScriptReplacesTheAppAndCleansUp() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try makeApp(in: folder, name: "Overseer.app", identifier: Updater.bundleIdentifier, version: "0.1.0", build: "0")
        let work = folder.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let staged = try makeApp(in: work, name: "Overseer.app", identifier: Updater.bundleIdentifier, version: "0.2.0", build: "2")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for a pid that has already exited (this test's own child would be racy).
        process.arguments = ["-c", Updater.swapScript, "test", "999999", installed.path, staged.path, "/usr/bin/true"]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(Bundle(url: installed).flatMap { AppVersion.current(bundle: $0) } == AppVersion(tag: "0.2.0(2)"))
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OverseerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(in folder: URL, name: String, identifier: String, version: String, build: String) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
