import Foundation
import Observation
import SwiftUI

/// A column on the board, by what the agents are doing with a ticket. Done and closed tickets aren't shown.
enum BoardColumn: String, CaseIterable, Identifiable {
    case hold, todo, inProgress, needsClarification

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold"
        case .todo: "Todo"
        case .inProgress: "In Progress"
        case .needsClarification: "Needs Clarification"
        }
    }

    var statuses: Set<TicketStatus> {
        switch self {
        case .hold: [.backlog, .unfiled]
        case .todo: [.todo]
        case .inProgress: [.inProgress, .review]
        case .needsClarification: [.needsClarification]
        }
    }

    /// Representative status for the column's symbol and tint.
    var status: TicketStatus {
        switch self {
        case .hold: .backlog
        case .todo: .todo
        case .inProgress: .inProgress
        case .needsClarification: .needsClarification
        }
    }

    /// The board Status a card dropped here gets. In Progress and Needs Clarification are the agents' to set.
    var dropStatus: String? {
        switch self {
        case .hold: Store.backlogStatus
        case .todo: Store.todoStatus
        case .inProgress, .needsClarification: nil
        }
    }

    var hint: String {
        switch self {
        case .hold: "Not for the agents yet."
        case .todo: "Dropping a ticket here hands it to the agents."
        case .inProgress: "The agents are building or reviewing it."
        case .needsClarification: "The agent is blocked. Answer its question on the issue, then move it back to Todo."
        }
    }
}

@MainActor
@Observable
final class Store {
    static let todoStatus = "To Do"
    static let backlogStatus = "Backlog"
    static let needsClarificationStatus = "Needs Clarification"

    var repos: [Repo] = []
    var board: Board?
    var boardTickets: [Ticket] = []
    var repoFilter: String? // nameWithOwner
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

    /// Repositories that have tickets on the board, for the filter menu.
    var boardRepos: [String] {
        Set(boardTickets.map(\.repoNameWithOwner)).sorted()
    }

    private var filteredTickets: [Ticket] {
        let text = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return boardTickets.filter { ticket in
            (repoFilter == nil || ticket.repoNameWithOwner == repoFilter) &&
                (text.isEmpty || ticket.title.lowercased().contains(text) || ticket.key.lowercased().contains(text))
        }
    }

    func tickets(in column: BoardColumn) -> [Ticket] {
        filteredTickets
            .filter { column.statuses.contains(status(of: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var selectedTicket: Ticket? {
        guard let selection else { return nil }
        if let detail, detail.id == selection { return detail }
        return boardTickets.first { $0.id == selection }
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
            error = nil
            lastRefresh = .now
            if let selection, detail?.id == selection { await loadDetail(id: selection) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadDetail(id: Ticket.ID) async {
        do {
            let (ticket, comments) = try await authorizedClient().ticket(id: id)
            guard selection == id else { return }
            detail = ticket
            detailComments = comments
            if let i = boardTickets.firstIndex(where: { $0.id == id }) { boardTickets[i] = ticket }
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
        guard ticket.boardItem(on: board)?.status != statusName else { return }
        setLocalStatus(ticket, statusName)
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
        if statusName == Self.todoStatus { notice = "Moved \(ticket.key) to To Do. The agents start on it now." }
    }

    /// Handles a card dropped on a column.
    func drop(ticketID: Ticket.ID, on column: BoardColumn) async {
        guard let statusName = column.dropStatus,
              let ticket = boardTickets.first(where: { $0.id == ticketID }) else { return }
        await move(ticket, to: statusName)
    }

    /// The agents start on a Status change into To Do, so a ticket already there goes out and back.
    func restart(_ ticket: Ticket) async {
        await move(ticket, to: Self.backlogStatus)
        if let moved = boardTickets.first(where: { $0.id == ticket.id }) {
            await move(moved, to: Self.todoStatus)
        }
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

    /// Shows a move on the board at once; the refresh after the write confirms or reverts it.
    private func setLocalStatus(_ ticket: Ticket, _ statusName: String) {
        guard let board, let i = boardTickets.firstIndex(where: { $0.id == ticket.id }) else { return }
        let old = boardTickets[i]
        var items = old.boardItems.filter { $0.projectID != board.id }
        items.append(BoardItem(id: old.boardItem(on: board)?.id ?? "", projectID: board.id, status: statusName))
        boardTickets[i] = old.with(boardItems: items)
    }

    private func mutate(_ ticket: Ticket, _ work: @escaping (GitHubClient, Board) async throws -> Void) async {
        do {
            guard let board else { throw GitHubError.graphQL("The board hasn't loaded yet") }
            try await work(try authorizedClient(), board)
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
        if selection == ticket.id { await loadDetail(id: ticket.id) }
    }
}
