#if DEBUG
import CommsClient
import CommsCore
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// DEBUG-only design gallery: each row is a Comms render built from a `ChatBackend`'s data
/// (the app passes `FixtureBackend.staging()`) next to the matching Apple Messages reference
/// from `docs/research/refs/`, read from the repo checkout (nothing is bundled). It compiles
/// out of release builds.
///
/// `DesignGallery` loads the data; `DesignGalleryBoard` is the synchronous layout the PNG
/// export in the tests renders (`design/refs/comms-gallery-v0.png`).
public struct DesignGallery: View {
    let backend: any ChatBackend
    let refsDirectory: URL
    @State private var data: GalleryData?
    @State private var failure: String?

    public init(backend: any ChatBackend, refsDirectory: URL = GalleryReferences.repoDirectory) {
        self.backend = backend
        self.refsDirectory = refsDirectory
    }

    public var body: some View {
        Group {
            if let data {
                ScrollView([.vertical]) { DesignGalleryBoard(data: data, refsDirectory: refsDirectory) }
            } else if let failure {
                ContentUnavailableView("Gallery Unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task {
            do { data = try await GalleryData.load(from: backend) } catch { failure = "\(error)" }
        }
    }
}

/// What the scenes draw, loaded from a backend.
public struct GalleryData: Sendable {
    public struct Room: Sendable {
        public var thread: CommsThread
        public var members: [CommsMember]
        public var messages: [CommsMessage]
    }

    public var threads: [CommsThread]
    public var oneToOne: Room
    public var group: Room

    public enum LoadError: Error { case noDM, noGroup }

    /// The first 1:1 titled "Alice Example" (else the first 1:1) and the first group.
    public static func load(from backend: any ChatBackend) async throws -> GalleryData {
        let threads = try await backend.threads(CommsThreadQuery()).threads
        guard let dm = threads.first(where: { $0.kind == .dm && $0.title == "Alice Example" }) ?? threads.first(where: { $0.kind == .dm }) else { throw LoadError.noDM }
        guard let group = threads.first(where: { $0.kind == .group }) else { throw LoadError.noGroup }
        func room(_ thread: CommsThread) async throws -> Room {
            let detail = try await backend.thread(id: thread.id)
            let page = try await backend.messages(threadID: thread.id, before: nil, limit: 50)
            return Room(thread: detail.thread, members: detail.members, messages: page.messages)
        }
        return GalleryData(threads: threads, oneToOne: try await room(dm), group: try await room(group))
    }
}

/// Where the Apple references live.
public enum GalleryReferences {
    /// `<repo>/docs/research/refs`, found from this file's path (DEBUG builds only).
    public static let repoDirectory: URL = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/research/refs", isDirectory: true)

    static func image(_ name: String, crop: CGRect?, in directory: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        guard let crop else { return image }
        return image.cropping(to: crop)
    }
}

/// The gallery layout: a title, then one row per scene, Comms left and Apple right.
public struct DesignGalleryBoard: View {
    let data: GalleryData
    let refsDirectory: URL
    var scheme: ColorScheme = .light

    public init(data: GalleryData, refsDirectory: URL = GalleryReferences.repoDirectory) {
        self.data = data
        self.refsDirectory = refsDirectory
    }

    static let panelWidth: CGFloat = 390
    /// The minimum panel height; panels grow to fit their content.
    static let panelHeight: CGFloat = 480

    struct Scene: Identifiable {
        let id: String
        let title: String
        let note: String
        let reference: String
        let crop: CGRect?
        let ours: AnyView
    }

    private var scenes: [Scene] {
        let guideTranscript = "macos26-guide-window-sidebar-transcript.png"
        return [
            Scene(id: "sidebar", title: "Sidebar", note: "Apple: macOS 26 guide, sidebar crop", reference: guideTranscript,
                  crop: CGRect(x: 0, y: 0, width: 270, height: 612), ours: AnyView(sidebar)),
            Scene(id: "transcript-1to1", title: "Transcript, 1:1", note: "Apple: macOS 26 guide, transcript column", reference: guideTranscript,
                  crop: CGRect(x: 262, y: 0, width: 552, height: 612), ours: AnyView(transcript(data.oneToOne, last: 9))),
            Scene(id: "transcript-group", title: "Transcript, group with avatars", note: "Apple: iOS 26 guide, group details (closest group reference; Mac group transcript not available)",
                  reference: "ios26-guide-group-details.png", crop: nil, ours: AnyView(transcript(data.group, last: 9))),
            Scene(id: "tapbacks", title: "Tapbacks", note: "Apple: iOS 26 guide, tapback on a photo (Comms: classic monochrome tapbacks)",
                  reference: "ios26-guide-sms-transcript-audio-photo-tapback.png", crop: nil,
                  ours: AnyView(transcript(data.oneToOne, around: { !$0.reactions.isEmpty }, before: 1, after: 1))),
            Scene(id: "link-preview", title: "Link preview and photo", note: "Apple: iOS 26 guide, 1:1 transcript (no link-card reference exists in refs)",
                  reference: "ios26-guide-transcript-1to1-add-button.png", crop: nil,
                  ours: AnyView(transcript(data.oneToOne, around: { !$0.linkPreviews.isEmpty }, before: 2, after: 1))),
            Scene(id: "message-menu", title: "Message menu and reactions",
                  note: "Apple: iOS 26 guide, tapback on a photo (Comms: long-press bar + menu, who-reacted list; glass drawn live only)",
                  reference: "ios26-guide-sms-transcript-audio-photo-tapback.png", crop: nil, ours: AnyView(messageMenu)),
            Scene(id: "inspector", title: "Details inspector", note: "Apple: macOS 26 guide, group info",
                  reference: "macos26-guide-group-info-view.png", crop: nil, ours: AnyView(inspector)),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Comms design gallery v0").font(.system(size: 26, weight: .bold))
                Text("Left: Comms at Mac sizes, rendered from the staging fixtures. Right: Apple Messages reference. Compare by eye; owner sign-off pending.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(scenes) { scene in
                VStack(alignment: .leading, spacing: 8) {
                    Text(scene.title).font(.system(size: 17, weight: .semibold))
                    HStack(alignment: .top, spacing: 24) {
                        panel(caption: "Comms") {
                            // Sized to its content (never a fixed height that squeezes the
                            // bubbles), at least `panelHeight` so rows line up.
                            scene.ours
                                .environment(\.bubbleMetrics, .mac)
                                .environment(\.mediaLoader, .placeholder)
                                .environment(\.colorScheme, scheme)
                                .frame(width: Self.panelWidth, alignment: .top)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: Self.panelHeight, alignment: .top)
                                .background(scheme == .dark ? Color.black : Color.white)
                        }
                        panel(caption: scene.note) { reference(scene) }
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 2 * Self.panelWidth + 24 + 64, alignment: .leading)
        .background(Color(white: 0.93))
        .environment(\.colorScheme, .light)
    }

    /// The long-press menu's pieces around a message of the 1:1 room (with its reactions, or a
    /// synthetic ❤️ from "Alex" and the owner when it has none), and who reacted.
    private var menuMessage: CommsMessage? {
        let messages = layout(data.oneToOne).compactMap { if case .message(let m, _, _, _) = $0 { m } else { nil } }
        guard var m = messages.last(where: { !$0.reactions.isEmpty }) ?? messages.last(where: { !$0.sender.isSelf }) ?? messages.last else { return nil }
        if m.reactions.isEmpty {
            m.reactions = [CommsReaction(key: "❤️", count: 2, mine: true, senders: [.init(id: "self", name: "You"), .init(id: "@alex", name: "Alex")])]
        }
        return m
    }

    @ViewBuilder private var messageMenu: some View {
        if let m = menuMessage {
            VStack(alignment: m.sender.isSelf ? .trailing : .leading, spacing: 10) {
                TapbackPicker(selected: Set(m.reactions.filter(\.mine).map(\.key))) { _ in }
                MessageBubble(message: m, position: .single, isGroup: false)
                    .environment(\.bubbleMaxWidth, 280)
                MessageActionMenu(groups: [[.init(kind: .reply)], [.init(kind: .copy), .init(kind: .translate), .init(kind: .select)]]) { _ in }
                ReactionDetailsView(people: ReactionOverlay.people(m.reactions, selfIDs: []), compact: false)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: m.sender.isSelf ? .trailing : .leading)
        }
    }

    private func panel<C: View>(caption: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
                .overlay(Rectangle().stroke(Color.black.opacity(0.12), lineWidth: 1))
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: Self.panelWidth, alignment: .leading)
        }
    }

    @ViewBuilder private func reference(_ scene: Scene) -> some View {
        if let image = GalleryReferences.image(scene.reference, crop: scene.crop, in: refsDirectory) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(width: Self.panelWidth)
                .frame(minHeight: Self.panelHeight, alignment: .top)
                .background(Color.white)
        } else {
            Text("Missing reference\n\(scene.reference)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: Self.panelWidth, height: Self.panelHeight)
                .background(Color.white)
        }
    }

    // MARK: Comms scenes

    private var sidebar: some View {
        let now = data.threads.map(\.lastActivityAt).max() ?? Date()
        return SidebarContent(pinned: data.threads.filter(\.pinned), threads: data.threads.filter { !$0.pinned },
                              selection: data.oneToOne.thread.id, now: now, onSelect: { _ in }, onReachEnd: {})
            .frame(width: 270)
            .padding(.top, 8)
            .frame(width: Self.panelWidth, alignment: .leading)
    }

    private func transcript(_ room: GalleryData.Room, last: Int) -> some View {
        let rows = layout(room)
        return transcriptView(Array(rows.suffix(last)), isGroup: room.thread.kind == .group)
    }

    private func transcript(_ room: GalleryData.Room, around match: (CommsMessage) -> Bool, before: Int, after: Int) -> some View {
        let rows = layout(room)
        let messageIndexes = rows.indices.filter { if case .message = rows[$0] { true } else { false } }
        let hit = messageIndexes.first { i in if case .message(let m, _, _, _) = rows[i] { match(m) } else { false } } ?? messageIndexes.last ?? 0
        let pos = messageIndexes.firstIndex(of: hit) ?? 0
        let from = messageIndexes[max(0, pos - before)], to = messageIndexes[min(messageIndexes.count - 1, pos + after)]
        return transcriptView(Array(rows[from...to]), isGroup: room.thread.kind == .group)
    }

    private func layout(_ room: GalleryData.Room) -> [TranscriptRow] {
        TranscriptLayout.rows(for: room.messages.filter { ($0.body?.plain.count ?? 0) < 200 && ($0.body != nil || !$0.attachments.isEmpty || !$0.linkPreviews.isEmpty || $0.system != nil) },
                              isGroup: room.thread.kind == .group, gapMinutes: Tokens.transcript.timeHeaderGapMinutes, calendar: .current)
    }

    private func transcriptView(_ rows: [TranscriptRow], isGroup: Bool) -> some View {
        let metrics = BubbleMetrics.mac
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                TranscriptRowView(
                    row: row,
                    context: TranscriptRowContext(
                        isGroup: isGroup,
                        spacingAbove: TranscriptRowView.spacingAbove(row, after: i > 0 ? rows[i - 1] : nil, metrics: metrics)))
            }
        }
        .environment(\.bubbleMaxWidth, (Self.panelWidth - 2 * TranscriptRowView.sideMargin) * metrics.maxWidthRatio)
        .padding(.bottom, 12)
    }

    private var inspector: some View {
        InspectorContent(thread: data.group.thread, members: data.group.members, messages: data.group.messages)
            .padding(.horizontal, 16)
            .frame(width: Self.panelWidth)
    }
}
#endif
