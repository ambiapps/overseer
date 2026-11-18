#if DEBUG
import AppKit

/// Made-up issues for debug snapshots, so screenshots never show a real workspace.
extension LinearStore {
    func fillWithDemo() {
        isDemo = true
        teams = [LinearTeam(id: "team", name: "Design", key: "DES")]
        let states = [
            LinearState(id: "backlog", name: "Backlog", type: "backlog", position: 0, color: "#bec2c8"),
            LinearState(id: "todo", name: "Todo", type: "unstarted", position: 1, color: "#e2e2e2"),
            LinearState(id: "clarify", name: "Needs clarification", type: "unstarted", position: 2, color: "#eb5757"),
            LinearState(id: "progress", name: "In Progress", type: "started", position: 3, color: "#f2c94c"),
            LinearState(id: "review", name: "In Review", type: "started", position: 4, color: "#0f9d58"),
            LinearState(id: "done", name: "Done", type: "completed", position: 5, color: "#5e6ad2"),
        ]
        teamID = "team" // before the states: changing the team clears the board
        self.states = states
        let now = Date.now
        func issue(_ n: Int, _ title: String, _ state: String, priority: Double, hours: Double,
                   assignee: String? = nil, labels: [(String, String)] = []) -> LinearIssue {
            let names = ["No priority", "Urgent", "High", "Medium", "Low"]
            return LinearIssue(
                id: "issue-\(n)", identifier: "DES-\(n)", title: title,
                description: "The current flow takes three taps to get here.\n\n## Acceptance\n- Works in light and dark mode\n- Matches the spacing on the board",
                url: URL(string: "https://linear.app")!, priority: priority, priorityLabel: names[Int(priority)],
                createdAt: now.addingTimeInterval(-hours * 3600 - 86_400), updatedAt: now.addingTimeInterval(-hours * 3600),
                state: .init(id: state), assignee: assignee.map { LinearPerson(name: $0, displayName: $0) },
                creator: LinearPerson(name: "Sam", displayName: "Sam"),
                labels: .init(nodes: labels.map { LinearLabel(name: $0.0, color: $0.1) }))
        }
        let feature = ("Feature", "#5e6ad2"), bug = ("Bug", "#eb5757"), polish = ("Polish", "#26b5ce")
        issues = [
            issue(41, "Explore a compact card layout for long titles", "backlog", priority: 4, hours: 50, labels: [polish]),
            issue(38, "Onboarding illustrations for empty states", "backlog", priority: 0, hours: 120),
            issue(44, "Keyboard shortcuts cheat sheet", "backlog", priority: 3, hours: 30, labels: [feature]),
            issue(52, "Redesign the settings window", "todo", priority: 2, hours: 5, assignee: "Alex", labels: [feature]),
            issue(53, "Date picker clips in dark mode", "todo", priority: 1, hours: 2, labels: [bug]),
            issue(49, "Icon set for ticket states", "todo", priority: 3, hours: 26, assignee: "Robin"),
            issue(51, "Which export formats should the share sheet offer?", "clarify", priority: 2, hours: 6, labels: [feature]),
            issue(47, "Drag and drop between columns", "progress", priority: 2, hours: 1, assignee: "Alex", labels: [feature]),
            issue(50, "Tighten spacing in the inspector", "progress", priority: 3, hours: 3, assignee: "Robin", labels: [polish]),
            issue(45, "Comment composer supports Markdown", "review", priority: 2, hours: 4, assignee: "Sam", labels: [feature]),
            issue(40, "App icon, first round", "done", priority: 2, hours: 20, assignee: "Robin"),
            issue(39, "Toolbar overflow on small windows", "done", priority: 1, hours: 70, assignee: "Alex", labels: [bug]),
        ]
        lastRefresh = now
    }

    /// What every demo image loads as: the app icon.
    static var demoImage: Data {
        let icon = NSApplication.shared.applicationIconImage!
        let rep = NSBitmapImageRep(data: icon.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    static let demoComments = [
        LinearComment(id: "c1", body: "Started on this — the drop target highlights the column now.",
                      createdAt: .now.addingTimeInterval(-7200), user: LinearPerson(name: "Alex", displayName: "Alex"), botActor: nil),
        LinearComment(id: "c2", body: "Looks great. Can we also show the card while it's dragged?\n\n![Pasted image.png](https://uploads.linear.app/demo/pasted-image.png)",
                      createdAt: .now.addingTimeInterval(-3600), user: LinearPerson(name: "Sam", displayName: "Sam"), botActor: nil),
    ]
}
#endif
