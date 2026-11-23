import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Composer states and the undelivered bubble, light and dark, at Mac sizes. The composer has
/// a real text field and glass, which `ImageRenderer` cannot draw, so these render a hosting
/// view in an offscreen window (`Snapshot.assertHosted`).
@MainActor
final class ComposerSnapshotTests: XCTestCase {
    static let width: CGFloat = 460

    private func composer(_ bar: ComposerBar) -> some View {
        bar.padding(.vertical, 12)
    }

    static let photo = OutgoingAttachment(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, kind: .image,
                                          data: FixtureMessages.placeholderPNG, mime: "image/png", filename: "Photo.png", pixelWidth: 4, pixelHeight: 3)
    static let pdf = OutgoingAttachment(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, kind: .file,
                                        data: Data(count: 48_000), mime: "application/pdf", filename: "Itinerary.pdf")
    static let levels: [Double] = (0..<120).map { (i: Int) -> Double in
        let x = Double(i)
        let a: Double = abs(sin(x * 0.37))
        let b: Double = 0.5 + 0.5 * abs(cos(x * 0.11))
        return 0.15 + 0.8 * a * b
    }

    func testComposerEmpty() {
        Snapshot.assertHosted(composer(ComposerBar(network: .whatsapp, canSend: true)), named: "composerEmpty", width: Self.width)
    }

    func testComposerWithText() {
        Snapshot.assertHosted(composer(ComposerBar(network: .telegram, canSend: true, draft: "On my way, see you at 7")), named: "composerWithText", width: Self.width)
    }

    func testComposerWithAttachmentPreviews() {
        Snapshot.assertHosted(composer(ComposerBar(network: .whatsapp, canSend: true, draft: "Tickets attached", attachments: [Self.photo, Self.pdf])),
                              named: "composerAttachmentPreview", width: Self.width)
    }

    /// A file dragged over the conversation (Finder, Photos, Safari, the screenshot thumbnail):
    /// the field shows the drop-target ring; the drop lands as a preview like "+ → Files".
    func testComposerDropTarget() {
        Snapshot.assertHosted(composer(ComposerBar(network: .imessage, canSend: true, dropInbox: ComposerDropInbox(isTargeted: true))),
                              named: "composerDropTarget", width: Self.width)
        Snapshot.assertHosted(composer(ComposerBar(network: .imessage, canSend: true, dropInbox: ComposerDropInbox(isTargeted: true),
                                                   attachments: [Self.photo])),
                              named: "composerDropTargetWithPreview", width: Self.width)
    }

    func testComposerRecording() {
        let recorder = VoiceRecorder.preview(phase: .recording, levels: Self.levels, elapsed: 7.4)
        Snapshot.assertHosted(composer(ComposerBar(network: .whatsapp, canSend: true, recorder: recorder)), named: "composerRecording", width: Self.width)
    }

    func testComposerRecorded() {
        let recorder = VoiceRecorder.preview(phase: .recorded, levels: Self.levels, elapsed: 12.2)
        Snapshot.assertHosted(composer(ComposerBar(network: .whatsapp, canSend: true, recorder: recorder)), named: "composerRecorded", width: Self.width)
    }

    func testComposerDisabled() {
        Snapshot.assertHosted(composer(ComposerBar(network: .imessage, canSend: false)), named: "composerDisabled", width: Self.width)
        XCTAssertEqual(ComposerBar.disabledPlaceholder(for: .imessage), "iMessage • Read Only")
        XCTAssertEqual(ComposerBar.disabledPlaceholder(for: .sms), "Text Message • Read Only")
    }

    func testFailedBubbleShowsNotDelivered() {
        var m = FixtureMessages.message(id: PendingSend.messageID(for: "c1"), outgoing: true, at: Date(timeIntervalSince1970: 1_800_000_000),
                                        text: "Running 10 minutes late", delivery: "failed")
        m.deliveryError = "The network couldn't deliver it."
        let row = TranscriptRowView(row: .message(m, .single, showSenderName: false, showAvatar: false),
                                    context: TranscriptRowContext(isGroup: false, spacingAbove: 0))
        Snapshot.assert(row, named: "failedBubbleNotDelivered")
    }

    func testSendingCaption() {
        let m = FixtureMessages.message(id: PendingSend.messageID(for: "c2"), outgoing: true, at: Date(timeIntervalSince1970: 1_800_000_000),
                                        text: "Sending this now", delivery: "pending")
        let rows: [TranscriptRow] = [.message(m, .single, showSenderName: false, showAvatar: false)]
        XCTAssertEqual(Receipt.forLast(rows)?.receipt.text, "Sending…")
        let row = TranscriptRowView(row: rows[0], context: TranscriptRowContext(isGroup: false, spacingAbove: 0, receipt: Receipt.forLast(rows)?.receipt))
        Snapshot.assert(row, named: "pendingBubbleSending")
    }
}

