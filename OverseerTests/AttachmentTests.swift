import Testing
import Foundation
@testable import Overseer

struct AttachmentTests {
    @Test func imagesEmbedAndFilesLink() {
        let url = URL(string: "https://uploads.linear.app/a/b")!
        #expect(Attachment(data: Data(), filename: "shot.png").markdown(for: url) == "![shot.png](https://uploads.linear.app/a/b)")
        #expect(Attachment(data: Data(), filename: "log.txt").markdown(for: url) == "[log.txt](https://uploads.linear.app/a/b)")
    }

    @Test func mimeTypeFromExtension() {
        #expect(Attachment(data: Data(), filename: "a.PNG").mimeType == "image/png")
        #expect(Attachment(data: Data(), filename: "a.pdf").mimeType == "application/pdf")
        #expect(Attachment(data: Data(), filename: "noext").mimeType == "application/octet-stream")
    }

    @Test func placeholderBlocksSending() {
        let text = "Before\n\(Attachment.placeholder(for: "Pasted image.png"))\nAfter"
        #expect(Attachment.isUploading(text))
        #expect(!Attachment.isUploading("![Uploading notes](https://example.com/x.png)"))
    }
}
