import Foundation
import Observation

/// Which board the window shows.
enum BoardSource: String, CaseIterable, Identifiable {
    case github, linear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .github: "GitHub"
        case .linear: "Linear"
        }
    }
}

/// A Linear team's issues, laid out by workflow state. Moving and commenting write straight to Linear.
@MainActor
@Observable
final class LinearStore {
    static let teamKey = "linearTeam"
    static let closedDays = 14

    var teams: [LinearTeam] = []
    var states: [LinearState] = []
    var issues: [LinearIssue] = []
    var selection: LinearIssue.ID?
    var searchText = ""
    var isLoading = false
    var error: String?
    var notice: String?
    var lastRefresh: Date?
    var detail: LinearIssue?
    var detailComments: [LinearComment] = []

    var teamID: String? {
        didSet {
            guard teamID != oldValue else { return }
            UserDefaults.standard.set(teamID, forKey: Self.teamKey)
            states = []
            issues = []
            selection = nil
            Task { await refresh() }
        }
    }

    private var client: LinearClient?
    private var pollTask: Task<Void, Never>?

    init() {
        // The backing storage: through the setter, `didSet` would start a refresh before
        // `start()` (or a debug snapshot's demo data) is ready for one.
        _teamID = UserDefaults.standard.string(forKey: Self.teamKey)
    }

    var team: LinearTeam? { teams.first { $0.id == teamID } }
    var hasKey: Bool { isDemo || LinearKey.key() != nil }
    /// Debug snapshots fill the board with made-up issues and never call Linear.
    var isDemo = false

    // MARK: Derived

    func state(of issue: LinearIssue) -> LinearState? {
        states.first { $0.id == issue.state.id }
    }

    func issues(in state: LinearState) -> [LinearIssue] {
        let text = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let cutoff = Date.now.addingTimeInterval(-Double(Self.closedDays) * 86_400)
        return issues
            .filter { $0.state.id == state.id }
            .filter { !state.isClosed || $0.updatedAt >= cutoff }
            .filter { text.isEmpty || $0.title.lowercased().contains(text) || $0.identifier.lowercased().contains(text) }
            .sorted { lhs, rhs in
                // Urgent (1) first, no priority (0) last, then the most recently touched.
                let left = lhs.priority == 0 ? 5 : lhs.priority
                let right = rhs.priority == 0 ? 5 : rhs.priority
                return left != right ? left < right : lhs.updatedAt > rhs.updatedAt
            }
    }

    var selectedIssue: LinearIssue? {
        guard let selection else { return nil }
        if let detail, detail.id == selection { return detail }
        return issues.first { $0.id == selection }
    }

    // MARK: Loading

    private func authorizedClient() throws -> LinearClient {
        if let client { return client }
        guard let key = LinearKey.key() else { throw LinearError.noKey }
        let client = LinearClient(key: key)
        self.client = client
        return client
    }

    /// Settings changed the key: start over.
    func resetAuth() {
        client = nil
        teams = []
        states = []
        issues = []
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
        guard !isDemo else { return }
        guard hasKey else {
            client = nil
            teams = []
            issues = []
            error = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try authorizedClient()
            if teams.isEmpty { teams = try await client.teams() }
            if team == nil, let first = teams.first {
                teamID = first.id // refreshes again for the new team
                return
            }
            guard let teamID else { return }
            if states.isEmpty { states = try await client.states(team: teamID) }
            let since = Date.now.addingTimeInterval(-Double(Self.closedDays) * 86_400)
            let loaded = try await client.issues(team: teamID, closedSince: since)
            guard teamID == self.teamID else { return }
            issues = loaded
            error = nil
            lastRefresh = .now
            if let selection, detail?.id == selection { await loadDetail(id: selection) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadDetail(id: LinearIssue.ID) async {
        guard !isDemo else { return }
        do {
            let (issue, comments) = try await authorizedClient().issue(id: id)
            guard selection == id else { return }
            detail = issue
            detailComments = comments
            if let index = issues.firstIndex(where: { $0.id == id }) { issues[index] = issue }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Actions

    func move(_ issueID: LinearIssue.ID, to state: LinearState) async {
        guard let index = issues.firstIndex(where: { $0.id == issueID }),
              issues[index].state.id != state.id else { return }
        // Show the move at once; the refresh confirms or reverts it.
        issues[index].state = .init(id: state.id)
        if detail?.id == issueID { detail?.state = .init(id: state.id) }
        await mutate(issueID) { try await $0.setState(issue: issueID, state: state.id) }
    }

    func comment(on issueID: LinearIssue.ID, body: String) async {
        await mutate(issueID) { try await $0.comment(issue: issueID, body: body) }
    }

    /// The state a new ticket starts in: the team's first Todo-type state, else its first open one.
    var defaultNewState: LinearState? {
        states.first { $0.type == "unstarted" } ?? states.first { !$0.isClosed }
    }

    var canCreate: Bool { hasKey && team != nil && defaultNewState != nil }

    /// Files a ticket in the current team and selects it. Returns whether it was created.
    func createIssue(title: String, description: String, state: LinearState, priority: Int) async -> Bool {
        do {
            guard let teamID else { throw LinearError.graphQL("No team is selected.") }
            let issue = try await authorizedClient().createIssue(
                team: teamID, title: title, description: description, state: state.id, priority: priority)
            if teamID == self.teamID, !issues.contains(where: { $0.id == issue.id }) { issues.append(issue) }
            selection = issue.id
            notice = "Filed \(issue.identifier) in \(state.name)."
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func mutate(_ issueID: LinearIssue.ID, _ work: (LinearClient) async throws -> Void) async {
        do {
            try await work(try authorizedClient())
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
        if selection == issueID { await loadDetail(id: issueID) }
    }
}
