import SwiftUI

/// The Linear board: a column per workflow state of the chosen team.
struct LinearContentView: View {
    @Environment(LinearStore.self) private var store
    @Binding var source: BoardSource
    @Binding var showingNewTicket: Bool
    @AppStorage("showBacklog") private var showBacklog = true

    var body: some View {
        @Bindable var store = store
        Group {
            if !store.hasKey {
                ContentUnavailableView {
                    Label("Connect Linear", systemImage: "key")
                } description: {
                    Text("Create a personal API key in Linear under Settings → Security & access, then paste it in Overseer's Settings.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                LinearBoardView(showBacklog: showBacklog)
            }
        }
        .navigationTitle(store.team.map { "Linear · \($0.name)" } ?? "Linear")
        .navigationSubtitle(subtitle)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Filter issues")
        .inspector(isPresented: inspectorShown) {
            Group {
                if let issue = store.selectedIssue {
                    LinearIssueDetailView(issue: issue).id(issue.id)
                }
            }
            .inspectorColumnWidth(min: 380, ideal: 460, max: 700)
        }
        .onChange(of: store.selection) { _, id in
            store.detail = nil
            store.detailComments = []
            if let id { Task { await store.loadDetail(id: id) } }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { SourcePicker(source: $source) }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Team", selection: $store.teamID) {
                        ForEach(store.teams) { team in
                            Text(team.name).tag(String?.some(team.id))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(store.team?.name ?? "Team", systemImage: "person.3")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(store.teams.count < 2)
                .help("Show another team's board")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showBacklog) {
                    Label("Backlog", systemImage: "archivebox")
                }
                .help(showBacklog ? "Hide the backlog columns" : "Show the backlog columns")

                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Refresh (⌘R)")

                Button {
                    showingNewTicket = true
                } label: {
                    Label("New Ticket", systemImage: "square.and.pencil")
                }
                .disabled(!store.canCreate)
                .help("New Ticket (⌘N)")
            }
        }
        .sheet(isPresented: $showingNewTicket) {
            LinearNewTicketView()
        }
        .overlay(alignment: .bottom) {
            if let error = store.error {
                ErrorBanner(message: error, isError: true) { store.error = nil }
                    .padding()
            } else if let notice = store.notice {
                ErrorBanner(message: notice, isError: false) { store.notice = nil }
                    .padding()
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        if store.notice == notice { store.notice = nil }
                    }
            }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { store.selection != nil }, set: { if !$0 { store.selection = nil } })
    }

    private var subtitle: String {
        guard store.hasKey else { return "" }
        guard let last = store.lastRefresh else { return "Loading…" }
        return "Updated \(last.formatted(date: .omitted, time: .shortened))"
    }
}

/// Switches the window between the GitHub and Linear boards.
struct SourcePicker: View {
    @Binding var source: BoardSource

    var body: some View {
        Picker("Board", selection: $source) {
            ForEach(BoardSource.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Switch between the GitHub and Linear boards")
    }
}

struct LinearBoardView: View {
    @Environment(LinearStore.self) private var store
    let showBacklog: Bool

    private var columns: [LinearState] {
        store.states.filter { showBacklog || ($0.type != "backlog" && $0.type != "triage") }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { state in
                        LinearColumnView(state: state)
                            .frame(width: columnWidth(for: geometry.size.width))
                    }
                }
                .padding(12)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(.background.secondary)
        .overlay {
            if store.states.isEmpty && store.isLoading {
                ProgressView("Loading the board…")
            }
        }
    }

    private func columnWidth(for width: CGFloat) -> CGFloat {
        let count = CGFloat(max(columns.count, 1))
        return max(250, (width - 24 - 12 * (count - 1)) / count)
    }
}

struct LinearColumnView: View {
    @Environment(LinearStore.self) private var store
    let state: LinearState
    @State private var isTargeted = false

    var body: some View {
        let issues = store.issues(in: state)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LinearStateIcon(state: state)
                Text(state.name).font(.headline)
                Text("\(issues.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(issues) { issue in
                        LinearIssueCard(issue: issue, isSelected: store.selection == issue.id)
                            .onTapGesture { store.selection = store.selection == issue.id ? nil : issue.id }
                            .draggable(issue.id) {
                                LinearIssueCard(issue: issue, isSelected: true).frame(width: 260)
                            }
                    }
                    if issues.isEmpty {
                        Text(state.isClosed ? "Nothing in the last \(LinearStore.closedDays) days." : "No issues.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(8)
            }
        }
        .background(isTargeted ? AnyShapeStyle(Color(hex: state.color).opacity(0.08)) : AnyShapeStyle(.background.tertiary),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color(hex: state.color) : .clear, lineWidth: 2)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            Task { await store.move(id, to: state) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct LinearIssueCard: View {
    let issue: LinearIssue
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(issue.identifier)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                PriorityIcon(priority: Int(issue.priority), label: issue.priorityLabel)
            }
            Text(issue.title)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(issue.labels.nodes.prefix(3), id: \.name) { label in
                    HStack(spacing: 3) {
                        Circle().fill(Color(hex: label.color)).frame(width: 6, height: 6)
                        Text(label.name).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let assignee = issue.assignee {
                    Text(assignee.displayName ?? assignee.name).lineLimit(1)
                }
                Text(issue.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct LinearStateIcon: View {
    let state: LinearState

    var body: some View {
        Image(systemName: symbol).foregroundStyle(Color(hex: state.color))
    }

    private var symbol: String {
        switch state.type {
        case "triage": "tray"
        case "backlog": "circle.dashed"
        case "unstarted": "circle"
        case "started": "circle.lefthalf.filled"
        case "completed": "checkmark.circle.fill"
        case "canceled": "xmark.circle.fill"
        default: "circle"
        }
    }
}

struct PriorityIcon: View {
    let priority: Int
    let label: String

    var body: some View {
        switch priority {
        case 1: Image(systemName: "exclamationmark.square.fill").foregroundStyle(.orange).help(label)
        case 2: Image(systemName: "cellularbars", variableValue: 1).foregroundStyle(.secondary).help(label)
        case 3: Image(systemName: "cellularbars", variableValue: 0.66).foregroundStyle(.secondary).help(label)
        case 4: Image(systemName: "cellularbars", variableValue: 0.33).foregroundStyle(.secondary).help(label)
        default: EmptyView()
        }
    }
}

struct LinearIssueDetailView: View {
    @Environment(LinearStore.self) private var store
    @Environment(\.openURL) private var openURL
    let issue: LinearIssue

    @State private var reply = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                MarkdownText((issue.description ?? "").isEmpty ? "_No description._" : issue.description!)
                if !store.detailComments.isEmpty {
                    Divider()
                    comments
                }
                replyBox
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(issue.identifier)
        .toolbar {
            Button { openURL(issue.url) } label: { Label("Open in Linear", systemImage: "safari") }
                .help("Open in Linear")
        }
    }

    private var meta: String {
        var parts = [issue.identifier]
        if let creator = issue.creator { parts.append("opened by \(creator.displayName ?? creator.name)") }
        parts.append(issue.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(issue.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack {
                Menu {
                    ForEach(store.states) { state in
                        Button {
                            act { await store.move(issue.id, to: state) }
                        } label: {
                            if state.id == issue.state.id { Label(state.name, systemImage: "checkmark") } else { Text(state.name) }
                        }
                    }
                } label: {
                    if let state = store.state(of: issue) {
                        Label { Text(state.name) } icon: { LinearStateIcon(state: state) }
                    } else {
                        Text("Status")
                    }
                }
                .fixedSize()
                .help("Move to another column")
                if issue.priority > 0 {
                    Label { Text(issue.priorityLabel) } icon: { PriorityIcon(priority: Int(issue.priority), label: issue.priorityLabel) }
                        .font(.callout)
                }
                if let assignee = issue.assignee {
                    Label(assignee.displayName ?? assignee.name, systemImage: "person.crop.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(busy)
            Text(meta).font(.callout).foregroundStyle(.secondary)
            if !issue.labels.nodes.isEmpty {
                HStack {
                    ForEach(issue.labels.nodes, id: \.name) { label in
                        Text(label.name)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color(hex: label.color).opacity(0.25), in: Capsule())
                    }
                }
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.detailComments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(comment.author).font(.callout.weight(.semibold))
                        Text(comment.createdAt, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownText(comment.body)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var replyBox: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $reply)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .overlay(alignment: .topLeading) {
                    if reply.isEmpty {
                        Text("Add a comment…").foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                    }
                }
            Button("Comment") {
                let body = reply
                act {
                    await store.comment(on: issue.id, body: body)
                    reply = ""
                }
            }
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
    }

    private func act(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}
