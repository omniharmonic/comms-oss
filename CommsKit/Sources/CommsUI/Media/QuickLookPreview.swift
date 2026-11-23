import CommsClient
import CommsCore
import Foundation
import Observation
import QuickLook
#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers

/// Media bytes straight from the authenticated backend (`ChatBackend.media(token:)`): bytes
/// and `Content-Type`. Quick Look needs the original file, not a decoded image, so it has its
/// own seam next to `MediaLoader`. There is no URL path: the server refuses plain URL loads.
public struct MediaFetcher: Sendable {
    public var fetch: @Sendable (String) async throws -> (Data, String)
    /// Fresh tokens for expired ones (`ChatBackend.refreshMedia`); `[:]` = cannot refresh.
    public var refresh: @Sendable ([String]) async throws -> [String: String]
    /// A voice / audio message in a form AVFoundation plays (`ChatBackend.playableAudio`).
    public var playableAudio: @Sendable (String) async throws -> (Data, String)
    /// Pending attachments (`local-…` tokens) are answered from this device, never fetched.
    public init(fetch: @escaping @Sendable (String) async throws -> (Data, String),
                refresh: @escaping @Sendable ([String]) async throws -> [String: String] = { _ in [:] },
                playableAudio: (@Sendable (String) async throws -> (Data, String))? = nil) {
        let local: @Sendable (String, @Sendable (String) async throws -> (Data, String)) async throws -> (Data, String) = { token, remote in
            guard LocalMedia.isLocal(token) else { return try await remote(token) }
            guard let data = LocalMedia.data(for: token) else { throw FetchError.unavailable }
            return (data, "application/octet-stream")
        }
        self.fetch = { try await local($0, fetch) }
        self.refresh = refresh
        let audio = playableAudio ?? fetch
        self.playableAudio = { try await local($0, audio) }
    }

    /// `fetch`, `refresh` and `playableAudio` over a backend.
    public init(backend: any ChatBackend) {
        self.init(fetch: { try await backend.media(token: $0) }, refresh: { try await backend.refreshMedia(tokens: $0) },
                  playableAudio: { try await backend.playableAudio(token: $0) })
    }

    public enum FetchError: Error { case unavailable }
    public static let none = MediaFetcher { _ in throw FetchError.unavailable }
}

extension EnvironmentValues {
    /// Fetches full media for Quick Look.
    @Entry public var mediaFetcher: MediaFetcher = .none
}

/// "Open this picture or video in Quick Look". Bubbles live in AppKit table cells that do not
/// inherit the SwiftUI environment, so the request goes through this one shared object;
/// `.mediaViewer()` (on the transcript) observes it and presents the panel.
@MainActor @Observable
public final class MediaViewer {
    public static let shared: MediaViewer = {
        let viewer = MediaViewer()
        QuickLookTempFile.sweep() // leftovers of a crash
        #if os(macOS)
        viewer.terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in QuickLookTempFile.sweep() }
        #endif
        return viewer
    }()

    /// VoiceOver hint on a tappable photo / video.
    #if os(iOS)
    public static let openHint = "Opens full screen"
    #else
    public static let openHint = "Opens Quick Look"
    #endif

    public struct Request: Identifiable, Equatable {
        public let id = UUID()
        public let attachment: CommsAttachment
    }

    public private(set) var request: Request?
    /// The `.mediaViewer()` modifiers on screen, innermost (most recently shown) last. Only the
    /// last one presents, so a photo tapped in the Details sheet opens over the sheet, not
    /// under it on the transcript.
    private(set) var presenters: [UUID] = []

    init() {}

    func register(_ id: UUID) { if !presenters.contains(id) { presenters.append(id) } }
    func unregister(_ id: UUID) { presenters.removeAll { $0 == id } }
    @ObservationIgnored private var terminateObserver: (any NSObjectProtocol)?

    public func open(_ attachment: CommsAttachment) {
        guard attachment.mediaToken ?? attachment.thumbToken != nil else { return }
        request = Request(attachment: attachment)
    }

    func take() -> Request? {
        defer { request = nil }
        return request
    }
}

/// Quick Look reads files, so the bytes go to a temporary file that is deleted when the
/// panel closes (and any left by a crash are swept on the next launch of the viewer).
enum QuickLookTempFile {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("comms-quicklook", isDirectory: true) }

    /// Writes `data` into a fresh directory; `baseName` is generic (never the sender's file name) and the extension keeps a type-correct extension so
    /// Quick Look picks the right previewer.
    static func write(_ data: Data, contentType: String, baseName: String) throws -> URL {
        let ext = UTType(mimeType: MediaFileType.baseMime(contentType))?.preferredFilenameExtension ?? "bin"
        return try write(data, ext: ext, baseName: baseName)
    }

    static func write(_ data: Data, ext: String, baseName: String) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(baseName).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes the directory `write` made for `url`.
    static func remove(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func sweep() { try? FileManager.default.removeItem(at: root) }
}

/// A fetched attachment written to its temporary file.
struct PreparedMedia: Equatable {
    var url: URL
    var type: UTType
}

/// Fetches an attachment's full bytes through `fetch` and writes the viewer's temp file, typed
/// from the bytes (`MediaFileType`). An expired token (410, a transcript left open for hours)
/// is exchanged for a fresh one once (`MediaFetcher.refresh`) before giving up.
/// Not tied to any view's task, so handing the request over cannot cancel it.
enum QuickLookPreparer {
    static func token(for a: CommsAttachment) -> String? {
        (a.kind == .video ? a.mediaToken : (a.mediaToken ?? a.thumbToken)) ?? a.thumbToken
    }

    static func prepare(_ a: CommsAttachment, fetch: MediaFetcher) async throws -> URL? {
        try await prepareTyped(a, fetch: fetch)?.url
    }

    static func prepareTyped(_ a: CommsAttachment, fetch: MediaFetcher) async throws -> PreparedMedia? {
        guard let token = token(for: a) else { return nil }
        let (data, served) = try await fetchRefreshing(token, fetch: fetch)
        if Task.isCancelled { return nil }
        let type = MediaFileType.resolve(data: data, served: served, declared: a.mime, name: a.name)
        let url = try QuickLookTempFile.write(data, ext: MediaFileType.fileExtension(type), baseName: a.kind == .video ? "Video" : "Photo")
        return PreparedMedia(url: url, type: type)
    }

    /// `fetch(token)`; on `mediaExpired`, one refresh and one retry with the fresh token.
    static func fetchRefreshing(_ token: String, fetch: MediaFetcher) async throws -> (Data, String) {
        do {
            return try await fetch.fetch(token)
        } catch CommsError.mediaExpired {
            guard let fresh = (try? await fetch.refresh([token]))?[token], fresh != token else { throw CommsError.mediaExpired }
            return try await fetch.fetch(fresh)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// The one Quick Look fetch in flight. A new request cancels the previous one (no
/// last-finish-wins), `cancel()` stops it when the transcript goes away, and a cancelled
/// fetch never delivers or leaves a temp file behind.
@MainActor
final class QuickLookFetch {
    private(set) var task: Task<Void, Never>?
    private var generation = 0

    /// Fetch `a` and hand its temp file to `ready`, or a message to `failed`.
    func start(_ a: CommsAttachment, fetcher: MediaFetcher, ready: @escaping @MainActor (URL) -> Void, failed: @escaping @MainActor (String) -> Void) {
        task?.cancel()
        generation += 1
        let gen = generation
        task = Task {
            do {
                let url = try await QuickLookPreparer.prepare(a, fetch: fetcher)
                guard let url else {
                    // No token to fetch: say so rather than doing nothing.
                    if !Task.isCancelled, gen == self.generation { failed(MediaOpenFailure.message(for: CommsError.mediaExpired, kind: a.kind)) }
                    return
                }
                guard !Task.isCancelled, gen == self.generation else { return QuickLookTempFile.remove(url) }
                ready(url)
            } catch {
                if QuickLookPreparer.isCancellation(error) || Task.isCancelled || gen != self.generation { return }
                failed(MediaOpenFailure.message(for: error, kind: a.kind))
            }
            if gen == self.generation { self.task = nil }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }
}

#if os(iOS)
/// iPhone / iPad: Messages' own full-screen viewer (`PhoneMediaViewerController`) — it opens at
/// once over the thumbnail, swipes down to close with the picture following the finger, and
/// shows an error with Try Again instead of nothing. (SwiftUI's `quickLookPreview` opened only
/// after the whole download, with no progress, and its sheet fought the swipe to close.)
struct MediaViewerModifier: ViewModifier {
    @Environment(\.mediaFetcher) private var fetcher
    @Environment(\.mediaLoader) private var loader
    @State private var id = UUID()
    private let viewer = MediaViewer.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                viewer.register(id)
                VoicePlayer.shared.fetcher = fetcher
            }
            .onDisappear {
                viewer.unregister(id)
                VoicePlayer.shared.stop()
            }
            .onChange(of: viewer.request) { _, new in
                guard new != nil, viewer.presenters.last == id, let request = viewer.take() else { return }
                PhoneMediaViewerController.present(request.attachment, fetcher: fetcher, loader: loader)
            }
            .modifier(VoiceFailureAlert())
    }
}
#else
struct MediaViewerModifier: ViewModifier {
    @Environment(\.mediaFetcher) private var fetcher
    @State private var fileURL: URL?
    @State private var failure: String?
    @State private var fetch = QuickLookFetch()
    @State private var id = UUID()
    private let viewer = MediaViewer.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                viewer.register(id)
                VoicePlayer.shared.fetcher = fetcher
            }
            .quickLookPreview($fileURL)
            .onChange(of: fileURL) { old, new in
                if new == nil, let old { QuickLookTempFile.remove(old) }
            }
            .onDisappear {
                viewer.unregister(id)
                VoicePlayer.shared.stop()
                fetch.cancel()
                if let fileURL { QuickLookTempFile.remove(fileURL); self.fileURL = nil }
            }
            .onChange(of: viewer.request) { _, new in
                // Copy the request out and clear the shared slot; a newer request cancels
                // the fetch still in flight.
                guard new != nil, viewer.presenters.last == id, let request = viewer.take() else { return }
                fetch.start(request.attachment, fetcher: fetcher, ready: { url in
                    if let old = fileURL { QuickLookTempFile.remove(old) }
                    fileURL = url
                }, failed: { failure = $0 })
            }
            .alert("Can't Open Media", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .modifier(VoiceFailureAlert())
    }
}
#endif

/// "Can't Play Audio Message" — a voice message that could not be played always says why.
struct VoiceFailureAlert: ViewModifier {
    private let player = VoicePlayer.shared
    func body(content: Content) -> some View {
        content.alert("Can't Play Audio Message", isPresented: Binding(get: { player.failure != nil }, set: { if !$0 { player.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.failure ?? "")
        }
    }
}

extension View {
    /// Presents `MediaViewer.shared.open(_:)` requests — Quick Look on the Mac, the full-screen
    /// photo / video viewer on iPhone and iPad — fetching bytes through `\.mediaFetcher`.
    public func mediaViewer() -> some View { modifier(MediaViewerModifier()) }
}

