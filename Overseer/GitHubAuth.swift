import Foundation
import Observation
import Security

/// The GitHub OAuth App that identifies Overseer. Device-flow sign-in needs only its public
/// client ID; there is no client secret in the app.
nonisolated enum GitHubOAuth {
    static let clientID = "Ov23liAB2jHcMhINKCwX"
    /// Issues in private repositories, organization membership, and project boards.
    static let scopes = "repo read:org project"
}

/// A board picked in Settings: which signed-in account reads it, and where it lives.
nonisolated struct BoardRef: Codable, Hashable, Sendable {
    let account: String
    let owner: String
    let ownerIsOrganization: Bool
    let number: Int
    let title: String

    static let defaultsKey = "githubBoard"

    static var saved: BoardRef? {
        get {
            UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(BoardRef.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: defaultsKey)
        }
    }
}

// MARK: - Keychain

/// GitHub tokens, one per signed-in account, in the login keychain.
nonisolated enum TokenStore {
    static let service = "se.ambi.overseer.github"

    static func save(_ token: String, for login: String) throws {
        delete(login)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: login,
            kSecAttrLabel as String: "Overseer GitHub token (\(login))",
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubError.keychain(status) }
    }

    static func token(for login: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: login,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ login: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: login,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Accounts

/// The GitHub accounts signed in to Overseer. Logins are kept in defaults, tokens in the Keychain.
@MainActor
@Observable
final class Accounts {
    static let defaultsKey = "githubAccounts"

    private(set) var logins: [String]

    init() {
        logins = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        // Older builds kept a pasted token here in plain text.
        UserDefaults.standard.removeObject(forKey: "githubToken")
    }

    var isEmpty: Bool { logins.isEmpty }

    func add(_ login: String, token: String) throws {
        try TokenStore.save(token, for: login)
        if !logins.contains(login) { logins.append(login) }
        persist()
    }

    func remove(_ login: String) {
        TokenStore.delete(login)
        logins.removeAll { $0 == login }
        persist()
        if BoardRef.saved?.account == login { BoardRef.saved = nil }
    }

    func client(for login: String) -> GitHubClient? {
        TokenStore.token(for: login).map { GitHubClient(token: $0) }
    }

    private func persist() {
        UserDefaults.standard.set(logins, forKey: Self.defaultsKey)
    }
}

// MARK: - Device flow

/// GitHub's device flow: show a code, the user enters it at github.com/login/device, and the app
/// polls until GitHub hands over a token.
nonisolated enum DeviceFlow {
    struct Code: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    static func start() async throws -> Code {
        let data = try await post("https://github.com/login/device/code",
                                  ["client_id": GitHubOAuth.clientID, "scope": GitHubOAuth.scopes])
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            throw GitHubError.signIn(failure.message)
        }
        return try JSONDecoder().decode(Code.self, from: data)
    }

    /// Polls until the user approves, declines or the code expires. Returns the access token.
    static func token(for code: Code) async throws -> String {
        var interval = max(code.interval, 5)
        let deadline = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            let data = try await post("https://github.com/login/oauth/access_token", [
                "client_id": GitHubOAuth.clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            if let token = reply.accessToken { return token }
            switch reply.error {
            case "authorization_pending": continue
            case "slow_down": interval = reply.interval ?? interval + 5
            case "access_denied": throw GitHubError.signIn("Sign-in was declined on GitHub.")
            case "expired_token": throw GitHubError.signIn("The code expired. Try again.")
            default: throw GitHubError.signIn(reply.errorDescription ?? reply.error ?? "GitHub didn't sign you in.")
            }
        }
        throw GitHubError.signIn("The code expired. Try again.")
    }

    struct Reply: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    private struct Failure: Decodable {
        let error: String
        let errorDescription: String?
        var message: String {
            error == "device_flow_disabled" ? "Device sign-in isn't enabled for Overseer's GitHub app." : (errorDescription ?? error)
        }
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private static func post(_ url: String, _ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitHubError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }
}
