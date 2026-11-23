import CommsCore
@testable import CommsUI
import SwiftUI
import XCTest

/// The reaction emoji picker: every emoji (Unicode emoji 16.0) in Messages' categories,
/// searchable, with skin tones — replacing the emoji-keyboard trick that never reached the server.
@MainActor
final class EmojiPickerTests: XCTestCase {
    let catalog = EmojiCatalog.shared

    func testCatalogHasEveryKindOfEmoji() {
        XCTAssertEqual(catalog.categories.map(\.name), ["Smileys & People", "Animals & Nature", "Food & Drink", "Activity", "Travel & Places", "Objects", "Symbols", "Flags"])
        XCTAssertGreaterThan(catalog.all.count, 1_800)
        let values = Set(catalog.all.map(\.value))
        for e in ["😀", "🌮", "❤️‍🔥", "🧑‍🤝‍🧑", "🇯🇵", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "1️⃣", "#️⃣", "🫩", "🏳️‍🌈", "👨‍👩‍👧‍👦"] {
            XCTAssertTrue(values.contains(e), e)
        }
        XCTAssertFalse(values.contains("🏻"), "skin-tone components are not emoji of their own")
        XCTAssertFalse(values.contains("👍🏽"), "variants fold under their base")
        XCTAssertEqual(catalog.entry(for: "👍")?.variants, ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        XCTAssertEqual(catalog.entry(for: "🧑‍🤝‍🧑")?.variants.count, 25, "two-person tone combinations")
        XCTAssertEqual(catalog.entry(for: "👍🏾")?.value, "👍", "a variant finds its base")
    }

    func testSearch() {
        XCTAssertEqual(catalog.search("taco").map(\.value), ["🌮"])
        XCTAssertTrue(catalog.search("thumbs up").map(\.value).contains("👍"))
        XCTAssertTrue(catalog.search("flag jap").map(\.value).contains("🇯🇵"))
        XCTAssertTrue(catalog.search("  ").isEmpty)
        XCTAssertTrue(catalog.search("zzzqqq").isEmpty)
        XCTAssertEqual(catalog.search("🌮").map(\.value), ["🌮"])
    }

    func testCatalogParsing() {
        let c = EmojiCatalog(tsv: "%% comment\n@@Food & Drink\n🌮\ttaco\t\n@@Symbols\n#️⃣\tkeycap: #\t\n👍\tthumbs up\t👍🏻 👍🏿\n")
        XCTAssertEqual(c.categories.map(\.name), ["Food & Drink", "Symbols"])
        XCTAssertEqual(c.categories[1].emoji.map(\.value), ["#️⃣", "👍"], "a keycap # is an emoji, not a header")
        XCTAssertEqual(c.categories[1].emoji[1].variants, ["👍🏻", "👍🏿"])
    }

    func testRecentsKeepMoreThanTheBarShows() {
        let saved = UserDefaults.standard.array(forKey: RecentReactions.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: RecentReactions.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: RecentReactions.defaultsKey)
        for e in ["🌮", "🧑🏽‍🤝‍🧑🏿", "🇯🇵", "1️⃣", "🫩", "🦄", "🍕", "🎸"] { RecentReactions.note(e) }
        XCTAssertEqual(RecentReactions.all.first, "🎸", "newest first")
        XCTAssertEqual(RecentReactions.all.count, 8)
        XCTAssertEqual(TapbackPicker(selected: [], recents: RecentReactions.all) { _ in }.keys.count, 8, "the bar: six tapbacks + two recents")
    }

    func testPickerSnapshot() {
        let picker = EmojiPicker(recents: ["🌮", "🫩"]) { _ in }.frame(width: 340, height: 380)
        Snapshot.assertHosted(picker, named: "emojiPicker", width: 340)
    }
}
