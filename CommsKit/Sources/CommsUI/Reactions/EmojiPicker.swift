import Foundation
import SwiftUI

/// Every emoji, as Messages' emoji keyboard lists them: Unicode's order (emoji 16.0, ZWJ
/// sequences, flags, keycaps) in Apple's categories, each with its CLDR name for search and its
/// skin-tone variants (`Resources/emoji.tsv`, made by design/tools/make-emoji-data.py).
public struct EmojiCatalog: Sendable {
    public struct Emoji: Sendable, Hashable, Identifiable {
        public let value: String
        public let name: String
        /// Skin-tone variants (empty when there are none).
        public let variants: [String]
        public var id: String { value }
    }
    public struct Category: Sendable, Identifiable {
        public let name: String
        public let symbol: String
        public let emoji: [Emoji]
        public var id: String { name }
    }

    public let categories: [Category]

    /// The bundled catalog (parsed once).
    public static let shared = EmojiCatalog(tsv: Bundle.module.url(forResource: "emoji", withExtension: "tsv").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")

    static let symbols: [String: String] = [
        "Smileys & People": "face.smiling", "Animals & Nature": "pawprint", "Food & Drink": "fork.knife",
        "Activity": "basketball", "Travel & Places": "car", "Objects": "lightbulb", "Symbols": "heart", "Flags": "flag",
    ]

    public init(tsv: String) {
        var categories: [Category] = []
        var name: String?
        var list: [Emoji] = []
        func flush() {
            if let name { categories.append(Category(name: name, symbol: Self.symbols[name] ?? "circle", emoji: list)) }
            list = []
        }
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("%%") { continue }
            if line.hasPrefix("@@") {
                flush()
                name = String(line.dropFirst(2))
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty else { continue }
            let variants = parts.count > 2 ? parts[2].split(separator: " ").map(String.init) : []
            list.append(Emoji(value: String(parts[0]), name: String(parts[1]), variants: variants))
        }
        flush()
        self.categories = categories
    }

    public var all: [Emoji] { categories.flatMap(\.emoji) }

    /// Emoji whose name has a word starting with every word of `query` ("taco", "thumbs up",
    /// "flag jap"); an emoji typed into the field finds itself.
    public func search(_ query: String) -> [Emoji] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { e in
            if e.value == query || e.variants.contains(query) { return true }
            let nameWords = e.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            return words.allSatisfy { w in nameWords.contains { $0.hasPrefix(w) } }
        }
    }

    /// The catalog entry for `value` (or for the base of a skin-tone variant).
    public func entry(for value: String) -> Emoji? {
        all.first { $0.value == value || $0.variants.contains(value) }
    }
}

/// Messages' emoji picker for reactions: a search field, Frequently Used (this device's recent
/// reactions), then every category in a scrolling grid with a category bar; long-press an
/// emoji with skin tones for its variants. Picking one reacts with it (`onPick`).
public struct EmojiPicker: View {
    let catalog: EmojiCatalog
    let recents: [String]
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var variantsFor: EmojiCatalog.Emoji?
    @FocusState private var searching: Bool

    #if os(iOS)
    static let cell: CGFloat = 44
    static let glyph: CGFloat = 32
    #else
    static let cell: CGFloat = 32
    static let glyph: CGFloat = 24
    #endif

    public init(catalog: EmojiCatalog = .shared, recents: [String] = RecentReactions.all, onPick: @escaping (String) -> Void) {
        self.catalog = catalog
        self.recents = recents
        self.onPick = onPick
    }

    /// Recent reactions as entries (a skin-tone variant keeps its base's name).
    private var recentEntries: [EmojiCatalog.Emoji] {
        recents.map { r in EmojiCatalog.Emoji(value: r, name: catalog.entry(for: r)?.name ?? r, variants: []) }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell + 8), spacing: 2)] }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            if !recents.isEmpty {
                                section("Frequently Used", recentEntries)
                            }
                            ForEach(catalog.categories) { c in
                                section(c.name, c.emoji).id(c.name)
                            }
                        } else {
                            let found = catalog.search(query)
                            if found.isEmpty {
                                Text("No Results")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            } else {
                                section("Search Results", found)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollDismissesKeyboard(.immediately)
                if query.isEmpty {
                    categoryBar(proxy)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emoji-picker")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Emoji", text: $query)
                .textFieldStyle(.plain)
                .focused($searching)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("emoji-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }

    private func section(_ title: String, _ list: [EmojiCatalog.Emoji]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(list) { e in cell(e) }
            }
        }
    }

    private func cell(_ e: EmojiCatalog.Emoji) -> some View {
        Button { onPick(e.value) } label: {
            Text(e.value)
                .font(.system(size: Self.glyph))
                .frame(width: Self.cell, height: Self.cell)
                .contentShape(.rect)
        }
        .buttonStyle(TapbackButtonStyle())
        .accessibilityLabel(e.name)
        .accessibilityHint(e.variants.isEmpty ? "" : "Touch and hold for skin tones")
        .accessibilityIdentifier("emoji-\(e.name)")
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            if !e.variants.isEmpty { variantsFor = e }
        })
        .accessibilityAction(named: "Skin Tones") { if !e.variants.isEmpty { variantsFor = e } }
        .popover(item: Binding(get: { variantsFor?.value == e.value ? variantsFor : nil }, set: { variantsFor = $0 })) { item in
            SkinTonePicker(emoji: item, glyph: Self.glyph, cell: Self.cell) { v in
                variantsFor = nil
                onPick(v)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private func categoryBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(catalog.categories) { c in
                Button {
                    withAnimation(.snappy) { proxy.scrollTo(c.name, anchor: .top) }
                } label: {
                    Image(systemName: c.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.name)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// The row of skin tones Messages shows when an emoji is held.
struct SkinTonePicker: View {
    let emoji: EmojiCatalog.Emoji
    let glyph: CGFloat
    let cell: CGFloat
    let onPick: (String) -> Void

    var body: some View {
        // Simple tones on one row; two-person combinations wrap into a grid.
        let all = [emoji.value] + emoji.variants
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 2), count: min(6, all.count)), spacing: 2) {
            ForEach(all, id: \.self) { v in
                Button { onPick(v) } label: {
                    Text(v).font(.system(size: glyph)).frame(width: cell, height: cell).contentShape(.rect)
                }
                .buttonStyle(TapbackButtonStyle())
                .accessibilityLabel(v == emoji.value ? emoji.name : "\(emoji.name), skin tone \(all.firstIndex(of: v) ?? 0)")
            }
        }
        .padding(8)
        .accessibilityIdentifier("emoji-skin-tones")
    }
}
