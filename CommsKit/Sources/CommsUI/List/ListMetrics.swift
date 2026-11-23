import CommsClient
import SwiftUI

/// Mac sidebar metrics (UX spec §9) and the colours the list uses. Sizes and colours with a
/// design token come from `Tokens`; the rest are measured from
/// docs/research/refs/macos26-guide-window-sidebar-transcript.png (≈ 1×).
enum ListMetrics {
    #if os(iOS)
    // iOS 27 Messages, measured on the real app (iPhone 17 simulator, accessibility frames in
    // design/fidelity/apple-ios/list-light.ax.txt): a full-width 86.7 pt row, 45 pt avatar at
    // x 26, name / preview / separator at x 83, timestamp + chevron ending 16 pt from the edge.
    static let rowHeight = Tokens.list.rowHeightIOS
    static let avatar = Tokens.list.avatarIOS
    static let pinnedAvatar = Tokens.list.pinnedAvatarIOS
    static let unreadDot = Tokens.list.badge
    /// No inset panel on iPhone: rows run edge to edge.
    static let sidebarInset: CGFloat = 0
    /// Leading gutter (holds the unread dot): the avatar starts at x 26.
    static let gutter: CGFloat = 26
    /// Avatar (26 + 45 = 71) to the text column at x 83.
    static let avatarToText: CGFloat = 12
    /// The chevron ends at x 386.
    static let rowTrailing: CGFloat = 16
    static let selectionRadius: CGFloat = 10
    /// Name: SF Pro Semibold 17 (label frame y = row + 12).
    static let nameSize: CGFloat = 17
    static let nameWeight: Font.Weight = .semibold
    static let nameTop: CGFloat? = 12
    /// Timestamp: Regular 15 (label 59 × 18 pt), 10 pt before the chevron.
    static let timeSize: CGFloat = 15
    /// Preview: Regular 15/20, two lines always reserved.
    static let previewSize: CGFloat = 15
    static let previewLineSpacing: CGFloat = 2
    /// Disclosure chevron: chevron.forward, 10.3 × 14 pt frame, 30 % label colour.
    static let chevronSize: CGFloat = 13.5
    static let chevronGap: CGFloat = 10
    static let showsChevron = true
    static let pinnedNameSize: CGFloat = 13
    static let pinnedDot: CGFloat = 10
    static let pinnedTileWidth: CGFloat = 127.5
    // Pinned grid, measured on the owner's iOS 27 device (dark, @3x): 95 pt avatars in three
    // 127.5 pt columns (centres x 73.5 / 201 / 328.5, so the outer avatars sit at x 26 and
    // end at 376), rows 131.3 pt apart, the first avatar 20 pt under the nav bar.
    static let pinnedGridInset: CGFloat = 9.75
    static let pinnedGridTop: CGFloat = 10 // the inline bar ends at y 116; first avatar at 126
    static let pinnedGridBottom: CGFloat = 0
    static let pinnedNameGap: CGFloat = 5
    static let pinnedTilePadTop: CGFloat = 0
    static let pinnedTilePadBottom: CGFloat = 15.3
    /// The glass "last message" bubble over an unread pin: Regular 15, two lines max.
    static let pinnedPreviewSize: CGFloat = 15
    static let pinnedPreviewMaxWidth: CGFloat = 124
    static let pinnedPreviewRise: CGFloat = -7
    #else
    // tokens.json `list`
    static let rowHeight = Tokens.list.rowHeightMac
    static let avatar = Tokens.list.avatarMac
    static let pinnedAvatar = Tokens.list.pinnedAvatarMac
    static let unreadDot = Tokens.list.badge

    // Measured (guide image)
    /// Sidebar content inset from the panel edge; the selection rect sits inside it.
    static let sidebarInset: CGFloat = 8
    /// Leading gutter that holds the unread dot.
    static let gutter: CGFloat = 16
    static let avatarToText: CGFloat = 10
    static let rowTrailing: CGFloat = 10
    static let selectionRadius: CGFloat = 10
    static let nameSize: CGFloat = 13
    static let nameWeight: Font.Weight = .bold
    static let nameTop: CGFloat? = nil
    static let timeSize: CGFloat = 11
    static let previewSize: CGFloat = 12
    static let previewLineSpacing: CGFloat = 0
    static let chevronSize: CGFloat = 0
    static let chevronGap: CGFloat = 0
    static let showsChevron = false
    static let pinnedNameSize: CGFloat = 11
    static let pinnedDot: CGFloat = 7
    static let pinnedTileWidth: CGFloat = 76
    static let pinnedGridInset: CGFloat = 0
    static let pinnedGridTop: CGFloat = 12 // room for a pin's message bubble under the search field
    static let pinnedGridBottom: CGFloat = 6
    static let pinnedNameGap: CGFloat = 6
    static let pinnedTilePadTop: CGFloat = 8
    static let pinnedTilePadBottom: CGFloat = 7
    static let pinnedPreviewSize: CGFloat = 11
    static let pinnedPreviewMaxWidth: CGFloat = 84
    /// Mac guide: the bubble sits mostly above the 58 pt avatar, overlapping its top edge.
    static let pinnedPreviewRise: CGFloat = -20
    #endif
    /// Where row separators start (the text column).
    static var textColumn: CGFloat { gutter + avatar + avatarToText }

    // tokens.json `color`
    static let accent = Tokens.color.accent.color

    /// The iOS row hairline: 1 pt, #E8E8E8 light / #2A2A2C dark (sampled from the real app).
    static func separator(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? Tokens.color.separatorDark : Tokens.color.separatorLight).color
    }

    /// The network badge fill: that network's Mac outgoing shade (every shade is a blue, D4).
    static func networkColor(_ network: CommsNetwork) -> Color {
        Tokens.color.outgoingByNetwork.shade(for: network).mac.color
    }

    /// The opaque colour closest to the sidebar glass, for rings that must read as "cut out".
    static func sidebarFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.965, green: 0.965, blue: 0.965)
    }
}
