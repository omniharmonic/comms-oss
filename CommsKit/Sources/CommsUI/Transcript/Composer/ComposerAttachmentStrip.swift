import CommsClient
import CommsCore
import SwiftUI

/// Picked attachments inside the composer field, above the text (as in Messages): pictures as
/// rounded thumbnails, videos and files as tiles, each with a small ✕ to remove it.
struct ComposerAttachmentStrip: View {
    let attachments: [OutgoingAttachment]
    let height: CGFloat
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    ComposerAttachmentTile(attachment: a, height: height)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(a.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(.black.opacity(0.55)))
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .accessibilityLabel("Remove \(a.filename)")
                            .accessibilityIdentifier("composer-attachment-remove")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Self.label(a))
                        .accessibilityIdentifier("composer-attachment")
                }
            }
        }
        .scrollClipDisabled()
        .frame(height: height)
    }

    static func label(_ a: OutgoingAttachment) -> String {
        switch a.kind {
        case .image: "Photo"
        case .video: "Video"
        case .voice: "Audio message"
        case .file: a.filename
        }
    }
}

struct ComposerAttachmentTile: View {
    let attachment: OutgoingAttachment
    let height: CGFloat

    var body: some View {
        if attachment.kind == .image, let image = Self.thumbnail(attachment) {
            let aspect = CGFloat(image.cgImage.width) / CGFloat(max(1, image.cgImage.height))
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: min(height * 1.6, max(height * 0.6, height * aspect)), height: height)
                .clipShape(.rect(cornerRadius: 12))
        } else {
            HStack(spacing: 8) {
                Image(systemName: attachment.kind == .video ? "film" : "doc.fill")
                    .font(.system(size: height * 0.3))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 16)
            }
            .padding(.horizontal, 10)
            .frame(width: height * 2.4, height: height, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        }
    }

    /// Thumbnails are decoded once per attachment (the composer redraws on every keystroke).
    private static let cache = NSCache<NSUUID, MediaImage>()

    static func thumbnail(_ a: OutgoingAttachment) -> MediaImage? {
        if let hit = cache.object(forKey: a.id as NSUUID) { return hit }
        guard let image = MediaImage(data: a.data, maxPixelSize: 320) else { return nil }
        cache.setObject(image, forKey: a.id as NSUUID)
        return image
    }
}
