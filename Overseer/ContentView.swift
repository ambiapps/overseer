import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Binding var showingNewTicket: Bool
    @Binding var source: BoardSource
    @AppStorage("showBacklog") private var showBacklog = true

    var body: some View {
        @Bindable var store = store
        Group {
            if store.accounts.isEmpty {
                SignedOutView()
            } else if store.boardRef == nil {
                ContentUnavailableView {
                    Label("Choose a Board", systemImage: "rectangle.split.3x1")
                } description: {
                    Text(store.availableBoards.isEmpty && store.isLoading
                         ? "Looking for boards your accounts can see…"
                         : "Pick one of the boards your GitHub accounts can see. You can change it in Settings.")
                } actions: {
                    BoardPicker().labelsHidden().fixedSize()
                }
            } else {
                BoardView(showBacklog: showBacklog)
            }
        }
            .navigationTitle(store.board?.title ?? "Overseer")
            .navigationSubtitle(subtitle)
            .searchable(text: $store.searchText, placement: .toolbar, prompt: "Filter tickets")
            .inspector(isPresented: inspectorShown) {
                Group {
                    if let ticket = store.selectedTicket {
                        TicketDetailView(ticket: ticket).id(ticket.id)
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
                if store.board != nil {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Picker("Repository", selection: $store.repoFilter) {
                            Text("All Repositories").tag(String?.none)
                            Divider()
                            ForEach(store.boardRepos, id: \.self) { name in
                                Text(name.components(separatedBy: "/").last ?? name).tag(String?.some(name))
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(repoTitle, systemImage: "shippingbox")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Show one repository")
                }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $showBacklog) {
                        Label("Hold", systemImage: "pause.circle")
                    }
                    .help(showBacklog ? "Hide the Hold column" : "Show the Hold column")

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
                    .disabled(store.board == nil)
                    .help("New Ticket (⌘N)")
                }
            }
            .sheet(isPresented: $showingNewTicket) {
                NewTicketView()
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

    private var repoTitle: String {
        store.repoFilter.flatMap { $0.components(separatedBy: "/").last } ?? "All Repositories"
    }

    private var subtitle: String {
        guard let last = store.lastRefresh else { return "Loading…" }
        return "Updated \(last.formatted(date: .omitted, time: .shortened))"
    }
}

/// Shown until a GitHub account is signed in.
struct SignedOutView: View {
    @State private var signingIn = false

    var body: some View {
        ContentUnavailableView {
            Label("Sign in to GitHub", systemImage: "person.badge.key")
        } description: {
            Text("Overseer shows the issues on your GitHub project boards. Sign in with each GitHub account whose boards you want to see.")
        } actions: {
            Button("Sign In to GitHub…") { signingIn = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $signingIn) { SignInView() }
    }
}

struct ErrorBanner: View {
    let message: String
    var isError = true
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .yellow : .green)
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 560)
    }
}

// MARK: - Board

struct BoardView: View {
    @Environment(Store.self) private var store
    let showBacklog: Bool

    private var columns: [BoardColumn] {
        BoardColumn.allCases.filter { showBacklog || $0 != .hold }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { column in
                        BoardColumnView(column: column)
                            .frame(width: columnWidth(for: geometry.size.width))
                    }
                }
                .padding(12)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(.background.secondary)
        .overlay {
            if store.boardTickets.isEmpty && store.isLoading {
                ProgressView("Loading the board…")
            }
        }
    }

    /// Columns share the window, but never get narrower than a readable card.
    private func columnWidth(for width: CGFloat) -> CGFloat {
        let count = CGFloat(columns.count)
        return max(250, (width - 24 - 12 * (count - 1)) / count)
    }
}

struct BoardColumnView: View {
    @Environment(Store.self) private var store
    let column: BoardColumn
    @State private var isTargeted = false

    var body: some View {
        let tickets = store.tickets(in: column)
        VStack(alignment: .leading, spacing: 0) {
            header(count: tickets.count)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tickets) { ticket in
                        TicketCard(ticket: ticket, status: store.status(of: ticket), isSelected: store.selection == ticket.id)
                            .onTapGesture { store.selection = store.selection == ticket.id ? nil : ticket.id }
                            .draggable(ticket.id) {
                                TicketCard(ticket: ticket, status: store.status(of: ticket), isSelected: true)
                                    .frame(width: 260)
                            }
                    }
                    if tickets.isEmpty {
                        Text(column.hint)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(8)
            }
        }
        .background(columnBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? column.status.tint : .clear, lineWidth: 2)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard column.dropStatus != nil, let id = ids.first else { return false }
            Task { await store.drop(ticketID: id, on: column) }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted && column.dropStatus != nil
        }
    }

    private var columnBackground: some ShapeStyle {
        isTargeted ? AnyShapeStyle(column.status.tint.opacity(0.08)) : AnyShapeStyle(.background.tertiary)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: column.status.symbol)
                .foregroundStyle(column.status.tint)
            Text(column.title).font(.headline)
            Text("\(count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .help(column.hint)
    }
}

struct TicketCard: View {
    let ticket: Ticket
    let status: TicketStatus
    let isSelected: Bool

    private var pr: LinkedPR? {
        ticket.pullRequests.first { $0.state == .open } ?? ticket.pullRequests.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(ticket.key)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if status == .inProgress || status == .needsClarification {
                    Image(systemName: status.symbol)
                        .font(.caption)
                        .foregroundStyle(status.tint)
                        .symbolEffect(.pulse, isActive: status == .inProgress)
                }
            }
            Text(ticket.title)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let pr {
                    HStack(spacing: 3) {
                        Image(systemName: pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                        Text(verbatim: "#\(pr.number)")
                        if let checks = pr.checks { ChecksBadge(checks: checks) }
                    }
                }
                if ticket.commentCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.left")
                        Text("\(ticket.commentCount)")
                    }
                }
                Spacer()
                Text(ticket.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
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
