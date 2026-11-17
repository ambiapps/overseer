import Foundation
import SwiftUI

struct Repo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let nameWithOwner: String
}

/// The org project board that agents watch, with its Status field.
struct Board: Hashable, Sendable {
    struct Option: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }
    let id: String
    let number: Int
    let title: String
    let url: URL
    let statusFieldID: String
    let options: [Option]

    func option(named name: String) -> Option? {
        options.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// An issue's place on a board.
struct BoardItem: Hashable, Sendable {
    let id: String
    let projectID: String
    let status: String?
}

struct IssueLabel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let color: String

    var swiftUIColor: Color { Color(hex: color) }
}

struct User: Hashable, Sendable {
    let login: String
    let avatarURL: URL?
}

struct LinkedPR: Identifiable, Hashable, Sendable {
    enum State: String, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }
    enum Checks: String, Sendable { case success = "SUCCESS", failure = "FAILURE", error = "ERROR", pending = "PENDING", expected = "EXPECTED" }

    var id: Int { number }
    let number: Int
    let title: String
    let url: URL
    let state: State
    let isDraft: Bool
    let checks: Checks?
}

struct Comment: Identifiable, Hashable, Sendable {
    let id: String
    let author: User?
    let body: String
    let createdAt: Date
    let url: URL
}

struct Ticket: Identifiable, Hashable, Sendable {
    let id: String
    let number: Int
    let title: String
    let body: String
    let url: URL
    let isOpen: Bool
    let stateReason: String?
    let createdAt: Date
    let updatedAt: Date
    let author: User?
    let repoName: String
    let repoNameWithOwner: String
    let labels: [IssueLabel]
    let assignees: [User]
    let commentCount: Int
    let pullRequests: [LinkedPR]
    let boardItems: [BoardItem]

    func boardItem(on board: Board?) -> BoardItem? {
        guard let board else { return nil }
        return boardItems.first { $0.projectID == board.id }
    }

    var key: String { "\(repoName)#\(number)" }
}

/// Where a ticket is, from its board Status, linked PRs and issue state.
enum TicketStatus: String, CaseIterable, Identifiable, Sendable {
    case todo = "To Do"
    case inProgress = "In Progress"
    case review = "In Review"
    case backlog = "Backlog"
    case unfiled = "Not on Board"
    case done = "Done"
    case closed = "Closed"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .todo: "tray.and.arrow.down.fill"
        case .inProgress: "gearshape.2.fill"
        case .review: "arrow.triangle.pull"
        case .backlog: "archivebox"
        case .unfiled: "square.dashed"
        case .done: "checkmark.circle.fill"
        case .closed: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .todo: .orange
        case .inProgress: .blue
        case .review: .purple
        case .backlog, .unfiled, .closed: .secondary
        case .done: .green
        }
    }

    static func derive(_ ticket: Ticket, board: Board?) -> TicketStatus {
        if !ticket.isOpen {
            return ticket.stateReason == "COMPLETED" || ticket.pullRequests.contains { $0.state == .merged } ? .done : .closed
        }
        if ticket.pullRequests.contains(where: { $0.state == .open }) { return .review }
        guard let item = ticket.boardItem(on: board) else { return .unfiled }
        switch item.status?.lowercased() {
        case "to do": return .todo
        case "in progress": return .inProgress
        case "done": return .done
        default: return .backlog
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
