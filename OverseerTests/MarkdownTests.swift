import Foundation
import Testing
@testable import Overseer

@MainActor
struct MarkdownTests {
    private let linear = "https://uploads.linear.app/w/a/b"
    private let github = "https://github.com/user-attachments/assets/1b660ad0-0dc6-49fd-81a6-bbd50826abe0"

    @Test func imageOnItsOwnLine() {
        #expect(MarkdownText.blocks(of: "![shot.png](\(linear))") == [.image("shot.png", URL(string: linear)!)])
        #expect(MarkdownText.blocks(of: "<img width=\"955\" height=\"846\" alt=\"Image\" src=\"\(github)\" />")
            == [.image("Image", URL(string: github)!)])
    }

    @Test func severalImagesOnOneLine() {
        let blocks = MarkdownText.blocks(of: "![iphone.png](\(linear)/1) ![ipad.png](\(linear)/2)")
        #expect(blocks == [.image("iphone.png", URL(string: "\(linear)/1")!), .image("ipad.png", URL(string: "\(linear)/2")!)])
    }

    @Test func imageInsideText() {
        let blocks = MarkdownText.blocks(of: "Before ![a](\(linear)) after")
        #expect(blocks == [.paragraph("Before"), .image("a", URL(string: linear)!), .paragraph("after")])
    }

    @Test func imageWrappedInHTML() {
        let blocks = MarkdownText.blocks(of: "<p align=\"center\"><img src=\"\(github)\"></p>")
        #expect(blocks == [.image("", URL(string: github)!)])
    }

    @Test func uploadedFilesOnTheirOwnLine() {
        #expect(MarkdownText.blocks(of: github) == [.attachment(URL(string: github)!.lastPathComponent, URL(string: github)!)])
        #expect(MarkdownText.blocks(of: "[Recording.MP4](\(linear))") == [.attachment("Recording.MP4", URL(string: linear)!)])
    }

    @Test func ordinaryLinksStayText() {
        #expect(MarkdownText.blocks(of: "[docs](https://example.com/a)") == [.paragraph("[docs](https://example.com/a)")])
        #expect(MarkdownText.blocks(of: "https://example.com/a") == [.paragraph("https://example.com/a")])
    }

    @Test func recognisesVideos() {
        var mp4 = Data([0, 0, 0, 0x20]); mp4.append(Data("ftypisom".utf8)); mp4.append(Data(count: 8))
        #expect(TicketAttachment.isVideo(mp4))
        #expect(!TicketAttachment.isVideo(Data("\u{89}PNG\r\n\u{1a}\n........".utf8)))
    }
}
