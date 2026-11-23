import CommsClient
import CommsCore
import CoreGraphics
import Foundation
import ImageIO
import PrismTransport
import UniformTypeIdentifiers

/// What a fetched attachment really is, for the temporary file the viewer (Quick Look on the
/// Mac, the photo viewer on iPhone) opens. Order: the BYTES (ImageIO / ISO-BMFF / PDF magic),
/// then the server's served type (the media route serves the type it sniffed), then the
/// attachment's declared mime, then its file name. Owner report: a photo BlueBubbles had
/// converted HEIC → JPEG was written as `Photo.heic` from the declared mime, and anything the
/// declared mime did not name (octet-stream, odd PNG types) became `Photo.bin`, which opens
/// as a blank document.
public enum MediaFileType {
    public static func resolve(data: Data, served: String?, declared: String?, name: String?) -> UTType {
        if let sniffed = sniff(data) { return sniffed }
        for mime in [served, declared] {
            guard let base = mime.map(baseMime), !base.isEmpty, base != "application/octet-stream", base != "binary/octet-stream",
                  let type = UTType(mimeType: base) else { continue }
            return type
        }
        if let ext = name.map({ ($0 as NSString).pathExtension }), !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type }
        return .data
    }

    /// The type the bytes themselves say, or nil.
    public static func sniff(_ data: Data) -> UTType? {
        let head = [UInt8](data.prefix(64))
        if head.count >= 12, head[4...7].elementsEqual(Array("ftyp".utf8)) {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if ["heic", "heix", "heim", "heis", "hevc", "hevx"].contains(brand) { return .heic }
            if brand == "avif" || brand == "avis" { return UTType("public.avif") ?? imageIOType(data) }
            if brand == "mif1" || brand == "msf1" { return imageIOType(data) ?? .heif }
            if brand == "qt  " { return .quickTimeMovie }
            if ["M4A ", "M4B "].contains(brand) { return .mpeg4Audio }
            return .mpeg4Movie
        }
        if head.starts(with: Array("%PDF-".utf8)) { return .pdf }
        return imageIOType(data)
    }

    private static func imageIOType(_ data: Data) -> UTType? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let id = CGImageSourceGetType(src) as String?, let type = UTType(id), type.conforms(to: .image) else { return nil }
        return type
    }

    static func baseMime(_ s: String) -> String {
        (s.split(separator: ";").first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The extension the temporary file gets (never "bin" for something ImageIO can read).
    public static func fileExtension(_ type: UTType) -> String {
        if type == .heic { return "heic" }
        return type.preferredFilenameExtension ?? "bin"
    }
}

/// The message a viewer shows when an attachment cannot be opened — always something, never
/// a silent no-op (owner report: "it won't open at all").
public enum MediaOpenFailure {
    public static func message(for error: any Error, kind: CommsAttachmentKind) -> String {
        let noun = kind == .video ? "video" : "photo"
        if let c = error as? CommsError {
            switch c {
            case .mediaExpired, .threadUnavailable: return "This \(noun) is no longer available."
            default: break
            }
        }
        if let e = error as? PrismError {
            switch e {
            case .decoding(let why) where why.contains("too large"): return "This \(noun) is too large to open."
            case .unreachable, .outcomeUnknown: return "Couldn't load this \(noun). Check your connection and try again."
            case .notSignedIn, .signedOut, .unauthorized: return "Sign in again to open this \(noun)."
            default:
                if let status = e.httpStatus, status == 404 || status == 410 { return "This \(noun) is no longer available." }
                if e.httpStatus == 415 { return "This \(noun) can't be shown." }
            }
        }
        if error is URLError { return "Couldn't load this \(noun). Check your connection and try again." }
        if let u = error as? MediaUndecodable { return "This \(u.video ? "video" : "photo") can't be shown." }
        return "Couldn't load this \(noun)."
    }
}

/// The bytes arrived but are not a picture (or video) this device can show.
public struct MediaUndecodable: Error, Equatable { public var video = false }

/// The interactive swipe-to-dismiss of the full-screen viewer, as Photos and Messages do it:
/// the picture follows the finger, shrinks a little and the background fades; let go past a
/// distance (or flick) and it closes, otherwise it springs back.
public enum MediaDismissal {
    /// Drag distance (pt) that commits the dismissal on release.
    public static let distance: CGFloat = 110
    /// Downward flick speed (pt/s) that commits it however short the drag.
    public static let flickVelocity: CGFloat = 900

    /// 0 … 1 over a drag of `height` points (either direction; Photos lets you push up too).
    public static func progress(translation: CGSize, height: CGFloat) -> CGFloat {
        let h = max(1, height * 0.5)
        return min(1, abs(translation.height) / h)
    }

    /// The picture's scale for `progress` (down to 0.75, like Photos).
    public static func scale(progress: CGFloat) -> CGFloat { 1 - 0.25 * min(1, max(0, progress)) }

    /// The background's opacity for `progress` (fades out by about half way).
    public static func backgroundAlpha(progress: CGFloat) -> CGFloat { max(0, 1 - min(1, max(0, progress)) * 1.6) }

    /// Close on release? A long enough drag, or a flick in the direction of the drag.
    public static func shouldDismiss(translation: CGSize, velocity: CGSize) -> Bool {
        let towards = translation.height >= 0 ? velocity.height : -velocity.height // + = moving further out
        if abs(translation.height) > distance { return towards > -300 } // unless flung back
        return towards > flickVelocity
    }

    /// Does a pan with this velocity start a dismissal (rather than being left to the zoomed
    /// picture's scrolling or a video's scrubber)? Mostly vertical, and only when not zoomed.
    public static func begins(velocity: CGSize, zoomed: Bool) -> Bool {
        !zoomed && abs(velocity.height) > abs(velocity.width) * 1.2
    }
}
