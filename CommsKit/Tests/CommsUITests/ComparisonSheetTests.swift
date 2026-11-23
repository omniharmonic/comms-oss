import CommsUI
import CoreGraphics
import Foundation
import PrismModels
import SwiftUI
import XCTest

/// Renders design/refs/comms-bubbles-v0.png: a small Comms transcript at Mac sizes next to
/// the matching crop of Apple's Mac guide image, for a human fidelity check.
/// Runs only with RENDER_COMPARISON=1 (it writes into design/refs).
@MainActor
final class ComparisonSheetTests: XCTestCase {
    typealias M = MessageFactory

    func testRenderComparisonSheet() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_COMPARISON"] == "1", "set RENDER_COMPARISON=1")
        let m = BubbleMetrics.mac
        let transcript = VStack(spacing: 0) {
            MessageBubble(message: M.message(id: "$1", text: "Did you see the trail map?"), position: .first, isGroup: false)
            MessageBubble(message: M.message(id: "$2", text: "The north loop is closed this week"), position: .middle, isGroup: false)
                .padding(.top, m.gapSameSender)
            MessageBubble(message: M.message(id: "$3", text: "Give us a clue!", reactions: [.init(key: "😂", mine: true)]), position: .last, isGroup: false)
                .padding(.top, m.gapSameSender)
            MessageBubble(message: M.message(id: "$4", outgoing: true, text: "They're on a secret mission..."), position: .first, isGroup: false)
                .padding(.top, m.gapSenderChange)
            MessageBubble(message: M.message(id: "$5", outgoing: true, text: "Back by six"), position: .last, isGroup: false)
                .padding(.top, m.gapSameSender)
            MessageBubble(message: M.message(id: "$6", attachments: [M.image(w: 800, h: 600)]), position: .single, isGroup: false)
                .padding(.top, m.gapSenderChange)
            MessageBubble(message: M.message(id: "$7", outgoing: true, text: "https://example.org/trails", linkPreviews: [[
                "url": "https://example.org/trails", "title": "Trail conditions this weekend", "siteName": "example.org", "imageToken": "tok_og",
            ]]), position: .single, isGroup: false)
                .padding(.top, m.gapSenderChange)
            MessageBubble(message: M.message(id: "$8", text: "Ha, nice", reactions: [
                .init(key: "❤️", mine: true), .init(key: "👍", count: 2), .init(key: "‼️"),
            ]), position: .single, isGroup: false)
                .padding(.top, m.gapSenderChange)
            MessageBubble(message: M.message(id: "$9", outgoing: true, text: "😂", jumboEmoji: true), position: .single, isGroup: false)
                .padding(.top, m.gapSenderChange)
        }
        let width: CGFloat = 552 // the transcript column of the Mac guide image (x 262–814)
        let ours = try XCTUnwrap(Snapshot.render(transcript, width: width, scheme: .light))

        let refURL = TokensTests.repo.appendingPathComponent("docs/research/refs/macos26-guide-window-sidebar-transcript.png")
        let ref = try XCTUnwrap(Snapshot.readPNG(refURL))
        // Transcript area below the photo (bubbles, tapback, "Read"), at the guide's ≈ 1 px/pt.
        let crop = try XCTUnwrap(ref.cropping(to: CGRect(x: 262, y: 400, width: 552, height: 175)))
        // The guide PNG is ≈ 0.81 px/pt (CALIBRATION, R19): its 23 px single-line bubble is
        // 28.5 pt. Scale it to the same 2× as our render so the two compare like for like.
        let k = 2 * Double(Tokens.calibration.macBubbleHeight) / 23.0
        let refW = Int(Double(crop.width) * k), refH = Int(Double(crop.height) * k)

        let gap = 40, label = 44
        let W = ours.width + gap + refW, H = max(ours.height, refH) + label
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        ctx.draw(ours, in: CGRect(x: 0, y: H - label - ours.height, width: ours.width, height: ours.height))
        ctx.draw(crop, in: CGRect(x: ours.width + gap, y: H - label - refH, width: refW, height: refH))
        let caption = NSAttributedString(string: "Comms v0 (Mac sizes, @2x)                                                         Apple Messages, macOS 26 guide crop (0.81 px/pt, scaled to @2x)",
                                         attributes: [.font: CTFontCreateUIFontForLanguage(.system, 22, nil)!])
        let line = CTLineCreateWithAttributedString(caption)
        ctx.textPosition = CGPoint(x: 12, y: H - label + 12)
        CTLineDraw(line, ctx)
        let sheet = try XCTUnwrap(ctx.makeImage())
        try Snapshot.writePNG(sheet, to: TokensTests.repo.appendingPathComponent("design/refs/comms-bubbles-v0.png"))
    }
}
