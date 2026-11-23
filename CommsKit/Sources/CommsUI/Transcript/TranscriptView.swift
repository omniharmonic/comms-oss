#if os(macOS)
import AppKit
import CommsClient
import CommsCore
import SwiftUI

/// The Mac transcript: the conversation's rows in the anchored table, under a floating glass
/// header (avatar + name pill, which toggles the Details inspector), the source-error banner,
/// a scroll-to-bottom glass button when more than a screen up, and the Phase 1 composer
/// placeholder. Media and avatars load through `\.mediaLoader` / `\.avatarLoader`.
public struct TranscriptView: View {
    let store: TimelineStore

    @State private var showsInspector = false
    /// Files, photos and images dropped anywhere on the conversation go to the composer.
    @State private var dropInbox = ComposerDropInbox()
    @State private var farFromBottom = false
    @State private var topHeight: CGFloat = 80
    @State private var bottomHeight: CGFloat = 56
    @State private var scroller = TranscriptScroller()
    /// The message overlay on screen (right-click / Control-click / Force Touch, double-click…).
    @State private var overlay: OverlayRequest?
    @Environment(\.mediaLoader) private var mediaLoader
    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.omniStore) private var omni
    @Environment(\.messageEmojiPicker) private var emojiPicker

    public init(store: TimelineStore) {
        self.store = store
    }

    /// Toolbar band geometry (kit: unified toolbar 52 pt, XL buttons 36 pt at y 8).
    static let toolbarTop: CGFloat = 8
    static let toolbarSideMargin: CGFloat = 12
    static let composerBottom: CGFloat = 10
    static let composerGap: CGFloat = 12

    public var body: some View {
        ZStack {
            TranscriptTable(
                rows: store.rows,
                isGroup: store.isGroup,
                canLoadOlder: store.hasMore && !store.isStalled,
                olderLoadCount: store.olderLoadCount,
                selfSenderIDs: store.selfSenderIDs,
                topInset: topHeight,
                bottomInset: bottomHeight,
                metrics: metrics,
                mediaLoader: mediaLoader,
                scroller: scroller,
                sendActions: .store(store),
                interactions: .store(store, omni: omni),
                overlayShown: overlay != nil,
                onPresentOverlay: { context, mode in overlay = OverlayRequest(context: context, mode: mode) },
                onNeedsOlder: { Task { await store.loadOlder() } },
                // Reported from inside the table's update: hop out of the view-update pass.
                onFarFromBottomChange: { far in Task { @MainActor in withAnimation(.snappy) { farFromBottom = far } } }
            )
            .ignoresSafeArea(.container, edges: .top)
            placeholder
        }
        .overlay(alignment: .top) {
            // Mac Messages: the header sits in the toolbar band at the top of the transcript
            // column — avatar + name pill centred over the column (it re-centres when the
            // inspector narrows the column), the FaceTime and Info (ⓘ, ⌥⌘I) circles at the
            // trailing edge — over a soft scroll edge. Compose lives in the sidebar's toolbar
            // only (as in Messages).
            ZStack(alignment: .top) {
                HStack(spacing: 8) {
                    Spacer()
                    // Messages' FaceTime circle: a menu of every way to call this person
                    // (FaceTime, FaceTime Audio, Phone, their apps); absent when there is none.
                    TranscriptCallMenu(options: CallRoutes.options(contact: store.contact, networks: store.thread?.networks ?? []))
                    TranscriptToolbarButton(systemImage: "info.circle", label: "Details",
                                            hint: showsInspector ? "Hides the details" : "Shows the details", id: "transcript-info") {
                        showsInspector.toggle()
                    }
                    .help("Details (⌥⌘I)")
                }
                .padding(.horizontal, Self.toolbarSideMargin)
                VStack(spacing: 8) {
                    TranscriptHeader(thread: store.thread, isInspectorPresented: $showsInspector)
                    if store.isForum {
                        ForumTopicSwitcher(topics: store.topics, selected: store.selectedTopic) { store.selectTopic($0) }
                    }
                    if let message = store.sourceError ?? store.loadError {
                        SourceErrorBanner(message: message) { await store.retry() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if store.isStalled {
                        LoadEarlierButton { await store.loadOlder() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 60)
            }
            .padding(.top, Self.toolbarTop)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                ReactionNoticeToast(notice: store.reactionNotice) { store.dismissReactionNotice() }
                    .alignmentGuide(.bottom) { $0[.top] }
            }
            // The soft scroll edge reaches a little past the header, so text dissolves before
            // it meets the pill (Mac Messages' toolbar scroll edge).
            .background(alignment: .top) { ScrollEdgeFade(edge: .top).padding(.bottom, -ScrollEdgeFade.overhang) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            .animation(.snappy, value: store.sourceError ?? store.loadError)
            .animation(.snappy, value: store.isStalled)
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if farFromBottom {
                    Button {
                        scroller.scrollToBottom()
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Scroll to latest message")
                    .transition(.scale.combined(with: .opacity))
                }
                VStack(spacing: 10) {
                    // Omni's drafts, note and "drafting…" chip sit at the end of the conversation.
                    OmniTranscriptAccessory(store: store)
                    if let reply = store.replyTarget {
                        ReplyComposeBanner(message: reply, note: store.replyNote) { store.cancelReply() }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let header = store.emailReply {
                        EmailComposerHeader(reply: header, account: store.emailDetail?.account, replyAll: store.emailReplyAll,
                                            canReplyAll: store.canReplyAll) { store.setEmailReplyAll($0) }
                            .id(store.emailReplyAll) // a fresh Cc expansion per choice
                    }
                    TranscriptComposer(store: store, dropInbox: dropInbox)
                    .id(store.threadID)
                }
                // The last bubble rests one gap above the composer (bottom padding 10 + 12).
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 + Self.composerBottom + Self.composerGap }
            }
            .padding(.bottom, Self.composerBottom)
            // Bubbles scrolling under the composer fade out (the top edge's twin), so they never
            // collide with the typed text.
            .background(alignment: .bottom) {
                ScrollEdgeFade(edge: .bottom).padding(.top, -ScrollEdgeFade.overhang).ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // Mac Messages 26: the lifted bubble, the tapback bar and the menu over everything,
        // the transcript blurred behind. Any resize (window, inspector) closes it.
        // The overlay lives in its own AppKit host over the transcript pane (the table
        // controller's `showOverlay`), so its coordinates are the pane's exactly.
        .onChange(of: overlay?.id) { _, _ in
            guard let c = scroller.controller else { return }
            if let overlay {
                c.showOverlay(AnyView(
                    MessageInteractionOverlay(context: overlay.context, mode: overlay.mode, interactions: .store(store, omni: omni)) {
                        self.overlay = nil
                    }
                    .id(overlay.id)
                    .environment(\.messageEmojiPicker, emojiPicker)
                    .environment(\.omniStore, omni)))
            } else {
                c.hideOverlay()
            }
        }
        .onDisappear { scroller.controller?.hideOverlay() }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in overlay = nil }
        .onChange(of: store.threadID) { overlay = nil }
        // ⌘T: the tapback bar on the newest message from someone else (Mac Messages).
        .background {
            Button("Tapback") {
                if let c = scroller.controller, let id = c.newestReactableID { c.presentOverlay(messageID: id, mode: .tapbacks) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        // The inspector brings the window toolbar into the detail column; keep its band
        // transparent so the header and its circles stay visible over the transcript.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .inspector(isPresented: $showsInspector) {
            InspectorView(thread: store.thread, members: store.members, messages: store.rows.compactMap {
                if case .message(let m, _, _, _) = $0 { m } else { nil }
            }, contact: store.contact)
        }
        .composerDropTarget(dropInbox, enabled: store.canSend && !store.isEmail) // email: text only
        .mediaViewer()
        .sheet(item: Binding(get: { store.emailOriginalRequest }, set: { store.emailOriginalRequest = $0 })) { item in
            EmailOriginalView { try await store.emailOriginal(messageID: item.id) }
        }
        .task(id: store.threadID) { await store.loadLatest() }
    }

    @ViewBuilder private var placeholder: some View {
        if store.rows.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if store.sourceError == nil, store.loadError == nil, !store.isStalled {
                Text("No Messages").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown when paging stopped after many pages with nothing to show (`TimelineStore.isStalled`):
/// automatic prefetch pauses, so loading further back is the reader's choice.
struct LoadEarlierButton: View {
    let load: @MainActor () async -> Void
    var body: some View {
        Button { Task { await load() } } label: {
            Label("Load Earlier Messages", systemImage: "arrow.up")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Phase 1 has no composer: a disabled capsule says what is coming.
/// A 36 pt glass circle in the transcript's toolbar band (kit: XL toolbar button, 36 pt,
/// glyph Medium 13 → 15 here as in Messages). Inert ones say so to VoiceOver.
struct TranscriptToolbarButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let id: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }
}

/// Mac Messages' soft scroll edge under the toolbar band (top) and behind the composer
/// (bottom): the content blurs and fades into the window background toward the edge, so text
/// scrolling under the header or the composer never collides with them. A blur (material) plus
/// the window colour, opaque at the edge (kit: white 85 %) and clear `overhang` past the bar.
struct ScrollEdgeFade: View {
    let edge: VerticalEdge
    static let overhang: CGFloat = 24

    var body: some View {
        let toward: UnitPoint = edge == .top ? .top : .bottom
        let away: UnitPoint = edge == .top ? .bottom : .top
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.85), location: 0.55),
                .init(color: .clear, location: 1),
            ], startPoint: toward, endPoint: away)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The FaceTime circle in the toolbar band as a menu: video calls, then audio calls, then the
/// apps. Hidden when the contact offers no way to call.
struct TranscriptCallMenu: View {
    let options: [CallOption]

    var body: some View {
        let ordered = options.filter { $0.kind == .video } + options.filter { $0.kind == .audio } + options.filter { $0.kind == .app }
        if !ordered.isEmpty {
            Menu {
                CallMenuItems(options: ordered)
            } label: {
                Image(systemName: "video")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .circle)
            .help("FaceTime")
            .accessibilityLabel("FaceTime")
            .accessibilityHint("Shows ways to call")
            .accessibilityIdentifier("transcript-video")
        }
    }
}

/// One showing of the message overlay.
struct OverlayRequest: Identifiable {
    let id = UUID()
    let context: MessageOverlayContext
    let mode: MessageOverlayMode
}

/// Lets SwiftUI controls (the ↓ button) drive the table.
@MainActor
final class TranscriptScroller {
    weak var controller: TranscriptTableController?
    func scrollToBottom() { controller?.scrollToBottom(animated: true) }
}

/// SwiftUI host of `TranscriptTableController`.
struct TranscriptTable: NSViewControllerRepresentable {
    let rows: [TranscriptRow]
    let isGroup: Bool
    let canLoadOlder: Bool
    let olderLoadCount: Int
    let selfSenderIDs: Set<String>
    let topInset: CGFloat
    let bottomInset: CGFloat
    let metrics: BubbleMetrics
    let mediaLoader: MediaLoader
    let scroller: TranscriptScroller
    let sendActions: SendActions
    let interactions: MessageInteractions
    let overlayShown: Bool
    let onPresentOverlay: (MessageOverlayContext, MessageOverlayMode) -> Void
    let onNeedsOlder: () -> Void
    let onFarFromBottomChange: (Bool) -> Void

    func makeNSViewController(context: Context) -> TranscriptTableController {
        let c = TranscriptTableController()
        _ = c.view
        scroller.controller = c
        return c
    }

    func updateNSViewController(_ c: TranscriptTableController, context: Context) {
        scroller.controller = c
        c.onNeedsOlder = onNeedsOlder
        c.onFarFromBottomChange = onFarFromBottomChange
        c.mediaLoader = mediaLoader
        c.sendActions = sendActions
        c.interactions = interactions
        c.overlayShown = overlayShown
        c.onPresentOverlay = onPresentOverlay
        c.setInsets(top: topInset, bottom: bottomInset)
        c.configure(isGroup: isGroup, metrics: metrics, selfSenderIDs: selfSenderIDs)
        // Re-arm before applying rows, so a page that did add rows can prefetch again at once.
        c.noteOlderLoads(olderLoadCount)
        c.apply(rows)
        c.setCanLoadOlder(canLoadOlder)
    }
}
#endif
