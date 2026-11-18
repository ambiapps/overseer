import SwiftUI

struct NewTicketView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastRepo") private var lastRepo = ""

    @State private var repoName = ""
    @State private var title = ""
    @State private var details = ""
    @State private var toDo = true
    @State private var submitting = false
    @State private var uploadError: String?
    @FocusState private var titleFocused: Bool

    private static let template = """
    ## Goal


    ## Context


    ## Acceptance criteria
    - [ ]
    """

    private var repo: Repo? { store.repo(named: repoName) }
    private var canSubmit: Bool {
        repo != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty && !submitting
            && !Attachment.isUploading(details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Ticket").font(.title2.weight(.semibold))

            Form {
                Picker("Repository", selection: $repoName) {
                    if repoName.isEmpty { Text("Choose…").tag("") }
                    ForEach(store.repos) { Text($0.name).tag($0.nameWithOwner) }
                }
                TextField("Title", text: $title, prompt: Text("What should be done?"))
                    .focused($titleFocused)
            }

            Text("Description").font(.callout).foregroundStyle(.secondary)
            AttachmentEditor(text: $details, upload: { attachment in
                guard let repo else { throw GitHubError.graphQL("Choose a repository before attaching files.") }
                return try await store.upload(attachment, repo: repo.nameWithOwner)
            }, onError: { uploadError = $0 })
                .frame(minHeight: 260)

            Picker("Put in", selection: $toDo) {
                Text("To Do: agents pick it up now").tag(true)
                Text("Backlog").tag(false)
            }
            .pickerStyle(.radioGroup)

            HStack {
                if let uploadError {
                    Label(uploadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(toDo ? "File in To Do" : "File in Backlog") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            details = Self.template
            if store.repo(named: lastRepo) != nil { repoName = lastRepo }
            else if let name = store.repoFilter { repoName = name }
            titleFocused = true
        }
    }

    private func submit() {
        guard let repo else { return }
        submitting = true
        lastRepo = repo.nameWithOwner
        let body = details == Self.template ? "" : details
        Task {
            let ok = await store.createTicket(repo: repo, title: title.trimmingCharacters(in: .whitespaces), body: body,
                                              status: toDo ? Store.todoStatus : Store.backlogStatus)
            submitting = false
            if ok { dismiss() }
        }
    }
}
