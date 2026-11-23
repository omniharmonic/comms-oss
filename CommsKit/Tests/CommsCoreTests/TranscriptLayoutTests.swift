import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

final class TranscriptLayoutTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ iso: String) -> Date { PrismJSON.parseDate(iso)! }

    private func msg(_ id: String, _ iso: String, sender: String = "Alex", outgoing: Bool = false, system: String? = nil, redacted: Bool = false) -> CommsMessage {
        FixtureMessages.message(id: id, sender: sender, outgoing: outgoing, at: date(iso), system: system).with { $0.redacted = redacted }
    }

    /// A compact description: `T` for a time row, `id:position` for messages, `S:id` for system rows.
    private func shape(_ rows: [TranscriptRow]) -> [String] {
        rows.map { row in
            switch row {
            case .time: return "T"
            case .message(let m, let p, _, _): return "\(m.id):\(p)"
            case .system(_, let id): return "S:\(id)"
            }
        }
    }

    func testTimeHeaderOnDayChangeAndAfter60Minutes() {
        let cal = calendar("America/New_York")
        let messages = [
            msg("a", "2026-11-20T14:00:00Z"), // 09:00
            msg("b", "2026-11-20T14:30:00Z"), // 09:30
            msg("c", "2026-11-20T15:31:00Z"), // 10:31 (61 min later)
            msg("d", "2026-11-21T13:00:00Z"), // next day 08:00
        ]
        let rows = TranscriptLayout.rows(for: messages, isGroup: false, gapMinutes: 60, calendar: cal)
        XCTAssertEqual(shape(rows), ["T", "a:first", "b:last", "T", "c:single", "T", "d:single"])
        XCTAssertEqual(rows.compactMap { if case .time(let d) = $0 { d } else { nil } },
                       [date("2026-11-20T14:00:00Z"), date("2026-11-20T15:31:00Z"), date("2026-11-21T13:00:00Z")],
                       "each header carries the time of the message it introduces")
    }

    func testExactlySixtyMinutesIsNotAGap() {
        let rows = TranscriptLayout.rows(for: [msg("a", "2026-11-20T14:00:00Z"), msg("b", "2026-11-20T15:00:00Z")],
                                         isGroup: false, gapMinutes: 60, calendar: calendar("UTC"))
        XCTAssertEqual(shape(rows), ["T", "a:first", "b:last"])
    }

    func testRunPositionsSingleFirstMiddleLast() {
        let t = "2026-11-20T14:0"
        let messages = [
            msg("a1", t + "0:00Z"), msg("a2", t + "1:00Z"), msg("a3", t + "2:00Z"),
            msg("me", t + "3:00Z", outgoing: true),
            msg("a4", t + "4:00Z"),
            msg("sys", t + "5:00Z", system: "Alex joined"),
            msg("a5", t + "6:00Z"), msg("a6", t + "7:00Z"),
            msg("gone", t + "8:00Z", redacted: true),
            msg("a7", t + "9:00Z"),
        ]
        let rows = TranscriptLayout.rows(for: messages, isGroup: false, gapMinutes: 60, calendar: calendar("UTC"))
        XCTAssertEqual(shape(rows), [
            "T", "a1:first", "a2:middle", "a3:last", "me:single", "a4:single", "S:sys",
            "a5:first", "a6:last", "gone:single", "a7:single",
        ], "runs break on sender change, system rows and unsent messages")
    }

    func testTimeRowBreaksARun() {
        let rows = TranscriptLayout.rows(for: [msg("a", "2026-11-20T14:00:00Z"), msg("b", "2026-11-20T16:00:00Z")],
                                         isGroup: false, gapMinutes: 60, calendar: calendar("UTC"))
        XCTAssertEqual(shape(rows), ["T", "a:single", "T", "b:single"])
    }

    func testGroupShowsNameFirstAvatarLast() {
        let t = "2026-11-20T14:0"
        let messages = [
            msg("al1", t + "0:00Z", sender: "Alice"), msg("al2", t + "1:00Z", sender: "Alice"), msg("al3", t + "2:00Z", sender: "Alice"),
            msg("bo1", t + "3:00Z", sender: "Bob"),
            msg("me1", t + "4:00Z", outgoing: true), msg("me2", t + "5:00Z", outgoing: true),
        ]
        func flags(_ rows: [TranscriptRow]) -> [String: String] {
            var out: [String: String] = [:]
            for case .message(let m, _, let name, let avatar) in rows { out[m.id] = "\(name ? "N" : "-")\(avatar ? "A" : "-")" }
            return out
        }
        let group = TranscriptLayout.rows(for: messages, isGroup: true, gapMinutes: 60, calendar: calendar("UTC"))
        XCTAssertEqual(flags(group), ["al1": "N-", "al2": "--", "al3": "-A", "bo1": "NA", "me1": "--", "me2": "--"])
        let dm = TranscriptLayout.rows(for: messages, isGroup: false, gapMinutes: 60, calendar: calendar("UTC"))
        XCTAssertEqual(Set(flags(dm).values), ["--"], "a DM never shows sender names or avatars")
    }

    func testDstBoundaryHeaders() {
        // America/Edmonton leaves DST on 2026-11-01 at 02:00 MDT (→ 01:00 MST): wall-clock time
        // repeats 01:00–02:00, so gaps must be measured in absolute time and days by the calendar.
        let cal = calendar("America/Edmonton")
        let messages = [
            msg("m0", "2026-11-01T05:50:00Z"), // Oct 31 23:50 MDT
            msg("m1", "2026-11-01T06:20:00Z"), // Nov 1 00:20 MDT: day change
            msg("a", "2026-11-01T07:20:00Z"),  // 01:20 MDT, exactly 60 min later
            msg("b", "2026-11-01T08:10:00Z"),  // 01:10 MST: wall clock went back, 50 min later
            msg("c", "2026-11-01T09:15:00Z"),  // 02:15 MST, 65 min later
            msg("d", "2026-11-02T06:30:00Z"),  // Nov 1 23:30 MST
            msg("e", "2026-11-02T07:05:00Z"),  // Nov 2 00:05 MST, 35 min later: day change
        ]
        let rows = TranscriptLayout.rows(for: messages, isGroup: false, gapMinutes: 60, calendar: cal)
        XCTAssertEqual(shape(rows), ["T", "m0:single", "T", "m1:first", "a:middle", "b:last", "T", "c:single", "T", "d:single", "T", "e:single"])
    }

    func testRowIDsAreStableAndUnique() {
        let messages = [msg("a", "2026-11-20T14:00:00Z"), msg("b", "2026-11-20T16:00:00Z"), msg("s", "2026-11-20T16:01:00Z", system: "x")]
        let rows = TranscriptLayout.rows(for: messages, isGroup: false, gapMinutes: 60, calendar: calendar("UTC"))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows.map(\.id), TranscriptLayout.rows(for: messages, isGroup: false, gapMinutes: 60, calendar: calendar("UTC")).map(\.id))
        XCTAssertEqual(rows.first?.id, "time:\(date("2026-11-20T14:00:00Z").timeIntervalSince1970)")
    }
}

extension CommsMessage {
    func with(_ change: (inout CommsMessage) -> Void) -> CommsMessage {
        var copy = self
        change(&copy)
        return copy
    }
}
