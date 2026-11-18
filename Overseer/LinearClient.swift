import Foundation

// MARK: - Models

nonisolated struct LinearTeam: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let name: String
    let key: String
}

/// A column on a Linear board: one of the team's workflow states.
nonisolated struct LinearState: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let name: String
    /// triage, backlog, unstarted, started, completed or canceled.
    let type: String
    let position: Double
    let color: String

    var isClosed: Bool { type == "completed" || type == "canceled" }

    /// Linear's own order: by type, then the team's position within it.
    static func boardOrder(_ lhs: LinearState, _ rhs: LinearState) -> Bool {
        let order = ["triage", "backlog", "unstarted", "started", "completed", "canceled"]
        let left = order.firstIndex(of: lhs.type) ?? order.count
        let right = order.firstIndex(of: rhs.type) ?? order.count
        return left != right ? left < right : lhs.position < rhs.position
    }
}

nonisolated struct LinearPerson: Hashable, Sendable, Decodable {
    let name: String
    let displayName: String?
    var avatarUrl: URL? = nil
}

nonisolated struct LinearLabel: Hashable, Sendable, Decodable {
    let name: String
    let color: String
}

nonisolated struct LinearIssue: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let identifier: String
    let title: String
    let description: String?
    let url: URL
    /// 0 none, 1 urgent … 4 low. A Float in Linear's schema.
    let priority: Double
    let priorityLabel: String
    let createdAt: Date
    let updatedAt: Date
    var state: Ref
    let assignee: LinearPerson?
    let creator: LinearPerson?
    let labels: Labels

    nonisolated struct Ref: Hashable, Sendable, Decodable { let id: String }
    nonisolated struct Labels: Hashable, Sendable, Decodable { let nodes: [LinearLabel] }
}

nonisolated struct LinearComment: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let body: String
    let createdAt: Date
    let user: LinearPerson?
    let botActor: Bot?

    nonisolated struct Bot: Hashable, Sendable, Decodable { let name: String? }

    var author: String { user?.displayName ?? user?.name ?? botActor?.name ?? "Linear" }
}

nonisolated enum LinearError: LocalizedError {
    case noKey
    case http(Int, String)
    case graphQL(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "No Linear API key. Create one in Linear under Settings → Security & access, and paste it in Overseer's Settings."
        case .http(401, _): "Linear rejected the API key. Check it in Settings."
        case .http(let code, let body): "Linear returned HTTP \(code): \(body.prefix(300))"
        case .graphQL(let message): "Linear: \(message)"
        }
    }
}

/// The Linear API key saved in Settings.
nonisolated enum LinearKey {
    static let defaultsKey = "linearAPIKey"

    static func key() -> String? {
        let key = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }
}

// MARK: - Client

/// Linear's GraphQL API, authenticated with a personal API key.
nonisolated struct LinearClient: Sendable {
    let key: String

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Linear's timestamps carry milliseconds, which `.iso8601` rejects.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }()

    func graphQL<T: Decodable>(_ query: String, variables: [String: Any] = [:], as: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? Self.decoder.decode(Envelope<T>.self, from: data)
        if let errors = envelope?.errors, !errors.isEmpty {
            if errors.contains(where: { $0.extensions?.code == "AUTHENTICATION_ERROR" }) {
                throw LinearError.graphQL("the API key was rejected. Check it in Settings.")
            }
            throw LinearError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard (200..<300).contains(code) else { throw LinearError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let value = envelope?.data else {
            // Decode again to surface the actual decoding error.
            _ = try Self.decoder.decode(Envelope<T>.self, from: data)
            throw LinearError.graphQL("Empty response")
        }
        return value
    }

    func teams() async throws -> [LinearTeam] {
        struct Response: Decodable { let teams: LinearNodes<LinearTeam> }
        let query = "query { teams(first: 100) { nodes { id name key } } }"
        return try await graphQL(query, as: Response.self).teams.nodes.sorted { $0.name < $1.name }
    }

    func states(team: String) async throws -> [LinearState] {
        struct Response: Decodable { let team: Team }
        struct Team: Decodable { let states: LinearNodes<LinearState> }
        let query = """
        query($team: String!) { team(id: $team) { states(first: 100) { nodes { id name type position color } } } }
        """
        return try await graphQL(query, variables: ["team": team], as: Response.self).team.states.nodes
            .sorted(by: LinearState.boardOrder)
    }

    static let issueFields = """
    id identifier title description url priority priorityLabel createdAt updatedAt
    state { id } assignee { name displayName } creator { name displayName avatarUrl } labels { nodes { name color } }
    """

    /// The team's open issues, plus closed ones updated since `closedSince`.
    func issues(team: String, closedSince: Date) async throws -> [LinearIssue] {
        struct Response: Decodable { let team: Team }
        struct Team: Decodable { let issues: LinearPage<LinearIssue> }
        let query = """
        query($team: String!, $after: String, $since: DateTimeOrDuration!) {
          team(id: $team) {
            issues(first: 100, after: $after, filter: {
              or: [{ state: { type: { nin: ["completed", "canceled"] } } }, { updatedAt: { gt: $since } }]
            }) {
              pageInfo { hasNextPage endCursor }
              nodes { \(Self.issueFields) }
            }
          }
        }
        """
        var result: [LinearIssue] = []
        var after: String?
        repeat {
            var variables: [String: Any] = ["team": team, "since": closedSince.ISO8601Format()]
            if let after { variables["after"] = after }
            let page = try await graphQL(query, variables: variables, as: Response.self).team.issues
            result += page.nodes
            after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while after != nil && result.count < 1000
        return result
    }

    func issue(id: String) async throws -> (LinearIssue, [LinearComment]) {
        struct Response: Decodable { let issue: Issue }
        struct Issue: Decodable {
            let comments: LinearNodes<LinearComment>
            let fields: LinearIssue
            init(from decoder: Decoder) throws {
                fields = try LinearIssue(from: decoder)
                comments = try decoder.container(keyedBy: Key.self).decode(LinearNodes<LinearComment>.self, forKey: .comments)
            }
            enum Key: String, CodingKey { case comments }
        }
        let query = """
        query($id: String!) {
          issue(id: $id) {
            \(Self.issueFields)
            comments(first: 100) { nodes { id body createdAt user { name displayName } botActor { name } } }
          }
        }
        """
        let issue = try await graphQL(query, variables: ["id": id], as: Response.self).issue
        return (issue.fields, issue.comments.nodes.sorted { $0.createdAt < $1.createdAt })
    }

    func setState(issue: String, state: String) async throws {
        struct Response: Decodable { let issueUpdate: Success }
        let query = """
        mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }
        """
        guard try await graphQL(query, variables: ["id": issue, "state": state], as: Response.self).issueUpdate.success
        else { throw LinearError.graphQL("Linear didn't move the issue.") }
    }

    func comment(issue: String, body: String) async throws {
        struct Response: Decodable { let commentCreate: Success }
        let query = """
        mutation($issue: String!, $body: String!) { commentCreate(input: { issueId: $issue, body: $body }) { success } }
        """
        guard try await graphQL(query, variables: ["issue": issue, "body": body], as: Response.self).commentCreate.success
        else { throw LinearError.graphQL("Linear didn't save the comment.") }
    }
}

private nonisolated struct Envelope<T: Decodable>: Decodable {
    struct Err: Decodable {
        struct Extensions: Decodable { let code: String? }
        let message: String
        let extensions: Extensions?
    }
    let data: T?
    let errors: [Err]?
}

nonisolated struct LinearNodes<T: Decodable>: Decodable { let nodes: [T] }
nonisolated struct LinearPage<T: Decodable>: Decodable {
    struct Info: Decodable { let hasNextPage: Bool; let endCursor: String? }
    let pageInfo: Info
    let nodes: [T]
}
private nonisolated struct Success: Decodable { let success: Bool }
