import CommsClient
import CommsCore
import CommsTestSupport
import Foundation

/// Synthetic history: `count` messages oldest first, variable lengths, two senders, an image
/// now and then, and an occasional gap of hours (so prepends also add / drop time rows).
enum SyntheticHistory {
    static let start = PrismJSON.parseDate("2026-10-01T09:00:00Z")!

    static func messages(_ count: Int) -> [CommsMessage] {
        var t = start
        return (0..<count).map { i in
            var rng = UInt64(i) &* 6364136223846793005 &+ 1442695040888963407
            func next() -> Int { rng ^= rng >> 33; rng = rng &* 0xff51afd7ed558ccd; rng ^= rng >> 33; return Int(rng % 1000) }
            t = t.addingTimeInterval(next() % 17 == 0 ? 3 * 3600 : Double(30 + next() % 300))
            let words = 1 + next() % 60
            let text = (0..<words).map { w in ["ok", "trail", "tomorrow", "sounds good", "the north ridge", "bring water"][(w + i) % 6] }.joined(separator: " ")
            let outgoing = next() % 3 == 0
            return FixtureMessages.message(
                id: String(format: "m%04d", i), threadID: "th_syn", sender: "Alex", outgoing: outgoing, at: t,
                text: text, attachments: next() % 23 == 0 ? [FixtureMessages.image(token: "img\(i)", w: 800, h: 600)] : []
            )
        }
    }

    static func rows(_ messages: some Collection<CommsMessage>) -> [TranscriptRow] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return TranscriptLayout.rows(for: Array(messages), isGroup: false, gapMinutes: 60, calendar: cal)
    }
}

