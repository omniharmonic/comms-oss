// The iOS transcript host (flipped UICollectionView): iOS-only, run on the iOS simulator
// (`xcodebuild test -scheme CommsKit-Package -destination 'platform=iOS Simulator,…'`).
#if os(iOS)
import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import UIKit
import XCTest

@MainActor
final class PhoneTranscriptTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func host(width: CGFloat = 402, height: CGFloat = 874) -> PhoneTranscriptController {
        let c = PhoneTranscriptController()
        c.mediaLoader = .placeholder
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        w.rootViewController = c
        w.isHidden = false
        w.layoutIfNeeded()
        c.setInsets(top: 140, bottom: 80)
        window = w
        return c
    }

    private func visible(_ c: PhoneTranscriptController) -> [String: Double] {
        Dictionary(c.visibleRows().map { ($0.id, Double($0.y)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The spike's harness: scroll toward older history at 15 pt per tick starting from the
    /// newest 100 messages; whenever the controller asks for older history, add 50 on that
    /// tick. 10 prepends.
    private func runPrependHarness(displaces: Bool) -> (meter: JumpMeter, inserts: Int) {
        let all = SyntheticHistory.messages(600)
        var shown = 100
        let c = host()
        c.displacesOnInsertForTesting = displaces
        var needsOlder = false
        c.onNeedsOlder = { needsOlder = true }
        c.apply(SyntheticHistory.rows(all.suffix(shown)), caption: nil)
        c.setCanLoadOlder(true)
        needsOlder = false
        c.scrollToNewest()

        var meter = JumpMeter()
        meter.sample(visible(c), anchorPosition: { _ in nil }, scrollDelta: 0, insertedThisTick: false)
        var inserts = 0
        var ticks = 0
        let cv = c.collectionView!
        while inserts < 10, ticks < 20_000 {
            ticks += 1
            let old = cv.contentOffset.y
            let maxY = c.layout.collectionViewContentSize.height + cv.contentInset.bottom - cv.bounds.height
            c.scroll(toY: min(old + 15, max(maxY, old)))
            cv.layoutIfNeeded()
            // Flipped: a larger offset moves the content DOWN on screen by the same amount.
            let delta = -(cv.contentOffset.y - old)
            var inserted = false
            if needsOlder, shown < all.count {
                needsOlder = false
                shown = min(all.count, shown + 50)
                c.apply(SyntheticHistory.rows(all.suffix(shown)), caption: nil)
                c.setCanLoadOlder(shown < all.count)
                inserts += 1
                inserted = true
            }
            meter.sample(visible(c), anchorPosition: { c.screenY(ofRowID: $0).map(Double.init) }, scrollDelta: delta, insertedThisTick: inserted)
            if delta == 0, !inserted, !needsOlder { break }
        }
        return (meter, inserts)
    }

    func testPrependTenPagesOfFiftyNeverMovesWhatIsOnScreen() {
        let (meter, inserts) = runPrependHarness(displaces: false)
        print("IOS_TRANSCRIPT_JUMP flipped \(meter.summary(inserts: inserts))")
        XCTAssertEqual(inserts, 10)
        XCTAssertTrue(meter.valid, "every insert tick compared at least one row")
        XCTAssertGreaterThanOrEqual(meter.minComparedAtInsert, 1)
        XCTAssertEqual(meter.insertSamples, 10)
        XCTAssertEqual(meter.maxJump, 0, accuracy: 0.001)
        XCTAssertEqual(meter.maxJumpAtInsert, 0, accuracy: 0.001)
    }

    /// Negative control: the same run with the content displaced by the inserted height on
    /// every prepend (what an unflipped, uncompensated list does) must register big jumps.
    func testNegativeControlMeterDetectsADisplacedPrepend() {
        let (meter, inserts) = runPrependHarness(displaces: true)
        print("IOS_TRANSCRIPT_JUMP negative-control(displaced) \(meter.summary(inserts: inserts))")
        XCTAssertGreaterThanOrEqual(inserts, 1)
        XCTAssertTrue(meter.valid)
        XCTAssertGreaterThan(meter.maxJumpAtInsert, 500)
    }

    func testOpensAtTheNewestRowJustAboveTheComposer() throws {
        let c = host()
        let rows = SyntheticHistory.rows(SyntheticHistory.messages(80))
        c.apply(rows, caption: nil)
        let newest = try XCTUnwrap(rows.last)
        let y = try XCTUnwrap(c.screenY(ofRowID: newest.id))
        let frame = c.layout.frame(at: 0)
        // Its bottom edge sits composerGap above the composer (874 − 80).
        XCTAssertEqual(y + frame.height, 874 - 80 - PhoneTranscriptController.composerGap, accuracy: 0.5)
        XCTAssertTrue(c.isAtNewest)
    }

    func testAShortTranscriptSitsUnderTheHeader() throws {
        let c = host()
        let rows = SyntheticHistory.rows(SyntheticHistory.messages(1))
        c.apply(rows, caption: "WhatsApp")
        let top = try XCTUnwrap(c.screenY(ofRowID: "history-caption"))
        XCTAssertEqual(top, 140, accuracy: 0.5, "the oldest item starts at the header's band")
    }

    func testCellsAreLaidOutAtTheirMeasuredHeights() {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(120)), caption: nil)
        let cv = c.collectionView!
        for _ in 0..<6 {
            cv.contentOffset.y += 500
            cv.layoutIfNeeded()
            for cell in cv.visibleCells {
                guard let ip = cv.indexPath(for: cell) else { continue }
                XCTAssertEqual(cell.frame, c.layout.frame(at: ip.item), "item \(ip.item) frame")
            }
        }
        for i in 0..<min(40, c.items.count) {
            XCTAssertEqual(c.layout.frame(at: i).height, c.freshHeight(ofItem: i), accuracy: 0.5, "cached height of item \(i)")
        }
    }

    func testALiveMessageAtTheNewestStaysPinned() throws {
        let c = host()
        let all = SyntheticHistory.messages(81)
        c.apply(SyntheticHistory.rows(all.prefix(80)), caption: nil)
        c.apply(SyntheticHistory.rows(all), caption: nil)
        XCTAssertTrue(c.isAtNewest)
        let last = try XCTUnwrap(SyntheticHistory.rows(all).last)
        let y = try XCTUnwrap(c.screenY(ofRowID: last.id))
        XCTAssertEqual(y + c.layout.frame(at: 0).height, 874 - 80 - PhoneTranscriptController.composerGap, accuracy: 0.5)
    }

    func testALiveMessageWhileReadingHistoryDoesNotMoveIt() throws {
        let c = host()
        let all = SyntheticHistory.messages(121)
        c.apply(SyntheticHistory.rows(all.prefix(120)), caption: nil)
        c.scroll(toY: 1500)
        c.collectionView.layoutIfNeeded()
        let before = visible(c)
        c.apply(SyntheticHistory.rows(all), caption: nil)
        c.collectionView.layoutIfNeeded()
        let after = visible(c)
        var compared = 0
        for (id, y) in before {
            guard let y2 = after[id] else { continue }
            compared += 1
            XCTAssertEqual(y, y2, accuracy: 0.001, "row \(id)")
        }
        XCTAssertGreaterThan(compared, 3)
    }

    func testTheKeyboardLiftsTheNewestRowWithTheComposer() throws {
        let c = host()
        let rows = SyntheticHistory.rows(SyntheticHistory.messages(80))
        c.apply(rows, caption: nil)
        let id = try XCTUnwrap(rows.last?.id)
        let before = try XCTUnwrap(c.screenY(ofRowID: id))
        c.setInsets(top: 140, bottom: 80 + 336) // keyboard up
        let up = try XCTUnwrap(c.screenY(ofRowID: id))
        XCTAssertEqual(up, before - 336, accuracy: 0.5)
        c.setInsets(top: 140, bottom: 80)
        XCTAssertEqual(try XCTUnwrap(c.screenY(ofRowID: id)), before, accuracy: 0.5)
    }

    func testRequestsOlderHistoryNearTheOldestRowOnlyOncePerLoad() {
        let c = host()
        var requests = 0
        c.onNeedsOlder = { requests += 1 }
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(200)), caption: nil)
        c.setCanLoadOlder(true)
        XCTAssertEqual(requests, 0, "the newest screen is far from the oldest row")
        let cv = c.collectionView!
        cv.contentOffset.y = c.layout.collectionViewContentSize.height - cv.bounds.height
        c.scrollViewDidScroll(cv)
        c.scrollViewDidScroll(cv)
        XCTAssertEqual(requests, 1)
        c.noteOlderLoads(1)
        c.scrollViewDidScroll(cv)
        XCTAssertEqual(requests, 2, "re-armed once the load finished")
    }

    func testAWidthChangeKeepsTheAnchor() throws {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(150)), caption: nil)
        c.scroll(toY: 2000)
        c.collectionView.layoutIfNeeded()
        let anchor = try XCTUnwrap(c.visibleRows().first { $0.y > 200 })
        window?.frame = CGRect(x: 0, y: 0, width: 600, height: 874)
        window?.layoutIfNeeded()
        c.view.layoutIfNeeded()
        let y = try XCTUnwrap(c.screenY(ofRowID: anchor.id))
        // The anchor is the visible row nearest the composer; rows above it may re-wrap.
        XCTAssertLessThan(abs(y - anchor.y), 400)
        XCTAssertEqual(c.contentWidth, 600)
    }

    func testAnAnimatedWidthChangeMeasuresOnlyTheBandUntilItSettles() throws {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(300)), caption: nil)
        let before = c.measureCount
        for w in stride(from: 402.0, through: 700.0, by: 30) {
            window?.frame = CGRect(x: 0, y: 0, width: w, height: 874)
            window?.layoutIfNeeded()
            c.view.layoutIfNeeded()
        }
        let perFrame = c.measureCount - before
        XCTAssertLessThan(perFrame, 300 * 3, "each frame measures the viewport band, not all 300+ rows")
        XCTAssertTrue(c.isAtNewest, "kept at the newest row")
        c.flushPendingRemeasure()
        for i in 0..<c.items.count where i % 25 == 0 {
            XCTAssertEqual(c.layout.frame(at: i).height, c.freshHeight(ofItem: i), accuracy: 0.5, "item \(i) re-measured once settled")
        }
    }

    func testAGroupFlagChangeKeepsTheReadingPosition() throws {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(150)), caption: nil)
        c.scroll(toY: 1800)
        c.collectionView.layoutIfNeeded()
        let anchor = try XCTUnwrap(c.visibleRows().last)
        c.configure(isGroup: true, metrics: c.metrics, selfSenderIDs: [], mediaLoader: .placeholder, avatarLoader: nil)
        XCTAssertFalse(c.isAtNewest, "not thrown back to the newest row")
        XCTAssertNotNil(c.screenY(ofRowID: anchor.id))
        XCTAssertLessThan(abs(c.collectionView.contentOffset.y - 1800), 600)
    }

    func testVoiceOverOrderIsTopToBottomOldestFirst() throws {
        let c = host()
        c.apply(SyntheticHistory.rows(SyntheticHistory.messages(40)), caption: nil)
        c.collectionView.layoutIfNeeded()
        let elements = try XCTUnwrap(c.collectionView.accessibilityElements as? [UICollectionViewCell])
        XCTAssertGreaterThan(elements.count, 3)
        let ys = elements.map { $0.convert($0.bounds, to: nil).minY }
        XCTAssertEqual(ys, ys.sorted(), "screen order, top to bottom")
        let ids = elements.compactMap { c.collectionView.indexPath(for: $0)?.item }
        XCTAssertEqual(ids, ids.sorted(by: >), "oldest (highest index) first, newest last")
    }
}
#endif
