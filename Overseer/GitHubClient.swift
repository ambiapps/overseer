import Foundation

nonisolated enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case graphQL(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            "No GitHub token. Run `gh auth login` in Terminal, or paste a token in Settings."
        case .http(let code, let body):
            "GitHub returned HTTP \(code): \(body.prefix(300))"
        case .graphQL(let message):
            "GitHub: \(message)"
        }
    }
}

/// Finds a GitHub token: a token saved in Settings wins, otherwise the `gh` CLI's token.
nonisolated enum TokenProvider {
    static let defaultsKey = "githubToken"

    static func token() -> String? {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        return ghToken()
    }

    static func ghToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

struct GitHubClient: Sendable {
    let token: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Transport

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Overseer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw GitHubError.http(code, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func graphQL<T: Decodable>(_ query: String, variables: [String: Any] = [:], as: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await send(request)
        let envelope = try Self.decoder.decode(GraphQLEnvelope<T>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw GitHubError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard let value = envelope.data else { throw GitHubError.graphQL("Empty response") }
        return value
    }

    func rest(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(request)
    }

    // MARK: Queries

    func repos(org: String) async throws -> [Repo] {
        let query = """
        query($org: String!, $after: String) {
          organization(login: $org) {
            repositories(first: 100, after: $after, isArchived: false, orderBy: {field: PUSHED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes { id name nameWithOwner hasIssuesEnabled }
            }
          }
        }
        """
        var result: [Repo] = []
        var after: String?
        repeat {
            var vars: [String: Any] = ["org": org]
            if let after { vars["after"] = after }
            let page = try await graphQL(query, variables: vars, as: ReposResponse.self).organization.repositories
            result += page.nodes.filter(\.hasIssuesEnabled).map { Repo(id: $0.id, name: $0.name, nameWithOwner: $0.nameWithOwner) }
            after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while after != nil
        return result
    }

    func board(org: String, number: Int) async throws -> Board {
        let query = """
        query($org: String!, $number: Int!) {
          organization(login: $org) {
            projectV2(number: $number) {
              id number title url
              field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
            }
          }
        }
        """
        let p = try await graphQL(query, variables: ["org": org, "number": number], as: BoardResponse.self).organization.projectV2
        guard let field = p.field else { throw GitHubError.graphQL("Board #\(number) has no Status field") }
        return Board(id: p.id, number: p.number, title: p.title, url: p.url, statusFieldID: field.id,
                     options: field.options.map { Board.Option(id: $0.id, name: $0.name) })
    }

    /// Every issue on the board (open or closed), in board order.
    func boardTickets(boardID: String) async throws -> [Ticket] {
        let query = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on ProjectV2 {
              items(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { content { ... on Issue { \(Self.issueFields) } } }
              }
            }
          }
        }
        """
        var result: [Ticket] = []
        var after: String?
        repeat {
            var vars: [String: Any] = ["id": boardID]
            if let after { vars["after"] = after }
            let page = try await graphQL(query, variables: vars, as: BoardItemsResponse.self).node.items
            result += page.nodes.compactMap { $0.content?.ticket }
            after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while after != nil
        return result
    }

    func searchTickets(_ q: String) async throws -> [Ticket] {
        let query = """
        query($q: String!) {
          search(query: $q, type: ISSUE, first: 100) {
            nodes { ... on Issue { \(Self.issueFields) } }
          }
        }
        """
        let response = try await graphQL(query, variables: ["q": q], as: SearchResponse.self)
        return response.search.nodes.compactMap { $0.ticket }
    }

    func ticket(id: String) async throws -> (Ticket, [Comment]) {
        let query = """
        query($id: ID!) {
          node(id: $id) {
            ... on Issue {
              \(Self.issueFields)
              allComments: comments(last: 100) { nodes { id body createdAt url author { login avatarUrl } } }
            }
          }
        }
        """
        let node = try await graphQL(query, variables: ["id": id], as: NodeResponse.self).node
        guard let ticket = node.ticket else { throw GitHubError.graphQL("Issue not found") }
        let comments = (node.allComments?.nodes ?? []).map {
            Comment(id: $0.id, author: $0.author?.user, body: $0.body, createdAt: $0.createdAt, url: $0.url)
        }
        return (ticket, comments)
    }

    // MARK: Mutations

    func createIssue(repo: String, title: String, body: String) async throws -> (nodeID: String, number: Int) {
        let data = try await rest("POST", "/repos/\(repo)/issues", body: ["title": title, "body": body])
        struct Created: Decodable { let number: Int; let node_id: String }
        let created = try Self.decoder.decode(Created.self, from: data)
        return (created.node_id, created.number)
    }

    func updateIssue(repo: String, number: Int, fields: [String: Any]) async throws {
        _ = try await rest("PATCH", "/repos/\(repo)/issues/\(number)", body: fields)
    }

    /// Adds an issue to the board (a no-op returning the existing item if it's already there).
    func addToBoard(boardID: String, contentID: String) async throws -> String {
        let query = """
        mutation($project: ID!, $content: ID!) {
          addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
        }
        """
        struct R: Decodable { struct A: Decodable { struct I: Decodable { let id: String }; let item: I }; let addProjectV2ItemById: A }
        return try await graphQL(query, variables: ["project": boardID, "content": contentID], as: R.self).addProjectV2ItemById.item.id
    }

    /// Sets an item's Status. Moving to To Do is what the board webhook turns into an agent run.
    func setStatus(board: Board, itemID: String, optionID: String) async throws {
        let query = """
        mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
          updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
                                                value: {singleSelectOptionId: $option}}) { projectV2Item { id } }
        }
        """
        struct R: Decodable { struct U: Decodable { struct I: Decodable { let id: String }; let projectV2Item: I }; let updateProjectV2ItemFieldValue: U }
        _ = try await graphQL(query, variables: ["project": board.id, "item": itemID, "field": board.statusFieldID, "option": optionID], as: R.self)
    }

    func comment(repo: String, number: Int, body: String) async throws {
        _ = try await rest("POST", "/repos/\(repo)/issues/\(number)/comments", body: ["body": body])
    }

    // MARK: GraphQL shapes

    static let issueFields = """
    id number title body url state stateReason createdAt updatedAt
    author { login avatarUrl }
    repository { name nameWithOwner }
    labels(first: 20) { nodes { id name color } }
    assignees(first: 5) { nodes { login avatarUrl } }
    comments { totalCount }
    projectItems(first: 10) {
      nodes { id project { id } fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } }
    }
    closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
      nodes {
        number title url state isDraft
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
    """
}

// MARK: - Decoding

private struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct Err: Decodable { let message: String }
    let data: T?
    let errors: [Err]?
}

private struct ReposResponse: Decodable {
    struct Org: Decodable { let repositories: Page }
    struct Page: Decodable { let pageInfo: PageInfo; let nodes: [Node] }
    struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    struct Node: Decodable {
        let id: String
        let name: String
        let nameWithOwner: String
        let hasIssuesEnabled: Bool
    }
    let organization: Org
}

private struct GQLUser: Decodable {
    let login: String
    let avatarUrl: URL?
    var user: User { User(login: login, avatarURL: avatarUrl) }
}

private struct Nodes<T: Decodable>: Decodable { let nodes: [T] }

private struct IssueNode: Decodable {
    struct RepoRef: Decodable { let name: String; let nameWithOwner: String }
    struct LabelNode: Decodable { let id: String; let name: String; let color: String }
    struct Count: Decodable { let totalCount: Int }
    struct PRNode: Decodable {
        struct CommitNode: Decodable {
            struct Commit: Decodable {
                struct Rollup: Decodable { let state: String }
                let statusCheckRollup: Rollup?
            }
            let commit: Commit
        }
        let number: Int
        let title: String
        let url: URL
        let state: String
        let isDraft: Bool
        let commits: Nodes<CommitNode>
    }
    struct ProjectItemNode: Decodable {
        struct Project: Decodable { let id: String }
        struct Status: Decodable { let name: String? }
        let id: String
        let project: Project
        let fieldValueByName: Status?
    }
    struct CommentNode: Decodable {
        let id: String
        let body: String
        let createdAt: Date
        let url: URL
        let author: GQLUser?
    }

    // All optional: search results include non-Issue nodes that decode as `{}`.
    let id: String?
    let number: Int?
    let title: String?
    let body: String?
    let url: URL?
    let state: String?
    let stateReason: String?
    let createdAt: Date?
    let updatedAt: Date?
    let author: GQLUser?
    let repository: RepoRef?
    let labels: Nodes<LabelNode>?
    let assignees: Nodes<GQLUser>?
    let comments: Count?
    let closedByPullRequestsReferences: Nodes<PRNode>?
    let projectItems: Nodes<ProjectItemNode>?
    let allComments: Nodes<CommentNode>?

    var ticket: Ticket? {
        guard let id, let number, let title, let url, let state, let createdAt, let updatedAt, let repository else { return nil }
        return Ticket(
            id: id, number: number, title: title, body: body ?? "", url: url,
            isOpen: state == "OPEN", stateReason: stateReason,
            createdAt: createdAt, updatedAt: updatedAt,
            author: author?.user,
            repoName: repository.name, repoNameWithOwner: repository.nameWithOwner,
            labels: (labels?.nodes ?? []).map { IssueLabel(id: $0.id, name: $0.name, color: $0.color) },
            assignees: (assignees?.nodes ?? []).map(\.user),
            commentCount: comments?.totalCount ?? 0,
            pullRequests: (closedByPullRequestsReferences?.nodes ?? []).map {
                LinkedPR(number: $0.number, title: $0.title, url: $0.url,
                         state: LinkedPR.State(rawValue: $0.state) ?? .open, isDraft: $0.isDraft,
                         checks: $0.commits.nodes.last?.commit.statusCheckRollup.flatMap { LinkedPR.Checks(rawValue: $0.state) })
            },
            boardItems: (projectItems?.nodes ?? []).map {
                BoardItem(id: $0.id, projectID: $0.project.id, status: $0.fieldValueByName?.name)
            }
        )
    }
}

private struct SearchResponse: Decodable {
    struct Search: Decodable { let nodes: [IssueNode] }
    let search: Search
}

private struct NodeResponse: Decodable { let node: IssueNode }

private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }

private struct BoardResponse: Decodable {
    struct Org: Decodable { let projectV2: Project }
    struct Project: Decodable {
        struct Field: Decodable { struct Option: Decodable { let id: String; let name: String }; let id: String; let options: [Option] }
        let id: String
        let number: Int
        let title: String
        let url: URL
        let field: Field?
    }
    let organization: Org
}

private struct BoardItemsResponse: Decodable {
    struct Node: Decodable { struct Items: Decodable { struct Item: Decodable { let content: IssueNode? }; let pageInfo: PageInfo; let nodes: [Item] }; let items: Items }
    let node: Node
}
