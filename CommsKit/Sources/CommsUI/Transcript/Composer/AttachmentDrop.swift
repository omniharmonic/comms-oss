import CommsClient
import CommsCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Drag and drop (and, on the Mac, ⌘V) into the composer, as in Messages: files from Finder,
/// pictures from Photos, images dragged out of Safari and the screenshot thumbnail become
/// attachment previews in the field — through the same import as the "+" menu, so size,
/// location stripping and refused kinds are checked the same way.
@MainActor
enum AttachmentDrop {
    /// What a drop target accepts. Plain text and links are left to the text field.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .movie, .audio, .pdf]

    /// The content type to read from a provider that is not a file URL (Photos' file promise,
    /// Safari's image data, the screenshot thumbnail): movies, then pictures, PDF, audio — the
    /// provider's own order (best fidelity first) among those.
    static func preferredType(_ registered: [UTType]) -> UTType? {
        for family in [UTType.movie, .image, .pdf, .audio] {
            if let t = registered.first(where: { $0.conforms(to: family) }) { return t }
        }
        return nil
    }

    /// Whether a drop carries anything the composer can attach (the highlight shows only then).
    static func canAttach(_ registered: [UTType]) -> Bool {
        registered.contains { t in acceptedTypes.contains { t.conforms(to: $0) } }
    }

    /// One import per provider (run by the composer, which reports what failed).
    static func jobs(for providers: [NSItemProvider], limit: Int?) -> [@MainActor () async throws -> OutgoingAttachment] {
        providers.map { provider in { try await load(provider, limit: limit) } }
    }

    @MainActor
    static func load(_ provider: NSItemProvider, limit: Int?) async throws -> OutgoingAttachment {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(provider) {
            return try await AttachmentImport.make(fileURL: url, limit: limit)
        }
        guard let type = preferredType(provider.registeredContentTypes) else {
            throw canAttach(provider.registeredContentTypes) ? AttachmentImport.ImportError.unreadable : AttachmentImport.ImportError.unsupportedType
        }
        let copy = try await copyFile(provider, type: type)
        let ext = copy.pathExtension
        let base = provider.suggestedName.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? (type.conforms(to: .movie) ? "Video" : type.conforms(to: .image) ? "Image" : "Attachment")
        return try await AttachmentImport.make(ownedFile: copy, originalName: ext.isEmpty ? base : "\(base).\(ext)", limit: limit)
    }

    /// A Finder / Files item's URL (nil when the provider can't give one).
    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    /// The provider's file (a file promise is fulfilled first) copied into ``OutgoingFiles``:
    /// the system deletes its own copy when the callback returns.
    private static func copyFile(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, any Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return c.resume(throwing: AttachmentImport.ImportError.unreadable) }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                let dest = OutgoingFiles.newURL(extension: ext)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    c.resume(returning: dest)
                } catch {
                    c.resume(throwing: AttachmentImport.ImportError.unreadable)
                }
            }
        }
    }
}

/// Hands drops on the transcript (or the composer) to the composer that shows the previews.
/// The transcript owns one; the composer takes what was delivered.
@MainActor @Observable
public final class ComposerDropInbox {
    /// A drag that the composer could attach is over the conversation (the field highlights).
    public var isTargeted = false
    /// Bumped on every delivery (the composer observes it).
    private(set) var generation = 0
    @ObservationIgnored private var pending: [NSItemProvider] = []

    public init(isTargeted: Bool = false) { self.isTargeted = isTargeted }

    func deliver(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        pending += providers
        generation += 1
    }

    func take() -> [NSItemProvider] {
        defer { pending = [] }
        return pending
    }
}

extension View {
    /// Make this view (the whole conversation column) a drop target for the composer's
    /// attachments. Nothing is accepted while the conversation can't send.
    func composerDropTarget(_ inbox: ComposerDropInbox, enabled: Bool) -> some View {
        modifier(ComposerDropTarget(inbox: inbox, enabled: enabled))
    }
}

private struct ComposerDropTarget: ViewModifier {
    let inbox: ComposerDropInbox
    let enabled: Bool

    func body(content: Content) -> some View {
        content.onDrop(of: AttachmentDrop.acceptedTypes, delegate: Delegate(inbox: inbox, enabled: enabled))
    }

    struct Delegate: DropDelegate {
        let inbox: ComposerDropInbox
        let enabled: Bool

        func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: AttachmentDrop.acceptedTypes) }
        func dropEntered(info: DropInfo) { inbox.isTargeted = validateDrop(info: info) }
        func dropExited(info: DropInfo) { inbox.isTargeted = false }
        func dropUpdated(info: DropInfo) -> DropProposal? { validateDrop(info: info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden) }
        func performDrop(info: DropInfo) -> Bool {
            inbox.isTargeted = false
            guard validateDrop(info: info) else { return false }
            inbox.deliver(info.itemProviders(for: AttachmentDrop.acceptedTypes))
            return true
        }
    }
}

#if os(macOS)
/// ⌘V in the composer on the Mac: files copied in Finder and copied images are attached (as in
/// Messages); anything with text pastes as text.
enum ComposerPaste {
    enum Decision: Equatable { case files, image(UTType), text }

    /// - Parameters: the pasteboard's types, whether it holds file URLs, and its plain string.
    static func decide(types: [NSPasteboard.PasteboardType], hasFileURLs: Bool, string: String?) -> Decision {
        if hasFileURLs { return .files }
        let imageType = types.lazy.compactMap { UTType($0.rawValue) }.first { $0.conforms(to: .image) }
        guard let imageType else { return .text }
        // "Copy Image" in Safari also puts the image's address as text: still a picture. Real
        // text (a selection that happens to include a picture) pastes as text.
        let text = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || isSingleURL(text) ? .image(imageType) : .text
    }

    static func isSingleURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace), let scheme = URL(string: s)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }

    /// The imports for the general pasteboard, or nil to let the field paste text.
    @MainActor
    static func jobs(from pasteboard: NSPasteboard = .general, limit: Int?) -> [@MainActor () async throws -> OutgoingAttachment]? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        switch decide(types: pasteboard.types ?? [], hasFileURLs: !urls.isEmpty, string: pasteboard.string(forType: .string)) {
        case .files:
            return urls.map { url in { try await AttachmentImport.make(fileURL: url, limit: limit) } }
        case .image(let type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { return nil }
            let ext = type.preferredFilenameExtension ?? "png"
            return [{ try AttachmentImport.make(data: data, type: type, filename: "Image.\(ext)", limit: limit) }]
        case .text:
            return nil
        }
    }
}
#endif
