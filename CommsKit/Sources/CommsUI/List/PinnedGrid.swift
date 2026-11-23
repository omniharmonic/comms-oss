import CommsClient
import SwiftUI

/// The pinned conversations: a 3-column grid of 58 pt avatars with the name below (unread dot
/// before it). The selected pin gets an accent-blue rounded tile behind avatar and name.
public struct PinnedGrid: View {
    let threads: [CommsThread]
    let selection: String?
    let onSelect: (String) -> Void
    var pins: PinActions? = nil

    public init(threads: [CommsThread], selection: String?, onSelect: @escaping (String) -> Void) {
        self.threads = threads
        self.selection = selection
        self.onSelect = onSelect
    }

    init(threads: [CommsThread], selection: String?, onSelect: @escaping (String) -> Void, pins: PinActions?) {
        self.init(threads: threads, selection: selection, onSelect: onSelect)
        self.pins = pins
    }

    #if os(iOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)
    #else
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    #endif

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(threads) { t in
                tile(t)
                    .accessibilityIdentifier("thread-tile-\(t.id)")
            }
        }
        .padding(.horizontal, ListMetrics.pinnedGridInset)
    }

    /// One pin: tap opens it; with pin actions, Unpin in its menu and drag to reorder (drop it on
    /// another pin to take that pin's place), as in Messages.
    @ViewBuilder private func tile(_ t: CommsThread) -> some View {
        let base = PinnedTile(thread: t, isSelected: t.id == selection)
            .onTapGesture { onSelect(t.id) }
            .accessibilityAction { onSelect(t.id) }
        if let pins {
            base
                .pinActions(pins, threadID: t.id)
                .draggable(PinnedGrid.dragPrefix + t.id) {
                    AvatarView(t.avatar, kind: t.kind, size: ListMetrics.pinnedAvatar, badge: nil, name: t.title)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let id = Self.draggedID(items.first), id != t.id, threads.contains(where: { $0.id == id }),
                          let to = threads.firstIndex(where: { $0.id == t.id }) else { return false }
                    pins.move(id, to)
                    return true
                }
                .accessibilityActions {
                    if let i = threads.firstIndex(where: { $0.id == t.id }) {
                        if i > 0 { Button("Move Left") { pins.move(t.id, i - 1) } }
                        if i < threads.count - 1 { Button("Move Right") { pins.move(t.id, i + 1) } }
                    }
                }
        } else {
            base
        }
    }

    /// A dragged pin travels as "comms-pin:<thread id>" (plain text from elsewhere is ignored).
    static let dragPrefix = "comms-pin:"
    static func draggedID(_ s: String?) -> String? {
        guard let s, s.hasPrefix(dragPrefix) else { return nil }
        return String(s.dropFirst(dragPrefix.count))
    }
}

struct PinnedTile: View {
    let thread: CommsThread
    let isSelected: Bool

    var body: some View {
        VStack(spacing: ListMetrics.pinnedNameGap) {
            AvatarView(thread.avatar, kind: thread.kind, size: ListMetrics.pinnedAvatar, badge: thread.networks.first,
                       badgeRing: isSelected ? .white : nil, name: thread.title)
                .overlay(alignment: .top) {
                    if let preview = PinnedPreview.text(for: thread) {
                        PinnedPreview(text: preview)
                            .offset(y: ListMetrics.pinnedPreviewRise)
                    }
                }
            HStack(spacing: 3) {
                if thread.unread.count > 0 {
                    Circle()
                        .fill(isSelected ? Color.white : ListMetrics.accent)
                        .frame(width: ListMetrics.pinnedDot, height: ListMetrics.pinnedDot)
                }
                Text(thread.title)
                    .font(.system(size: ListMetrics.pinnedNameSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 2)
        }
        .padding(.top, ListMetrics.pinnedTilePadTop)
        .padding(.bottom, ListMetrics.pinnedTilePadBottom)
        .frame(width: ListMetrics.pinnedTileWidth)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: ListMetrics.selectionRadius, style: .continuous).fill(ListMetrics.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ThreadRow.accessibilityLabel(for: thread, time: nil))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Messages' "last message" bubble that sits over the top of an unread pin's avatar
/// (owner's iOS 27 device: ≈ 124 × 39 pt, two lines of Regular 15, centred on the avatar,
/// its top 7 pt above the avatar's). Short text gets a one-line bubble that hugs it.
/// Drawn as a translucent fill with a hairline (Messages' grey glass): a `glassEffect`
/// does not render deterministically offscreen, which snapshot tests need.
struct PinnedPreview: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    /// The newest message's text, for a pin with unread messages from someone else.
    static func text(for thread: CommsThread) -> String? {
        guard thread.unread.count > 0, let last = thread.lastMessage, !last.isSelf, !last.text.isEmpty else { return nil }
        return last.text
    }

    private static let padH: CGFloat = 10
    private static let padV: CGFloat = 4

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bubble(Text(text).lineLimit(1).fixedSize())
            bubble(Text(text).lineLimit(2).frame(width: ListMetrics.pinnedPreviewMaxWidth - 2 * Self.padH))
        }
        .frame(width: ListMetrics.pinnedPreviewMaxWidth)
        .accessibilityHidden(true)
    }

    private func bubble(_ text: some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return text
            .font(.system(size: ListMetrics.pinnedPreviewSize))
            .multilineTextAlignment(.center)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
            .padding(.horizontal, Self.padH)
            .padding(.vertical, Self.padV)
            .background(shape.fill(scheme == .dark ? Color(white: 0.24).opacity(0.94) : Color(white: 0.97).opacity(0.94)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
