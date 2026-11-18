import Foundation

nonisolated enum GitHubError: LocalizedError {
    case notSignedIn
    case noBoard
    case http(Int, String)
    case graphQL(String)
    case signIn(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to GitHub in Settings."
        case .noBoard: "Pick a board in Settings."
        case .http(401, _): "GitHub rejected the sign-in. Sign in to that account again in Settings."
        case .http(let code, let body): "GitHub returned HTTP \(code): \(body.prefix(300))"
        case .graphQL(let message): "GitHub: \(message)"
        case .signIn(let message): message
        case .keychain(let status): "Couldn't save the sign-in to the Keychain (\(status))."
        }
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

    func repos(owner: String) async throws -> [Repo] {
        let query = """
        query($owner: String!, $after: String) {
          repositoryOwner(login: $owner) {
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
            var vars: [String: Any] = ["owner": owner]
            if let after { vars["after"] = after }
            guard let owner = try await graphQL(query, variables: vars, as: ReposResponse.self).repositoryOwner
            else { return result }
            let page = owner.repositories
            result += page.nodes.filter(\.hasIssuesEnabled).map { Repo(id: $0.id, name: $0.name, nameWithOwner: $0.nameWithOwner) }
            after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while after != nil
        return result
    }

    func board(_ ref: BoardRef) async throws -> Board {
        let owner = ref.ownerIsOrganization ? "organization" : "user"
        let query = """
        query($owner: String!, $number: Int!) {
          owner: \(owner)(login: $owner) {
            projectV2(number: $number) {
              id number title url
              field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
            }
          }
        }
        """
        guard let p = try await graphQL(query, variables: ["owner": ref.owner, "number": ref.number], as: BoardResponse.self).owner?.projectV2
        else { throw GitHubError.graphQL("\(ref.account) can't see board #\(ref.number) of \(ref.owner).") }
        guard let field = p.field else { throw GitHubError.graphQL("Board “\(p.title)” has no Status field.") }
        return Board(id: p.id, number: p.number, title: p.title, url: p.url, statusFieldID: field.id,
                     options: field.options.map { Board.Option(id: $0.id, name: $0.name) })
    }

    /// The signed-in user's login.
    func viewerLogin() async throws -> String {
        struct Response: Decodable { struct Viewer: Decodable { let login: String }; let viewer: Viewer }
        return try await graphQL("query { viewer { login } }", as: Response.self).viewer.login
    }

    /// Open boards the account can see: its own and its organizations'.
    func boards(account: String) async throws -> [BoardRef] {
        struct Project: Decodable { let number: Int; let title: String; let closed: Bool }
        struct Projects: Decodable { let nodes: [Project?] }
        struct Org: Decodable { let login: String; let projectsV2: Projects }
        struct Orgs: Decodable { let nodes: [Org?] }
        struct Viewer: Decodable { let login: String; let projectsV2: Projects; let organizations: Orgs }
        struct Response: Decodable { let viewer: Viewer }
        let query = """
        query {
          viewer {
            login
            projectsV2(first: 50) { nodes { number title closed } }
            organizations(first: 50) { nodes { login projectsV2(first: 50) { nodes { number title closed } } } }
          }
        }
        """
        let viewer = try await graphQL(query, as: Response.self).viewer
        func refs(_ projects: Projects, owner: String, isOrg: Bool) -> [BoardRef] {
            projects.nodes.compactMap { $0 }.filter { !$0.closed }.map {
                BoardRef(account: account, owner: owner, ownerIsOrganization: isOrg, number: $0.number, title: $0.title)
            }
        }
        return refs(viewer.projectsV2, owner: viewer.login, isOrg: false)
            + viewer.organizations.nodes.compactMap { $0 }.flatMap { refs($0.projectsV2, owner: $0.login, isOrg: true) }
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

    // MARK: Attachments

    /// GitHub has no API for issue attachments, so files go on an orphan branch in the issue's repo
    /// and the issue links to them there. Only people who can see the repo can see them.
    static let attachmentsBranch = "overseer-attachments"

    /// Commits `attachment` to the attachments branch of `repo` and returns a URL that renders in issues.
    func upload(_ attachment: Attachment, repo: String) async throws -> URL {
        let safe = attachment.filename.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" }
        let path = "\(Date().formatted(.iso8601.year().month()))/\(UUID().uuidString.prefix(8))-\(String(safe))"
        let body: [String: Any] = [
            "message": "Attach \(attachment.filename)",
            "content": attachment.data.base64EncodedString(),
            "branch": Self.attachmentsBranch,
        ]
        do {
            _ = try await rest("PUT", "/repos/\(repo)/contents/\(path)", body: body)
        } catch GitHubError.http(let code, _) where code == 404 || code == 422 {
            // The branch doesn't exist yet.
            try await createAttachmentsBranch(repo: repo)
            _ = try await rest("PUT", "/repos/\(repo)/contents/\(path)", body: body)
        }
        return URL(string: "https://github.com/\(repo)/blob/\(Self.attachmentsBranch)/\(path)?raw=true")!
    }

    /// Starts the attachments branch with no history, so it shares nothing with the code.
    private func createAttachmentsBranch(repo: String) async throws {
        struct SHA: Decodable { let sha: String }
        let readme = "Files attached to issues from Overseer. Issues link here; don't delete this branch.\n"
        let tree = try Self.decoder.decode(SHA.self, from: try await rest("POST", "/repos/\(repo)/git/trees", body: [
            "tree": [["path": "README.md", "mode": "100644", "type": "blob", "content": readme]],
        ]))
        let commit = try Self.decoder.decode(SHA.self, from: try await rest("POST", "/repos/\(repo)/git/commits", body: [
            "message": "Start attachments branch", "tree": tree.sha, "parents": [String](),
        ]))
        do {
            _ = try await rest("POST", "/repos/\(repo)/git/refs", body: ["ref": "refs/heads/\(Self.attachmentsBranch)", "sha": commit.sha])
        } catch GitHubError.http(422, let message) where message.contains("already exists") {
            // Another upload made it first.
        }
    }

    /// Fetches a file for display. Links to the attachments branch go through the API, since github.com
    /// only serves private files to a signed-in browser.
    func download(_ url: URL) async throws -> Data {
        let parts = url.pathComponents
        if url.host() == "github.com", parts.count > 5, parts[3] == "blob" || parts[3] == "raw" {
            let repo = "\(parts[1])/\(parts[2])"
            let path = parts[5...].map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)?ref=\(parts[4])")!)
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            return try await sendRaw(request)
        }
        var request = URLRequest(url: url)
        if url.host() == "github.com" || url.host()?.hasSuffix("githubusercontent.com") == true {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitHubError.http(code, "") }
        return data
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Overseer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitHubError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
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
    let repositoryOwner: Org?
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
    struct Owner: Decodable { let projectV2: Project? }
    struct Project: Decodable {
        struct Field: Decodable { struct Option: Decodable { let id: String; let name: String }; let id: String; let options: [Option] }
        let id: String
        let number: Int
        let title: String
        let url: URL
        let field: Field?
    }
    let owner: Owner?
}

private struct BoardItemsResponse: Decodable {
    struct Node: Decodable { struct Items: Decodable { struct Item: Decodable { let content: IssueNode? }; let pageInfo: PageInfo; let nodes: [Item] }; let items: Items }
    let node: Node
}
