import SwiftUI

/// Files a new issue in the Linear board's current team.
struct LinearNewTicketView: View {
    @Environment(LinearStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var stateID = ""
    @State private var priority = 0
    @State private var submitting = false
    @State private var uploadError: String?
    @FocusState private var titleFocused: Bool

    private static let template = """
    ## Goal


    ## Context


    ## Acceptance criteria
    - [ ]
    """

    /// Linear's priorities, in its menu order.
    private static let priorities = [(0, "No priority"), (1, "Urgent"), (2, "High"), (3, "Medium"), (4, "Low")]

    private var openStates: [LinearState] { store.states.filter { !$0.isClosed } }
    private var state: LinearState? { store.states.first { $0.id == stateID } }
    private var canSubmit: Bool {
        store.team != nil && state != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty && !submitting
            && !Attachment.isUploading(details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Linear Ticket").font(.title2.weight(.semibold))

            Form {
                LabeledContent("Team", value: store.team?.name ?? "—")
                TextField("Title", text: $title, prompt: Text("What should be done?"))
                    .focused($titleFocused)
                Picker("Status", selection: $stateID) {
                    if stateID.isEmpty { Text("Choose…").tag("") }
                    ForEach(openStates) { state in
                        Label {
                            Text(state.name)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: state.color))
                        }
                        .tag(state.id)
                    }
                }
                Picker("Priority", selection: $priority) {
                    ForEach(Self.priorities, id: \.0) { Text($0.1).tag($0.0) }
                }
            }

            Text("Description").font(.callout).foregroundStyle(.secondary)
            AttachmentEditor(text: $details, upload: { try await store.upload($0) },
                             onError: { uploadError = $0 })
                .frame(minHeight: 260)

            HStack {
                if let uploadError {
                    Label(uploadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(state.map { "File in \($0.name)" } ?? "File Ticket") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            details = Self.template
            stateID = store.defaultNewState?.id ?? ""
            titleFocused = true
        }
    }

    private func submit() {
        guard let state else { return }
        submitting = true
        let body = details == Self.template ? "" : details
        Task {
            let ok = await store.createIssue(title: title.trimmingCharacters(in: .whitespaces), description: body,
                                             state: state, priority: priority)
            submitting = false
            if ok { dismiss() }
        }
    }
}
