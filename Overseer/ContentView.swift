import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Binding var showingNewTicket: Bool

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            TicketListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            if let ticket = store.selectedTicket {
                TicketDetailView(ticket: ticket)
                    .id(ticket.id)
            } else {
                ContentUnavailableView("No Ticket Selected", systemImage: "tray",
                                       description: Text("File a ticket with ⌘N, or pick one from the list."))
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search tickets")
        .onSubmit(of: .search) { Task { await store.refresh() } }
        .onChange(of: store.searchText) { _, new in
            if new.isEmpty { Task { await store.refresh() } }
        }
        .onChange(of: store.sidebar) {
            store.selection = nil
            Task { await store.refresh() }
        }
        .onChange(of: store.selection) { _, id in
            store.detail = nil
            store.detailComments = []
            if let id { Task { await store.loadDetail(id: id) } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.sidebar) {
            Section(store.board?.title ?? "Board") {
                ForEach([SidebarItem.todo, .inProgress, .review, .backlog, .done]) { item in
                    Label(item.title, systemImage: symbol(item))
                        .badge(store.count(item) ?? 0)
                        .tag(item)
                }
            }
            Section("GitHub") {
                Label(SidebarItem.allOpen.title, systemImage: "tray.full").tag(SidebarItem.allOpen)
            }
            Section("Repositories") {
                ForEach(store.repos) { repo in
                    Label(repo.name, systemImage: "shippingbox").tag(SidebarItem.repo(repo.nameWithOwner))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let last = store.lastRefresh {
                Text("Updated \(last, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }
}

extension SidebarView {
    func symbol(_ item: SidebarItem) -> String {
        switch item {
        case .todo: TicketStatus.todo.symbol
        case .inProgress: TicketStatus.inProgress.symbol
        case .review: TicketStatus.review.symbol
        case .backlog: TicketStatus.backlog.symbol
        case .done: TicketStatus.done.symbol
        default: "tray"
        }
    }
}

// MARK: - List

struct TicketListView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            ForEach(store.groupedTickets, id: \.0) { status, tickets in
                Section {
                    ForEach(tickets) { ticket in
                        TicketRow(ticket: ticket, status: status).tag(ticket.id)
                    }
                } header: {
                    Label("\(status.rawValue) · \(tickets.count)", systemImage: status.symbol)
                        .foregroundStyle(status.tint)
                }
            }
        }
        .overlay {
            if store.visibleTickets.isEmpty && !store.isLoading {
                ContentUnavailableView("No Tickets", systemImage: "tray",
                                       description: Text(store.searchText.isEmpty ? "Nothing here yet." : "No matches."))
            }
        }
        .navigationTitle(title)
    }

    private var title: String { (store.sidebar ?? .todo).title }
}

struct TicketRow: View {
    let ticket: Ticket
    let status: TicketStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .symbolEffect(.pulse, isActive: status == .inProgress)
            VStack(alignment: .leading, spacing: 3) {
                Text(ticket.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(ticket.key).monospacedDigit()
                    if let pr = ticket.pullRequests.first(where: { $0.state == .open }) ?? ticket.pullRequests.first {
                        Text("PR #\(pr.number)")
                    }
                    if ticket.commentCount > 0 {
                        Label("\(ticket.commentCount)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                    }
                    Spacer()
                    Text(ticket.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
