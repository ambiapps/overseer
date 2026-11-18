import Foundation
import Testing
@testable import Overseer

struct LinearDecodingTests {
    @Test func decodesAnIssueWithLinearsTimestamps() throws {
        let json = """
        {"id": "a1", "identifier": "DES-12", "title": "Fix it", "description": null,
         "url": "https://linear.app/x/issue/DES-12", "priority": 2, "priorityLabel": "High",
         "createdAt": "2026-11-01T10:00:00.123Z", "updatedAt": "2026-11-02T10:00:00Z",
         "state": {"id": "s1"}, "assignee": null, "creator": {"name": "Sam", "displayName": "sam"},
         "labels": {"nodes": [{"name": "Bug", "color": "#eb5757"}]}}
        """
        let issue = try LinearClient.decoder.decode(LinearIssue.self, from: Data(json.utf8))
        #expect(issue.identifier == "DES-12")
        #expect(issue.state.id == "s1")
        #expect(issue.labels.nodes.map(\.name) == ["Bug"])
        #expect(issue.updatedAt.timeIntervalSince(issue.createdAt).rounded() == 86_400)
    }

    @Test func aBotCommentNamesTheBot() throws {
        let json = """
        {"id": "c1", "body": "Done", "createdAt": "2026-11-02T10:00:00.000Z", "user": null, "botActor": {"name": "GitHub"}}
        """
        #expect(try LinearClient.decoder.decode(LinearComment.self, from: Data(json.utf8)).author == "GitHub")
    }

    @Test func columnsFollowLinearsOrder() {
        func state(_ id: String, _ type: String, _ position: Double) -> LinearState {
            LinearState(id: id, name: id, type: type, position: position, color: "#000000")
        }
        let shuffled = [state("done", "completed", 0), state("doing", "started", 2), state("review", "started", 3),
                        state("todo", "unstarted", 9), state("backlog", "backlog", 5), state("canceled", "canceled", 0)]
        #expect(shuffled.sorted(by: LinearState.boardOrder).map(\.id) == ["backlog", "todo", "doing", "review", "done", "canceled"])
    }
}

@MainActor
struct LinearStoreTests {
    @Test func columnsSortByPriorityThenRecency() {
        let store = LinearStore()
        store.fillWithDemo()
        let todo = store.states.first { $0.id == "todo" }!
        // Urgent first, then High, then Medium.
        #expect(store.issues(in: todo).map(\.identifier) == ["DES-53", "DES-52", "DES-49"])
    }

    @Test func searchFiltersByTitleOrIdentifier() {
        let store = LinearStore()
        store.fillWithDemo()
        let backlog = store.states.first { $0.id == "backlog" }!
        store.searchText = "des-44"
        #expect(store.issues(in: backlog).map(\.identifier) == ["DES-44"])
        store.searchText = "illustrations"
        #expect(store.issues(in: backlog).map(\.identifier) == ["DES-38"])
    }

    @Test func oldClosedIssuesLeaveTheBoard() {
        let store = LinearStore()
        store.fillWithDemo()
        let done = store.states.first { $0.id == "done" }!
        let old = store.issues.first { $0.identifier == "DES-40" }!
        store.issues.append(LinearIssue(
            id: "old", identifier: "DES-1", title: "Old", description: nil, url: old.url, priority: 0,
            priorityLabel: "No priority", createdAt: .distantPast, updatedAt: .now.addingTimeInterval(-30 * 86_400),
            state: .init(id: "done"), assignee: nil, creator: nil, labels: .init(nodes: [])))
        #expect(!store.issues(in: done).contains { $0.id == "old" })
    }
}
