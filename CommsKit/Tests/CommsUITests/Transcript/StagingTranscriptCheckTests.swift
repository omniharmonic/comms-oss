// The Mac transcript host (NSTableView) is AppKit: these tests are macOS-only.
#if os(macOS)
import AppKit
import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import SwiftUI
import XCTest

/// Task 17 step 4 against the staging rooms as the Comms server normalizes them
/// (`FixtureBackend.staging()`, dumped from the staging Synapse with the server's own
/// normalizer). `TRANSCRIPT_RENDER_DIR=/some/dir` also writes a PNG of each transcript
/// (top and bottom) for a by-eye check.
@MainActor
final class StagingTranscriptCheckTests: XCTestCase {
    private func stores() async throws -> [TimelineStore] {
        let backend = try FixtureBackend.staging()
        let page = try await backend.threads(CommsThreadQuery())
        var out: [TimelineStore] = []
        for t in page.threads {
            let store = TimelineStore(backend: backend, threadID: t.id, thread: t)
            await store.loadLatest()
            out.append(store)
        }
        return out
    }

    private func messages(_ s: TimelineStore) -> [(CommsMessage, CommsCore.RunPosition, Bool)] {
        s.rows.compactMap { if case .message(let m, let p, _, let avatar) = $0 { (m, p, avatar) } else { nil } }
    }

    func testSeededRoomsShowWhatTheBriefChecks() async throws {
        let all = try await stores()
        XCTAssertEqual(all.count, 3)
        let alice = try XCTUnwrap(all.first { $0.thread?.title == "Alice Example" }, "room (a) is titled Alice Example")
        XCTAssertEqual(alice.thread?.networks, [.whatsapp], "with a WhatsApp badge")
        XCTAssertEqual(alice.thread?.kind, .dm)

        for s in all {
            let ms = messages(s)
            let name = s.thread?.title ?? "?"
            XCTAssertNil(s.sourceError, name)
            XCTAssertTrue(ms.contains { $0.0.editedAt != nil && !$0.0.redacted }, "\(name): the edit is marked Edited")
            XCTAssertTrue(ms.contains { $0.0.reactions.map(\.count).reduce(0, +) >= 2 }, "\(name): reactions with counts")
            XCTAssertFalse(ms.contains { m in (m.0.body?.plain ?? "").contains("<script") || (m.0.body?.plain ?? "").contains("alert(") },
                           "\(name): <script> is absent")
            XCTAssertTrue(ms.contains { $0.0.body?.jumboEmoji == true && $0.0.body?.plain == "😀🎉🚀" }, "\(name): the 3-emoji message is jumbo")
            XCTAssertTrue(ms.contains { ($0.0.body?.plain.count ?? 0) >= 64_000 },
                          "\(name): the long message is there, in full")
            XCTAssertTrue(ms.contains { $0.0.redacted }, "\(name): the redaction shows as unsent")
        }

        let crew = try XCTUnwrap(all.first { $0.thread?.title == "Trail Crew" })
        XCTAssertTrue(crew.isGroup)
        // Every incoming run ends in a row that shows the sender's avatar.
        let incoming = messages(crew).filter { !$0.0.sender.isSelf && !$0.0.redacted }
        XCTAssertFalse(incoming.isEmpty)
        for (m, p, avatar) in incoming where p.hasTail {
            XCTAssertTrue(avatar, "run ending in \(m.id) shows \(m.sender.name)'s avatar")
        }
    }

    func testRenderStagingTranscripts() async throws {
        guard let dir = ProcessInfo.processInfo.environment["TRANSCRIPT_RENDER_DIR"] else { throw XCTSkip("set TRANSCRIPT_RENDER_DIR to render") }
        for store in try await stores() {
            let root = TranscriptView(store: store)
                .environment(\.mediaLoader, .placeholder)
                .frame(width: 640, height: 900)
                .background(Color.white)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded() }
            let slug = (store.thread?.title ?? store.threadID).replacingOccurrences(of: " ", with: "-")
            try snapshot(host, to: URL(fileURLWithPath: dir).appendingPathComponent("\(slug)-bottom.png"))
            if let table = findTable(in: host) {
                table.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: -(table.enclosingScrollView?.contentInsets.top ?? 0)))
                for _ in 0..<5 { try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded() }
                try snapshot(host, to: URL(fileURLWithPath: dir).appendingPathComponent("\(slug)-top.png"))
            }
            window.close()
        }
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for v in view.subviews { if let t = findTable(in: v) { return t } }
        return nil
    }

    private func snapshot(_ view: NSView, to url: URL) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
#endif
