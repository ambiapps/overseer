import Foundation
import Testing
@testable import Overseer

struct GitHubAuthTests {
    @Test func readsDeviceFlowReplies() throws {
        let pending = try JSONDecoder().decode(DeviceFlow.Reply.self, from: Data(#"{"error":"authorization_pending"}"#.utf8))
        #expect(pending.accessToken == nil && pending.error == "authorization_pending")
        let slow = try JSONDecoder().decode(DeviceFlow.Reply.self, from: Data(#"{"error":"slow_down","interval":10}"#.utf8))
        #expect(slow.interval == 10)
        let done = try JSONDecoder().decode(DeviceFlow.Reply.self,
                                            from: Data(#"{"access_token":"gho_x","token_type":"bearer","scope":"repo"}"#.utf8))
        #expect(done.accessToken == "gho_x")
        let code = try JSONDecoder().decode(DeviceFlow.Code.self, from: Data("""
        {"device_code":"d","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}
        """.utf8))
        #expect(code.userCode == "ABCD-1234" && code.interval == 5)
    }

    @Test func keepsTokensInTheKeychain() throws {
        let login = "overseer-test-\(UUID().uuidString)"
        defer { TokenStore.delete(login) }
        try TokenStore.save("first", for: login)
        try TokenStore.save("second", for: login)
        #expect(TokenStore.token(for: login) == "second")
        TokenStore.delete(login)
        #expect(TokenStore.token(for: login) == nil)
    }

    @Test func opensTheOldBoardOrTheOnlyOne() throws {
        let defaults = try #require(UserDefaults(suiteName: "OverseerTests-\(UUID().uuidString)"))
        let code = BoardRef(account: "me", owner: "ambiapps", ownerIsOrganization: true, number: 8, title: "Code board")
        let other = BoardRef(account: "me", owner: "ambiapps", ownerIsOrganization: true, number: 3, title: "Roadmap")
        #expect(Store.preferredBoard(in: [code], defaults: defaults) == code)
        #expect(Store.preferredBoard(in: [code, other], defaults: defaults) == nil)
        defaults.set("ambiapps", forKey: "org")
        defaults.set(8, forKey: "boardNumber")
        #expect(Store.preferredBoard(in: [other, code], defaults: defaults) == code)
    }
}
