import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file to upload into a ticket: pasted, dropped or picked.
nonisolated struct Attachment: Sendable {
    let data: Data
    let filename: String
    let mimeType: String

    /// Linear and GitHub both cap uploads well above this; it keeps base64 request bodies sane.
    static let maxBytes = 25 * 1024 * 1024

    var isImage: Bool { mimeType.hasPrefix("image/") }

    /// The Markdown that shows the uploaded file: inline for images, a link otherwise.
    func markdown(for url: URL) -> String {
        let label = filename.replacingOccurrences(of: "]", with: "")
        return isImage ? "![\(label)](\(url.absoluteString))" : "[\(label)](\(url.absoluteString))"
    }

    static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    init(data: Data, filename: String, mimeType: String? = nil) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType ?? Self.mimeType(forExtension: (filename as NSString).pathExtension)
    }

    init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        self.init(data: data, filename: fileURL.lastPathComponent)
    }

    /// Files or image data on a pasteboard (a Finder copy, a screenshot, an image copied from a browser).
    /// Empty when it only holds text, so a normal paste goes ahead.
    static func from(_ pasteboard: NSPasteboard) -> [Result<Attachment, Error>] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            return files.map { url in Result { try Attachment(fileURL: url) } }
        }
        if let png = pasteboard.data(forType: .png) {
            return [.success(Attachment(data: png, filename: pastedName("png"), mimeType: "image/png"))]
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.success(Attachment(data: png, filename: pastedName("png"), mimeType: "image/png"))]
        }
        return []
    }

    private static func pastedName(_ ext: String) -> String {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.omitted))
        return "Pasted image \(stamp).\(ext)"
    }
}

extension Attachment {
    /// The text that stands in for a file while it uploads.
    static func placeholder(for filename: String) -> String {
        "![Uploading \(filename.replacingOccurrences(of: "]", with: ""))…](\(UUID().uuidString))"
    }

    /// Whether `text` still holds an upload placeholder, so it isn't ready to send.
    static func isUploading(_ text: String) -> Bool {
        text.contains(/!\[Uploading [^\]]*…\]\([0-9A-F-]{36}\)/)
    }
}

/// Uploads an attachment and returns the URL the ticket's Markdown should point at.
typealias AttachmentUploader = @MainActor (Attachment) async throws -> URL

// MARK: - Editor

/// A Markdown text editor that uploads pasted, dropped or attached files and images,
/// inserting a link to each at the cursor.
struct AttachmentEditor: View {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var placeholder: String?
    let upload: AttachmentUploader
    /// Reports a failed upload; the editor drops its placeholder.
    var onError: (String) -> Void = { _ in }

    @State private var controller = AttachmentEditorController()

    var body: some View {
        AttachmentTextView(text: $text, font: font, controller: controller, upload: upload, onError: onError)
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .overlay(alignment: .topLeading) {
                if let placeholder, text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    if controller.uploading > 0 { ProgressView().controlSize(.small) }
                    Button { controller.pickFiles() } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.borderless)
                        .help("Attach files or images (you can also paste or drop them)")
                }
                .padding(8)
            }
    }
}

@Observable
final class AttachmentEditorController {
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored var upload: AttachmentUploader?
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    /// Uploads in flight.
    var uploading = 0

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        insert(panel.urls.map { url in Result { try Attachment(fileURL: url) } })
    }

    /// Puts a placeholder at the cursor for each attachment, then swaps in its link once uploaded.
    func insert(_ attachments: [Result<Attachment, Error>]) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        for result in attachments {
            let attachment: Attachment
            switch result {
            case .failure(let error):
                onError("Couldn't read the file: \(error.localizedDescription)")
                continue
            case .success(let value):
                attachment = value
            }
            guard attachment.data.count <= Attachment.maxBytes else {
                onError("\(attachment.filename) is larger than 25 MB.")
                continue
            }
            guard let upload else { continue }
            let token = Attachment.placeholder(for: attachment.filename)
            let needsBreak = !(textView.string as NSString).substring(to: textView.selectedRange().location)
                .hasSuffix("\n") && textView.selectedRange().location > 0
            replace(textView.selectedRange(), with: (needsBreak ? "\n" : "") + token + "\n", in: textView)
            uploading += 1
            Task {
                defer { uploading -= 1 }
                do {
                    let url = try await upload(attachment)
                    swap(token, for: attachment.markdown(for: url))
                } catch {
                    swap(token + "\n", for: "")
                    swap(token, for: "")
                    onError("Couldn't upload \(attachment.filename): \(error.localizedDescription)")
                }
            }
        }
    }

    private func swap(_ token: String, for replacement: String) {
        guard let textView else { return }
        let range = (textView.string as NSString).range(of: token)
        guard range.location != NSNotFound else { return }
        let selection = textView.selectedRange()
        replace(range, with: replacement, in: textView)
        // Keep the cursor where the user left it.
        if selection.location >= range.location + range.length {
            let shift = (replacement as NSString).length - range.length
            textView.setSelectedRange(NSRange(location: max(0, selection.location + shift), length: selection.length))
        }
    }

    /// Edits through the text system, so undo works and the binding hears about it.
    private func replace(_ range: NSRange, with string: String, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }
}

private struct AttachmentTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let controller: AttachmentEditorController
    let upload: AttachmentUploader
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PastingTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! PastingTextView
        textView.controller = controller
        textView.delegate = context.coordinator
        textView.font = font
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.string = text
        controller.textView = textView
        controller.upload = upload
        controller.onError = onError
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        // The closures capture view state (the chosen repo or team), so keep the latest.
        controller.upload = upload
        controller.onError = onError
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// `NSTextView` makes its scrollable instance from the class it's called on.
private final class PastingTextView: NSTextView {
    weak var controller: AttachmentEditorController?

    override func paste(_ sender: Any?) {
        let attachments = Attachment.from(.general)
        if attachments.isEmpty { super.paste(sender) } else { controller?.insert(attachments) }
    }

    override func pasteAsPlainText(_ sender: Any?) { super.paste(sender) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let attachments = Attachment.from(sender.draggingPasteboard)
        guard !attachments.isEmpty else { return super.performDragOperation(sender) }
        // Drop at the point under the cursor.
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        controller?.insert(attachments)
        return true
    }
}

// MARK: - Showing uploaded images

/// Fetches an image's bytes, adding whatever sign-in the host needs (private uploads aren't public).
typealias ImageFetcher = @MainActor (URL) async throws -> Data

extension EnvironmentValues {
    @Entry var imageFetcher: ImageFetcher = { url in try await URLSession.shared.data(from: url).0 }
}

/// An image referenced from a ticket's Markdown.
struct TicketImage: View {
    @Environment(\.imageFetcher) private var fetch
    @Environment(\.openURL) private var openURL
    let alt: String
    let url: URL

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(image.size.width, 560), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { openURL(url) }
                    .help(alt)
            } else if failed {
                Link(destination: url) { Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo") }
            } else {
                ProgressView().controlSize(.small).frame(height: 40)
            }
        }
        .task(id: url) {
            do {
                let data = try await fetch(url)
                if let loaded = NSImage(data: data) { image = loaded } else { failed = true }
            } catch {
                failed = true
            }
        }
    }
}
