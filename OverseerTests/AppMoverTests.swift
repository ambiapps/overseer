import Foundation
import Testing
@testable import Overseer

struct AppMoverTests {
    @Test func recognizesApplicationsFolders() {
        #expect(AppMover.isInApplications(URL(fileURLWithPath: "/Applications/Overseer.app")))
        #expect(AppMover.isInApplications(URL(fileURLWithPath: "/Applications/Tools/Overseer.app")))
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(AppMover.isInApplications(home.appendingPathComponent("Applications/Overseer.app")))
        #expect(!AppMover.isInApplications(home.appendingPathComponent("Downloads/Overseer.app")))
        #expect(!AppMover.isInApplications(URL(fileURLWithPath: "/Volumes/Overseer/Overseer.app")))
        #expect(!AppMover.isInApplications(URL(fileURLWithPath: "/ApplicationsOld/Overseer.app")))
    }

    @Test func recognizesTranslocation() {
        #expect(AppMover.isTranslocated(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Overseer.app")))
        #expect(!AppMover.isTranslocated(URL(fileURLWithPath: "/Users/me/Downloads/Overseer.app")))
    }
}
