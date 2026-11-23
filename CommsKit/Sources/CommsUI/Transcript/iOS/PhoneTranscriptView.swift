#if os(iOS)
import CommsClient
import CommsCore
import SwiftUI
import UIKit

/// The iOS / iPadOS transcript screen: the flipped collection-view transcript
/// (`PhoneTranscriptController`) under Messages' floating header (60 pt avatar over the glass
/// name pill, which opens Details), the source-error banner, and the composer — inert in
/// Phase 1 (nothing is ever sent). The composer rides the keyboard and the transcript lifts
/// with it.
public struct PhoneTranscriptView: View {
    /// How far the header rises over the inline nav bar so the avatar's top is level with
    /// the back button (y 62 on iPhone 17, as in Messages): the bar's 44 pt plus the 10 pt
    /// gap the system leaves above a top safe-area bar (measured from the ax dump).
    static let navBarHeight: CGFloat = 54
    /// The composer's bottom edge is 28 pt above the screen's, not 34 (the safe area).
    static let composerDrop: CGFloat = 6

    let store: TimelineStore
    /// A second line under the name in the pill (nil = one line).
    let subtitle: String?
    /// Extra content at the top of Details (the DEBUG demo build puts its event injector here).
    let detailsAccessory: AnyView?

    @State private var showsDetails = false
    /// Files, photos and images dropped anywhere on the conversation go to the composer.
    @State private var dropInbox = ComposerDropInbox()
    @Environment(\.mediaLoader) private var mediaLoader
    @Environment(\.avatarLoader) private var avatarLoader
    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.omniStore) private var omni
    @Environment(\.openConversation) private var openConversation

    public init(store: TimelineStore, subtitle: String? = nil, detailsAccessory: AnyView? = nil) {
        self.store = store
        self.subtitle = subtitle
        self.detailsAccessory = detailsAccessory
    }

    public var body: some View {
        GeometryReader { geo in
            PhoneTranscriptHost(
                rows: store.rows,
                caption: store.hasMore ? nil : store.thread?.networks.first?.displayName,
                isGroup: store.isGroup,
                canLoadOlder: store.hasMore && !store.isStalled,
                olderLoadCount: store.olderLoadCount,
                selfSenderIDs: store.selfSenderIDs,
                topInset: geo.safeAreaInsets.top,
                bottomInset: geo.safeAreaInsets.bottom,
                metrics: metrics,
                mediaLoader: mediaLoader,
                avatarLoader: avatarLoader,
                sendActions: .store(store),
                interactions: .store(store, omni: omni),
                onNeedsOlder: { Task { await store.loadOlder() } }
            )
            // Vertical only: on iPad the sidebar is the detail's leading safe area.
            .ignoresSafeArea(edges: .vertical)
        }
        .overlay { placeholder }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                // Messages puts the 60 pt avatar at the top of the nav bar, level with the
                // back button, so the header rises over the (empty) inline bar.
                TranscriptHeader(thread: store.thread, subtitle: subtitle, isInspectorPresented: $showsDetails)
                    .padding(.top, -Self.navBarHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("transcript-header")
                if store.isForum {
                    ForumTopicSwitcher(topics: store.topics, selected: store.selectedTopic) { store.selectTopic($0) }
                }
                if let message = store.sourceError ?? store.loadError {
                    SourceErrorBanner(message: message) { await store.retry() }
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if store.isStalled {
                    LoadEarlierButton { await store.loadOlder() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                ReactionNoticeToast(notice: store.reactionNotice) { store.dismissReactionNotice() }
                    .alignmentGuide(.bottom) { $0[.top] }
            }
            .background(alignment: .top) { HeaderScrollEdge() }
            .animation(.snappy, value: store.sourceError ?? store.loadError)
            .animation(.snappy, value: store.isStalled)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
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
            .animation(.snappy, value: store.replyTarget?.id)
                .padding(.bottom, -Self.composerDrop)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Messages' FaceTime video circle: a menu of every way to call this person
            // (FaceTime, FaceTime Audio, Phone, their apps); absent when there is none.
            let options = CallRoutes.options(contact: store.contact, networks: store.thread?.networks ?? [])
            if !options.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        CallMenuItems(options: options.filter { $0.kind == .video } + options.filter { $0.kind == .audio } + options.filter { $0.kind == .app })
                    } label: { Image(systemName: "video") }
                        .accessibilityLabel("FaceTime")
                        .accessibilityHint("Shows ways to call")
                        .accessibilityIdentifier("transcript-video")
                }
            }
        }
        .inspector(isPresented: $showsDetails) {
            PhoneDetailsView(
                thread: store.thread, members: store.members,
                messages: store.rows.compactMap { if case .message(let m, _, _, _) = $0 { m } else { nil } },
                contact: store.contact,
                accessory: detailsAccessory,
                close: { showsDetails = false })
                // Opening another conversation from the card closes Details first; otherwise the
                // inspector stays up over the new thread with nothing in it (owner, 2026-11-23).
                .environment(\.openConversation, OpenConversationAction { [openConversation] id in
                    showsDetails = false
                    openConversation(id)
                })
                .presentationDragIndicator(.visible)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
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
                ProgressView()
            } else if store.sourceError == nil, store.loadError == nil, !store.isStalled {
                Text("No Messages").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Messages' soft scroll edge behind the floating header: rows passing under it are blurred
/// and fade into the background toward the status bar, rather than showing through sharply
/// (or as a flat block of colour). A material blur that fades out below the name pill, under
/// a background wash that is opaque only at the very top.
struct HeaderScrollEdge: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    // Fades out gradually: a hard material edge read as a grey band in dark mode.
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.8), location: 0.45),
                        .init(color: .clear, location: 0.9),
                    ], startPoint: .top, endPoint: .bottom)
                }
            Rectangle()
                .fill(Color(uiColor: .systemBackground))
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.85), location: 0.45),
                        .init(color: .black.opacity(0.5), location: 0.7),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .padding(.bottom, -18)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shown when paging stopped after many pages with nothing to show (`TimelineStore.isStalled`).
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

/// SwiftUI host of `PhoneTranscriptController`.
struct PhoneTranscriptHost: UIViewControllerRepresentable {
    let rows: [TranscriptRow]
    let caption: String?
    let isGroup: Bool
    let canLoadOlder: Bool
    let olderLoadCount: Int
    let selfSenderIDs: Set<String>
    let topInset: CGFloat
    let bottomInset: CGFloat
    let metrics: BubbleMetrics
    let mediaLoader: MediaLoader
    let avatarLoader: AvatarLoader?
    let sendActions: SendActions
    let interactions: MessageInteractions
    let onNeedsOlder: () -> Void

    func makeUIViewController(context: Context) -> PhoneTranscriptController {
        let c = PhoneTranscriptController()
        _ = c.view
        return c
    }

    func updateUIViewController(_ c: PhoneTranscriptController, context: Context) {
        c.onNeedsOlder = onNeedsOlder
        c.sendActions = sendActions
        c.interactions = interactions
        c.configure(isGroup: isGroup, metrics: metrics, selfSenderIDs: selfSenderIDs, mediaLoader: mediaLoader, avatarLoader: avatarLoader)
        c.setInsets(top: topInset, bottom: bottomInset)
        // Re-arm before applying rows, so a page that did add rows can prefetch again at once.
        c.noteOlderLoads(olderLoadCount)
        c.apply(rows, caption: caption)
        c.setCanLoadOlder(canLoadOlder)
    }
}
#endif
