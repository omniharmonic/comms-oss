import CommsClient
import Foundation

/// The Details inspector's Photos tab: every picture and video the loaded messages carry,
/// newest first (by `sentAt`; attachments of one message keep their order). Stickers, voice
/// notes, files and attachments with no token to fetch are not photos.
public func mediaItems(from messages: [CommsMessage]) -> [CommsAttachment] {
    newestFirst(messages).flatMap { message in
        message.attachments.filter { attachment in
            (attachment.kind == .image || attachment.kind == .video)
                && (attachment.mediaToken ?? attachment.thumbToken) != nil
        }
    }
}

/// The Links tab: link previews of the loaded messages, newest first, each URL once.
public func linkItems(from messages: [CommsMessage]) -> [CommsLinkPreview] {
    var seen = Set<String>()
    return newestFirst(messages).flatMap(\.linkPreviews).filter { seen.insert($0.url).inserted }
}

private func newestFirst(_ messages: [CommsMessage]) -> [CommsMessage] {
    // Stable: equal send times keep the later-listed (newer in server order) message first.
    messages.enumerated()
        .sorted { ($0.element.sentAt, $0.offset) > ($1.element.sentAt, $1.offset) }
        .map(\.element)
}
