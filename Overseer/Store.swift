import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable, Identifiable {
    case todo
    case inProgress
    case review
    case backlog
    case done
    case allOpen
    case repo(String) // nameWithOwner

    var id: String {
        switch self {
        case .todo: "todo"
        case .inProgress: "progress"
        case .review: "review"
        case .backlog: "backlog"
        case .done: "done"
        case .allOpen: "open"
        case .repo(let name): "repo:\(name)"
        }
    }

    var title: String {
        switch self {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .review: "In Review"
        case .backlog: "Backlog"
        case .done: "Done"
        case .allOpen: "All Open Issues"
        case .repo(let name): name.components(separatedBy: "/").last ?? name
        }
    }

    /// Board views come from the board; the rest are GitHub searches.
    var boardStatuses: Set<TicketStatus>? {
        switch self {
        case .todo: [.todo]
        case .inProgress: [.inProgress]
        case .review: [.review]
        case .backlog: [.backlog]
        case .done: [.done, .closed]
        case .allOpen, .repo: nil
        }
    }
}

@MainActor
@Observable
final class Store {
    static let todoStatus = "To Do"
    static let backlogStatus = "Backlog"

    var repos: [Repo] = []
    var board: Board?
    var boardTickets: [Ticket] = []
    var searchTickets: [Ticket] = []
    var sidebar: SidebarItem? = .todo
    var selection: Ticket.ID?
    var searchText = ""
    var isLoading = false
    var error: String?
    var notice: String?
    var lastRefresh: Date?

    var detail: Ticket?
    var detailComments: [Comment] = []

    private var client: GitHubClient?
    private var pollTask: Task<Void, Never>?

    private var org: String { UserDefaults.standard.string(forKey: "org") ?? "ambiapps" }
    private var boardNumber: Int {
        let n = UserDefaults.standard.integer(forKey: "boardNumber")
        return n > 0 ? n : 8
    }

    // MARK: Derived

    func status(of ticket: Ticket) -> TicketStatus {
        TicketStatus.derive(ticket, board: board)
    }

    func repo(named nameWithOwner: String) -> Repo? {
        repos.first { $0.nameWithOwner == nameWithOwner }
    }

    func count(_ item: SidebarItem) -> Int? {
        guard let statuses = item.boardStatuses, item != .done else { return nil }
        return boardTickets.filter { statuses.contains(status(of: $0)) }.count
    }

    /// Tickets for the current sidebar item, filtered by the search text.
    var visibleTickets: [Ticket] {
        let item = sidebar ?? .todo
        guard let statuses = item.boardStatuses else { return searchTickets }
        let text = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return boardTickets.filter { ticket in
            statuses.contains(status(of: ticket)) &&
                (text.isEmpty || ticket.title.lowercased().contains(text) || ticket.key.lowercased().contains(text))
        }
    }

    var groupedTickets: [(TicketStatus, [Ticket])] {
        let groups = Dictionary(grouping: visibleTickets, by: status(of:))
        return TicketStatus.allCases.compactMap { status in
            guard let items = groups[status], !items.isEmpty else { return nil }
            return (status, items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    var selectedTicket: Ticket? {
        guard let selection else { return nil }
        if let detail, detail.id == selection { return detail }
        return (boardTickets + searchTickets).first { $0.id == selection }
    }

    // MARK: Loading

    private func authorizedClient() throws -> GitHubClient {
        if let client { return client }
        guard let token = TokenProvider.token() else { throw GitHubError.noToken }
        let c = GitHubClient(token: token)
        client = c
        return c
    }

    func resetAuth() {
        client = nil
        repos = []
        board = nil
        Task { await refresh() }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try authorizedClient()
            if board == nil { board = try await client.board(org: org, number: boardNumber) }
            if repos.isEmpty { repos = try await client.repos(org: org) }
            if let board { boardTickets = try await client.boardTickets(boardID: board.id) }
            if let query = searchQuery() {
                searchTickets = try await client.searchTickets(query)
            }
            error = nil
            lastRefresh = .now
            if let selection, detail?.id == selection { await loadDetail(id: selection) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func searchQuery() -> String? {
        var parts: [String]
        switch sidebar ?? .todo {
        case .allOpen: parts = ["org:\(org)", "is:issue", "is:open", "sort:updated-desc"]
        case .repo(let name): parts = ["repo:\(name)", "is:issue", "is:open", "sort:updated-desc"]
        default: return nil
        }
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " ")
    }

    func loadDetail(id: Ticket.ID) async {
        do {
            let (ticket, comments) = try await authorizedClient().ticket(id: id)
            guard selection == id else { return }
            detail = ticket
            detailComments = comments
            if let i = boardTickets.firstIndex(where: { $0.id == id }) { boardTickets[i] = ticket }
            if let i = searchTickets.firstIndex(where: { $0.id == id }) { searchTickets[i] = ticket }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Actions

    /// Files an issue, puts it on the board and sets its Status. Filing into To Do is what hands it to the agents.
    @discardableResult
    func createTicket(repo: Repo, title: String, body: String, status: String) async -> Bool {
        do {
            let client = try authorizedClient()
            guard let board else { throw GitHubError.graphQL("The board hasn't loaded yet") }
            let created = try await client.createIssue(repo: repo.nameWithOwner, title: title, body: body)
            let itemID = try await client.addToBoard(boardID: board.id, contentID: created.nodeID)
            if let option = board.option(named: status) {
                try await client.setStatus(board: board, itemID: itemID, optionID: option.id)
            }
            sidebar = status == Self.todoStatus ? .todo : .backlog
            await refresh()
            selection = created.nodeID
            notice = "Filed \(repo.name)#\(created.number) in \(status)."
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Moves a ticket to a board Status, adding it to the board first if needed.
    func move(_ ticket: Ticket, to statusName: String) async {
        await mutate(ticket) { client, board in
            let itemID = if let item = ticket.boardItem(on: board) {
                item.id
            } else {
                try await client.addToBoard(boardID: board.id, contentID: ticket.id)
            }
            guard let option = board.option(named: statusName) else {
                throw GitHubError.graphQL("The board has no “\(statusName)” status")
            }
            try await client.setStatus(board: board, itemID: itemID, optionID: option.id)
        }
    }

    /// The agents start on a Status change into To Do, so a ticket already there goes out and back.
    func restart(_ ticket: Ticket) async {
        await move(ticket, to: Self.backlogStatus)
        await move(ticket, to: Self.todoStatus)
    }

    func setOpen(_ ticket: Ticket, open: Bool) async {
        await mutate(ticket) { client, _ in
            var fields: [String: Any] = ["state": open ? "open" : "closed"]
            if !open { fields["state_reason"] = "not_planned" }
            try await client.updateIssue(repo: ticket.repoNameWithOwner, number: ticket.number, fields: fields)
        }
    }

    func edit(_ ticket: Ticket, title: String, body: String) async {
        await mutate(ticket) { client, _ in
            try await client.updateIssue(repo: ticket.repoNameWithOwner, number: ticket.number, fields: ["title": title, "body": body])
        }
    }

    func comment(on ticket: Ticket, body: String) async {
        await mutate(ticket) { client, _ in
            try await client.comment(repo: ticket.repoNameWithOwner, number: ticket.number, body: body)
        }
    }

    private func mutate(_ ticket: Ticket, _ work: @escaping (GitHubClient, Board) async throws -> Void) async {
        do {
            guard let board else { throw GitHubError.graphQL("The board hasn't loaded yet") }
            try await work(try authorizedClient(), board)
            await refresh()
            if selection == ticket.id { await loadDetail(id: ticket.id) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
