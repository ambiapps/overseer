import SwiftUI

struct TicketDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    let ticket: Ticket

    @State private var reply = ""
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editBody = ""
    @State private var busy = false

    private var status: TicketStatus { store.status(of: ticket) }
    private var boardStatus: String? { ticket.boardItem(on: store.board)?.status }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                boardPanel
                if !ticket.pullRequests.isEmpty { pullRequests }
                Divider()
                if isEditing { editor } else { MarkdownText(ticket.body.isEmpty ? "_No description._" : ticket.body) }
                if !store.detailComments.isEmpty {
                    Divider()
                    comments
                }
                replyBox
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.imageFetcher) { [store] in try await store.download($0) }
        .navigationTitle(ticket.key)
        .toolbar {
            ToolbarItemGroup {
                Button { openURL(ticket.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                    .help("Open on GitHub")
                Button {
                    editTitle = ticket.title
                    editBody = ticket.body
                    isEditing = true
                } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(isEditing)
                    .help("Edit ticket")
            }
        }
    }

    // MARK: Sections

    private var meta: String {
        var parts = [ticket.repoNameWithOwner]
        if let author = ticket.author { parts.append("opened by \(author.login)") }
        parts.append(ticket.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            StatusBadge(status: status)
            Text(meta)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !ticket.labels.isEmpty {
                HStack {
                    ForEach(ticket.labels) { label in
                        Text(label.name)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(label.swiftUIColor.opacity(0.25), in: Capsule())
                    }
                }
            }
        }
    }

    private var boardPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.headline)
                    if !detailText.isEmpty {
                        Text(detailText).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    if ticket.isOpen {
                        if status == .review {
                            // The PR is the next step; comments on it reach the agent.
                        } else if boardStatus == Store.todoStatus {
                            Button("Restart Agents") { act { await store.restart(ticket) } }
                                .help("Moves it to Backlog and back to To Do, which starts the agents again.")
                        } else if status != .review {
                            Button("Move to To Do") { act { await store.move(ticket, to: Store.todoStatus) } }
                                .buttonStyle(.borderedProminent)
                                .help("Agents pick up tickets you move into To Do on the board.")
                        }
                        statusMenu
                        Spacer()
                        Button("Close") { act { await store.setOpen(ticket, open: false) } }
                    } else {
                        Spacer()
                        Button("Reopen") { act { await store.setOpen(ticket, open: true) } }
                    }
                }
            }
            .disabled(busy || store.board == nil)
            .padding(6)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(store.board?.options ?? []) { option in
                Button {
                    act { await store.move(ticket, to: option.name) }
                } label: {
                    if option.name == boardStatus { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            Text(boardStatus ?? "Not on board")
        }
        .fixedSize()
        .help("Board status")
    }

    private var headline: String {
        switch status {
        case .todo: "In To Do: handed to the agents"
        case .inProgress: "In progress"
        case .review: "PR open for review"
        case .needsClarification: "The agent needs clarification"
        case .backlog: "In \(boardStatus ?? "Backlog")"
        case .unfiled: "Not on the board"
        case .done: "Done"
        case .closed: "Closed"
        }
    }

    private var detailText: String {
        switch status {
        case .todo: "The agents start when a ticket moves into To Do. If nothing happens, check that the Ambre agent's GitHub App can see \(ticket.repoName)."
        case .review: "Comment on the PR to have the agent make changes."
        case .needsClarification: "Its question is in the comments. Answer it, edit the ticket if that helps, then move it back to To Do."
        case .backlog, .unfiled: "Move it to To Do when it's ready for an agent."
        default: ""
        }
    }

    private var pullRequests: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pull Requests").font(.headline)
            ForEach(ticket.pullRequests) { pr in
                Button { openURL(pr.url) } label: {
                    HStack {
                        Image(systemName: pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                            .foregroundStyle(pr.state == .merged ? .purple : pr.state == .open ? .green : .secondary)
                        Text(verbatim: "#\(pr.number) \(pr.title)").lineLimit(1)
                        if pr.isDraft { Text("Draft").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let checks = pr.checks { ChecksBadge(checks: checks) }
                        Text(pr.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $editTitle).textFieldStyle(.roundedBorder).font(.title3)
            AttachmentEditor(text: $editBody, upload: upload, onError: { store.error = $0 })
                .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                Button("Save") {
                    act {
                        await store.edit(ticket, title: editTitle, body: editBody)
                        isEditing = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editTitle.trimmingCharacters(in: .whitespaces).isEmpty || Attachment.isUploading(editBody))
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.detailComments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(comment.author?.login ?? "ghost").font(.callout.weight(.semibold))
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
            AttachmentEditor(text: $reply, font: .systemFont(ofSize: NSFont.systemFontSize), placeholder: "Add a comment…",
                             upload: upload, onError: { store.error = $0 })
                .frame(minHeight: 70)
            Button("Comment") {
                let body = reply
                act {
                    await store.comment(on: ticket, body: body)
                    reply = ""
                }
            }
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || Attachment.isUploading(reply))
        }
    }

    private func upload(_ attachment: Attachment) async throws -> URL {
        try await store.upload(attachment, repo: ticket.repoNameWithOwner)
    }

    private func act(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

struct StatusBadge: View {
    let status: TicketStatus

    var body: some View {
        Label(status.rawValue, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.tint.opacity(0.12), in: Capsule())
    }
}

struct ChecksBadge: View {
    let checks: LinkedPR.Checks

    var body: some View {
        switch checks {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passed")
        case .failure, .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failed")
        case .pending, .expected: Image(systemName: "circle.dotted").foregroundStyle(.orange).help("Checks running")
        }
    }
}

/// Lightweight Markdown: renders block structure line by line with inline styling.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4)
                case .code(let text):
                    Text(text)
                        .font(.callout.monospaced())
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                case .bullet(let indent, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .paragraph(let text):
                    inline(text)
                case .image(let alt, let url):
                    TicketImage(alt: alt, url: url)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private enum Block {
        case heading(Int, String)
        case code(String)
        case bullet(Int, String, String)
        case paragraph(String)
        case image(String, URL)
    }

    /// A line that is only an image: `![alt](url)` or GitHub's `<img src="url">`.
    private static func image(in line: String) -> (String, URL)? {
        if let match = line.wholeMatch(of: /!\[([^\]]*)\]\((\S+?)(?:\s+"[^"]*")?\)/),
           let url = URL(string: String(match.2)), url.scheme?.hasPrefix("http") == true {
            return (String(match.1), url)
        }
        if let match = line.wholeMatch(of: /<img\b[^>]*\bsrc="([^"]+)"[^>]*\/?>/),
           let url = URL(string: String(match.1)), url.scheme?.hasPrefix("http") == true {
            let alt = line.firstMatch(of: /\balt="([^"]*)"/).map { String($0.1) } ?? ""
            return (alt, url)
        }
        return nil
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        // HTML comments are invisible on GitHub (agents keep routing data in them), so drop them.
        let visible = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        for raw in visible.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[hashes] == " " {
                flush()
                result.append(.heading(line.distance(from: line.startIndex, to: hashes), String(line[line.index(after: hashes)...])))
                continue
            }
            if let (alt, url) = Self.image(in: line) {
                flush()
                result.append(.image(alt, url))
                continue
            }
            let indent = raw.prefix { $0 == " " }.count / 2
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flush()
                result.append(.bullet(indent, line.hasPrefix("- [ ]") ? "☐" : "☑", String(line.dropFirst(6))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                result.append(.bullet(indent, "•", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                result.append(.bullet(indent, String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return result
    }
}
