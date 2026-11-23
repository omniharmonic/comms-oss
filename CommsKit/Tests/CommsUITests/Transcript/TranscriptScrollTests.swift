// The Mac transcript host (NSTableView) is AppKit: these tests are macOS-only.
#if os(macOS)
import AppKit
import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import XCTest

@MainActor
final class TranscriptScrollTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func host(width: CGFloat = 480, height: CGFloat = 800) -> TranscriptTableController {
        let c = TranscriptTableController()
        c.mediaLoader = .placeholder
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = c.view
        w.contentView?.layoutSubtreeIfNeeded()
        window = w
        return c
    }

    private func visible(_ c: TranscriptTableController) -> [String: Double] {
        Dictionary(c.visibleRows().map { ($0.id, Double($0.y)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The spike's harness as a test: scroll toward older history at 15 pt per tick (1800 pt/s
    /// at 120 Hz) starting from the newest 100 messages; each time the controller asks for
    /// older history, prepend 50 on that tick. 10 prepends.
    private func runPrependHarness(restoresAnchor: Bool) -> (meter: JumpMeter, inserts: Int) {
        let all = SyntheticHistory.messages(600)
        var shown = 100
        let c = host()
        c.restoresAnchor = restoresAnchor
        var needsOlder = false
        c.onNeedsOlder = { needsOlder = true }
        c.apply(SyntheticHistory.rows(all.suffix(shown)))
        c.setCanLoadOlder(true)
        needsOlder = false // the first page is within two screens of its top: start from the bottom
        c.scrollToBottom()

        var meter = JumpMeter()
        meter.sample(visible(c), anchorPosition: { _ in nil }, scrollDelta: 0, insertedThisTick: false)
        var inserts = 0
        var ticks = 0
        let clip = c.scrollView.contentView
        while inserts < 10, ticks < 20_000 {
            ticks += 1
            let old = clip.bounds.origin.y
            c.scroll(toY: old - 15)
            let delta = clip.bounds.origin.y - old
            var inserted = false
            if needsOlder, shown < all.count {
                needsOlder = false
                shown = min(all.count, shown + 50)
                c.apply(SyntheticHistory.rows(all.suffix(shown)))
                c.setCanLoadOlder(shown < all.count)
                inserts += 1
                inserted = true
            }
            meter.sample(visible(c), anchorPosition: { c.screenY(ofRowID: $0).map(Double.init) }, scrollDelta: Double(delta), insertedThisTick: inserted)
            if delta == 0, !inserted, !needsOlder { break } // reached the top with nothing left
        }
        return (meter, inserts)
    }

    func testPrependTenPagesOfFiftyNeverMovesWhatIsOnScreen() {
        let (meter, inserts) = runPrependHarness(restoresAnchor: true)
        print("TRANSCRIPT_JUMP cachedHeights+anchor \(meter.summary(inserts: inserts))")
        XCTAssertEqual(inserts, 10)
        XCTAssertTrue(meter.valid, "every insert tick compared at least one row")
        XCTAssertGreaterThanOrEqual(meter.minComparedAtInsert, 1)
        XCTAssertEqual(meter.insertSamples, 10)
        XCTAssertEqual(meter.maxJump, 0, accuracy: 0.001)
        XCTAssertEqual(meter.maxJumpAtInsert, 0, accuracy: 0.001)
    }

    /// Negative control: the same run without the anchor restore must register big jumps,
    /// proving the meter would catch a broken restore.
    func testNegativeControlMeterDetectsMissingAnchorRestore() {
        let (meter, inserts) = runPrependHarness(restoresAnchor: false)
        print("TRANSCRIPT_JUMP negative-control(no restore) \(meter.summary(inserts: inserts))")
        XCTAssertGreaterThanOrEqual(inserts, 1)
        XCTAssertTrue(meter.valid)
        XCTAssertGreaterThan(meter.maxJumpAtInsert, 500, "an unanchored prepend of 50 rows moves the content by thousands of points")
    }

    func testWidthChangeKeepsTheAnchorAndRemeasures() throws {
        let all = SyntheticHistory.messages(200)
        let c = host(width: 600)
        c.apply(SyntheticHistory.rows(all))
        let clip = c.scrollView.contentView
        c.scroll(toY: clip.bounds.origin.y / 2) // mid-history, not pinned to the bottom
        let before = try XCTUnwrap(c.visibleRows().first)
        let longID = try XCTUnwrap(c.rows.indices.first { i in
            if case .message(let m, _, _, _) = c.rows[i] { return (m.body?.plain.count ?? 0) > 200 }
            return false
        })
        let wideHeight = c.tableView.rect(ofRow: longID).height

        for width in [420.0, 340.0, 520.0] {
            window?.setContentSize(NSSize(width: width, height: 800))
            window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(c.contentWidth, width, accuracy: 0.5)
            let y = try XCTUnwrap(c.screenY(ofRowID: before.id))
            XCTAssertEqual(y, before.y, accuracy: 0.5, "the top visible row stays put at width \(width)")
        }
        c.flushPendingRemeasure() // 200 rows: off-screen rows are re-measured once the width settles
        XCTAssertGreaterThan(c.tableView.rect(ofRow: longID).height, wideHeight, "a long message wraps to more lines when narrower")
    }

    func testWidthChangeAtTheBottomStaysAtTheBottom() {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(80)))
        XCTAssertEqual(c.distanceFromBottom, 0, accuracy: 0.5)
        window?.setContentSize(NSSize(width: 340, height: 800))
        window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(c.distanceFromBottom, 0, accuracy: 0.5)
    }

    func testNewMessageAtTheBottomStaysPinnedAndHeightsAreCached() {
        let all = SyntheticHistory.messages(61)
        let c = host()
        c.apply(SyntheticHistory.rows(all.prefix(60)))
        let measured = c.measureCount
        c.apply(SyntheticHistory.rows(all))
        XCTAssertEqual(c.distanceFromBottom, 0, accuracy: 0.5, "a new message keeps the bottom in view")
        XCTAssertLessThanOrEqual(c.measureCount - measured, 4, "only the new and the re-positioned rows are measured again")
    }

    func testFarFromBottomIsReportedAfterAScreen() {
        let c = host()
        var far: [Bool] = []
        c.onFarFromBottomChange = { far.append($0) }
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(200)))
        let clip = c.scrollView.contentView
        c.scroll(toY: clip.bounds.origin.y - clip.bounds.height * 0.5)
        XCTAssertEqual(far, [], "half a screen up is not far")
        c.scroll(toY: clip.bounds.origin.y - clip.bounds.height)
        XCTAssertEqual(far, [true])
        c.scrollToBottom()
        XCTAssertEqual(far, [true, false])
    }

    /// VoiceOver walks rows in table order: oldest first, newest last, the same as on screen.
    func testAccessibilityOrderIsOldestFirstNewestLast() throws {
        let c = host()
        let messages = SyntheticHistory.messages(12)
        c.apply(SyntheticHistory.rows(messages))
        c.scroll(toY: -c.scrollView.contentInsets.top)
        c.tableView.layoutSubtreeIfNeeded()

        // (`accessibilityRows()` bridges through a typed Swift array and traps on the table's
        // private row elements, so read the attribute untyped.)
        let axRows = ((c.tableView.value(forKey: "accessibilityRows") as? NSArray) ?? []).compactMap { $0 as? NSObject }
        XCTAssertFalse(axRows.isEmpty)
        func attr(_ o: NSObject, _ a: NSAccessibility.Attribute) -> Any? { o.accessibilityAttributeValue(a) }
        let indexes = axRows.map { (attr($0, .index) as? NSNumber)?.intValue ?? -1 }
        XCTAssertEqual(indexes, Array(0..<axRows.count), "accessibility rows follow the transcript order, oldest first")
        // Screen coordinates grow upward: a later row is lower on screen.
        let tops = axRows.map { o -> CGFloat in
            let origin = (attr(o, .position) as? NSValue)?.pointValue ?? .zero
            let size = (attr(o, .size) as? NSValue)?.sizeValue ?? .zero
            return origin.y + size.height
        }
        XCTAssertEqual(tops, tops.sorted(by: >), "accessibility rows go top to bottom")

        // Each AX row leads (row → cell → hosting view) to the cell drawing that transcript row.
        // (SwiftUI builds the hosting view's own elements only for a live accessibility
        // client, so their labels are checked through MessageBubble's label function.)
        func hostingView(_ e: Any, depth: Int = 0) -> NSView? {
            guard let o = e as? NSObject, depth < 4 else { return nil }
            if let v = o as? NSView, String(describing: type(of: v)).hasPrefix("NSHostingView") { return v }
            for k in (attr(o, .children) as? NSArray) ?? [] { if let v = hostingView(k, depth: depth + 1) { return v } }
            return nil
        }
        let tableRows = try axRows.map { try XCTUnwrap(hostingView($0)).map { c.tableView.row(for: $0) } }
        XCTAssertEqual(tableRows, Array(0..<axRows.count), "AX row n hosts transcript row n")
        let spoken = c.rows.compactMap { row -> String? in
            if case .message(let m, _, _, _) = row { return MessageBubble.accessibilityLabel(for: m) }
            return nil
        }
        XCTAssertEqual(spoken.count, messages.count)
        for (label, m) in zip(spoken, messages) {
            XCTAssertTrue(label.contains(m.body?.plain.prefix(30) ?? ""), "message labels are read in send order")
        }
    }

    // MARK: Fix round 1

    /// What `TranscriptTable.updateNSViewController` does with the store.
    private func feed(_ c: TranscriptTableController, _ store: TimelineStore) {
        c.noteOlderLoads(store.olderLoadCount)
        c.apply(store.rows)
        c.setCanLoadOlder(store.hasMore && !store.isStalled)
    }

    private func msg(_ i: Int, text: String = "hello there") -> CommsMessage {
        FixtureMessages.message(id: String(format: "x%03d", i), threadID: "th_a", at: SyntheticHistory.start.addingTimeInterval(Double(i) * 60), text: text)
    }

    func testAStalledOlderLoadStopsPrefetchWithoutLoopingAndLoadEarlierResumes() async throws {
        var pages: [String?: CommsMessagePage] = [nil: FixtureMessages.page((10..<14).map { msg($0) }, before: "e1", hasMore: true)]
        for i in 1...25 { pages["e\(i)"] = FixtureMessages.page([], before: "e\(i + 1)", hasMore: true) }
        pages["e26"] = FixtureMessages.page([msg(1)], before: nil, hasMore: false)
        let backend = try FixtureBackend()
        backend.setMessagePages(pages, threadID: "th_a")
        let store = TimelineStore(backend: backend, threadID: "th_a")
        let c = host()
        var asks = 0
        c.onNeedsOlder = { asks += 1 }

        await store.loadLatest()
        feed(c, store)
        XCTAssertEqual(asks, 1, "a short first page is within two screens of the top")

        await store.loadOlder() // 21 pages of nothing: stalls
        feed(c, store)
        XCTAssertTrue(store.isStalled)
        for _ in 0..<50 { c.scroll(toY: c.scrollView.contentView.bounds.origin.y + 1); c.scroll(toY: c.scrollView.contentView.bounds.origin.y - 1) }
        XCTAssertEqual(asks, 1, "stalled: no automatic request, no loop")

        await store.loadOlder() // "Load Earlier Messages"
        feed(c, store)
        XCTAssertEqual(c.rows.compactMap { if case .message(let m, _, _, _) = $0 { m.id } else { nil } }.first, "x001")
        XCTAssertFalse(store.hasMore)
    }

    func testAnOlderLoadThatFailsReArmsPrefetchOnTheNextScroll() async throws {
        let backend = try FixtureBackend()
        backend.setMessagePages([
            nil: FixtureMessages.page((10..<14).map { msg($0) }, before: "c1", hasMore: true),
            "c1": FixtureMessages.page([msg(1)], before: nil, hasMore: false),
        ], threadID: "th_a")
        let store = TimelineStore(backend: backend, threadID: "th_a")
        let c = host()
        var asks = 0
        c.onNeedsOlder = { asks += 1 }
        await store.loadLatest()
        feed(c, store)
        XCTAssertEqual(asks, 1)

        backend.setMessagesError(CommsError.sourceUnavailable(network: .whatsapp))
        await store.loadOlder()
        feed(c, store)
        XCTAssertEqual(asks, 1, "re-armed, but not asking again on its own")
        c.scroll(toY: c.scrollView.contentView.bounds.origin.y + 1)
        XCTAssertEqual(asks, 2, "the next scroll asks again")
    }

    func testALiveMessageInTheSameUpdateAsAWidthChangeRemeasuresEveryRow() throws {
        let all = SyntheticHistory.messages(61)
        let c = host(width: 600)
        c.apply(SyntheticHistory.rows(all.prefix(60)))
        let clip = c.scrollView.contentView
        c.scroll(toY: clip.bounds.origin.y / 2)
        let anchor = try XCTUnwrap(c.visibleRows().first)

        // The width changes and a message arrives before the next layout pass.
        window?.setContentSize(NSSize(width: 380, height: 800))
        c.apply(SyntheticHistory.rows(all))
        window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(c.contentWidth, 380, accuracy: 0.5)
        for i in c.rows.indices {
            XCTAssertEqual(c.tableView.rect(ofRow: i).height, c.freshHeight(ofRow: i), accuracy: 0.5, "row \(i) is at the new width")
        }
        XCTAssertEqual(try XCTUnwrap(c.screenY(ofRowID: anchor.id)), anchor.y, accuracy: 0.5)
    }

    func testAnAnimatedWidthSweepMeasuresOnlyTheVisibleBandPerFrame() throws {
        let c = host(width: 640)
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(400)))
        let clip = c.scrollView.contentView
        c.scroll(toY: clip.bounds.origin.y / 2)
        let anchor = try XCTUnwrap(c.visibleRows().first)
        XCTAssertGreaterThan(c.rows.count, TranscriptTableController.bandOnlyAbove)

        var perFrame: [Int] = []
        var top = anchor
        for frame in 1...24 { // an inspector sliding in: 640 → 400 pt
            let before = c.measureCount
            window?.setContentSize(NSSize(width: 640 - 10 * CGFloat(frame), height: 800))
            window?.contentView?.layoutSubtreeIfNeeded()
            perFrame.append(c.measureCount - before)
            // The row at the top of the viewport stays put from frame to frame.
            XCTAssertEqual(try XCTUnwrap(c.screenY(ofRowID: top.id)), top.y, accuracy: 0.5, "frame \(frame)")
            top = try XCTUnwrap(c.visibleRows().first)
        }
        let band = c.tableView.rows(in: clip.bounds.insetBy(dx: 0, dy: -clip.bounds.height)).length
        print("TRANSCRIPT_SWEEP rows=\(c.rows.count) band=\(band) measuredPerFrame=\(perFrame)")
        XCTAssertLessThanOrEqual(perFrame.max() ?? 0, 2 * band, "each frame re-measures about the visible band (it moves as rows grow)")
        XCTAssertLessThan(perFrame.max() ?? 0, c.rows.count / 4)

        c.flushPendingRemeasure() // the width settled
        for i in c.rows.indices {
            XCTAssertEqual(c.tableView.rect(ofRow: i).height, c.freshHeight(ofRow: i), accuracy: 0.5, "row \(i) re-measured once settled")
        }
        XCTAssertEqual(try XCTUnwrap(c.screenY(ofRowID: top.id)), top.y, accuracy: 0.5, "the settle re-measure keeps the viewport")
    }

    func testASelfSenderChangeRedrawsWithoutDroppingHeights() {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(60)))
        let measured = c.measureCount
        c.configure(isGroup: false, metrics: c.metrics, selfSenderIDs: ["@owner:example.test"])
        c.tableView.layoutSubtreeIfNeeded()
        XCTAssertEqual(c.measureCount, measured, "no row is measured again")
    }

    func testAnEditAboveTheViewportDoesNotMoveIt() throws {
        var all = SyntheticHistory.messages(200)
        let c = host()
        c.apply(SyntheticHistory.rows(all))
        let clip = c.scrollView.contentView
        c.scroll(toY: clip.bounds.origin.y / 2)
        let anchor = try XCTUnwrap(c.visibleRows().first)
        let first = try XCTUnwrap(c.rows.firstIndex { $0.id == anchor.id })
        // A message well above the viewport gets a long edit and a reaction.
        let target = try XCTUnwrap(c.rows[..<first].lastIndex { if case .message = $0 { true } else { false } })
        guard case .message(let old, _, _, _) = c.rows[target - 0] else { return XCTFail() }
        let oldHeight = c.tableView.rect(ofRow: target).height
        let j = try XCTUnwrap(all.firstIndex { $0.id == old.id })
        all[j] = FixtureMessages.message(id: old.id, threadID: old.threadId, outgoing: old.sender.isSelf, at: old.sentAt,
                                         text: String(repeating: "an edited, much longer message ", count: 20),
                                         editedAt: old.sentAt.addingTimeInterval(30), reactions: [.init("👍", count: 3)])
        c.apply(SyntheticHistory.rows(all))
        XCTAssertGreaterThan(c.tableView.rect(ofRow: target).height, oldHeight)
        XCTAssertEqual(try XCTUnwrap(c.screenY(ofRowID: anchor.id)), anchor.y, accuracy: 0.5, "the viewport does not move")
    }

    func testALongMessageIsShownInFull() throws {
        let long = String(repeating: "lorem ipsum ", count: 5_334)
        let messages = [
            FixtureMessages.message(id: "a", at: SyntheticHistory.start, text: "short"),
            FixtureMessages.message(id: "long", at: SyntheticHistory.start.addingTimeInterval(60), text: long),
        ]
        let c = host()
        c.apply(SyntheticHistory.rows(messages))
        let i = try XCTUnwrap(c.rows.firstIndex { $0.id == "long" })
        // Owner ruling: long messages are shown in full, as in Messages (no "Show more").
        XCTAssertGreaterThan(c.tableView.rect(ofRow: i).height, 9_000, "64 000 characters, all of them")
    }
}

@MainActor
final class TranscriptPiecesTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Edmonton")!
        return c
    }
    private let en = Locale(identifier: "en_US")

    func testTimeHeaderWords() {
        let now = PrismJSON.parseDate("2026-11-21T20:00:00Z")! // Sat Nov 21, 13:00 MST
        func words(_ iso: String) -> TimeHeaderText { TimeHeaderText(PrismJSON.parseDate(iso)!, now: now, calendar: cal, locale: en) }
        XCTAssertEqual(words("2026-11-21T15:17:00Z").day, "Today")
        XCTAssertEqual(words("2026-11-21T15:17:00Z").time.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{202F}", with: " "), "8:17 AM")
        XCTAssertEqual(words("2026-11-21T00:55:00Z").day, "Yesterday")
        XCTAssertEqual(words("2026-11-19T03:24:00Z").day, "Wednesday")
        let thisYear = words("2026-06-13T21:30:00Z")
        XCTAssertEqual(thisYear.day, "Sat, Jun 13")
        XCTAssertTrue(thisYear.time.hasPrefix(" at "))
        XCTAssertEqual(words("2025-06-13T21:30:00Z").day, "Jun 13, 2025")
    }

    func testSpacingFollowsBubbleMetrics() {
        let m = BubbleMetrics.mac
        let t = SyntheticHistory.start
        let a1 = FixtureMessages.message(id: "a1", at: t)
        let a2 = FixtureMessages.message(id: "a2", at: t.addingTimeInterval(10))
        let me = FixtureMessages.message(id: "me", outgoing: true, at: t.addingTimeInterval(20))
        let rows = SyntheticHistory.rows([a1, a2, me])
        XCTAssertEqual(TranscriptRowView.spacingAbove(rows[2], after: rows[1], metrics: m), m.gapSameSender)
        // The visible gap after a tailed bubble: the row above holds its tail (Mac overhang).
        XCTAssertEqual(TranscriptRowView.spacingAbove(rows[3], after: rows[2], metrics: m) + TranscriptRowView.overhang(rows[2], metrics: m), m.gapSenderChange, accuracy: 0.001)
    }

    func testFixtureMediaIsADecodableImage() async throws {
        let backend = try FixtureBackend()
        let (data, type) = try await backend.media(token: "anything")
        XCTAssertEqual(type, "image/png")
        XCTAssertNotNil(MediaImage(data: data))
    }
}
#endif
