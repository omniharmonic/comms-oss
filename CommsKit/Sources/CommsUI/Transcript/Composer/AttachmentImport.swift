import AVFoundation
import CommsClient
import CommsCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreTransferable

/// Turns what the owner picked (Photos, Files, Camera) into an `OutgoingAttachment`, or says
/// why it can't be attached. Privacy and size are checked here, before anything is sent:
///
/// - Size: a file over the server's cap (`capabilities.send.maxAttachmentBytes`) is refused
///   from its size on disk, before its bytes are read.
/// - Pictures lose their location. JPEG/PNG keep their pixels (the metadata is copied without
///   GPS); everything else — HEIC/HEIF (the server refuses it), WebP, TIFF… — is re-encoded
///   to JPEG with no metadata at all. The result is checked for any remaining location (EXIF
///   GPS, IPTC, XMP); if it still has one it falls back to the metadata-free JPEG, and if that
///   fails too the picture is REFUSED (fails closed: the original is never sent).
/// - Videos are re-exported without re-encoding (`AVAssetExportSession` passthrough) through
///   the sharing metadata filter, which drops location and personal metadata; the export is
///   checked and a video that still carries a location is refused.
/// - Videos and files go to a temporary file (``OutgoingFiles``) and are streamed when sent.
public enum AttachmentImport {
    public enum ImportError: Error, Equatable, LocalizedError {
        case tooLarge(limit: Int)
        case locationNotRemovable
        case unreadable
        /// A folder (or a package such as a .pages document), which is not one file.
        case folder
        /// A kind the server refuses (web pages, SVG, programs and scripts).
        case unsupportedType
        /// More than ``AttachmentImport/maxPerMessage`` items in the composer.
        case tooMany(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                "This file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)), the most this conversation can send."
            case .locationNotRemovable:
                "Comms couldn't remove the location from this item, so it wasn't attached."
            case .unreadable:
                "This item couldn't be read. If it's in iCloud, download it first."
            case .folder:
                "Folders can't be attached. Attach the files inside it instead."
            case .unsupportedType:
                "Web pages, SVG images, programs and scripts can't be sent."
            case .tooMany(let limit):
                "You can attach up to \(limit) items to one message."
            }
        }
    }

    /// Pictures whose pixels are kept (metadata rewritten without location). GIF keeps its
    /// animation when it carries no location. Anything else is re-encoded to JPEG.
    static let losslessImages: Set<String> = ["image/jpeg", "image/png"]

    /// The most items one message carries (the Photos picker's limit too).
    public static let maxPerMessage = 10

    /// Kinds the server refuses outright (`classifyAttachment`: active content, programs):
    /// refused here, before anything is read or sent.
    static func isRefusedType(_ type: UTType) -> Bool {
        [UTType.svg, .html, .javaScript, .executable, .applicationBundle, .application, .shellScript, .unixExecutable, .diskImage]
            .contains { type.conforms(to: $0) }
    }

    // MARK: In memory (pictures from Photos / Camera)

    /// A picture (or anything small) given as bytes.
    public static func make(data: Data, type: UTType?, filename: String?, limit: Int? = nil) throws -> OutgoingAttachment {
        guard !data.isEmpty else { throw ImportError.unreadable }
        if let limit, data.count > limit { throw ImportError.tooLarge(limit: limit) }
        let type = type ?? filename.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data
        let name = named(filename, type: type)
        if type.conforms(to: .image), pixelSize(data) != nil {
            return try picture(data: data, type: type, name: name)
        }
        let kind: CommsOutgoingKind = type.conforms(to: .movie) || type.conforms(to: .video) ? .video : .file
        if kind == .video {
            // A video must go through the location filter, which works on files.
            throw ImportError.locationNotRemovable
        }
        return OutgoingAttachment(kind: .file, data: data, mime: type.preferredMIMEType ?? "application/octet-stream", filename: name)
    }

    /// The picture pipeline; `strip` / `encode` are injectable so tests can force failures.
    static func picture(
        data: Data, type: UTType, name: String,
        strip: (Data) -> Data? = { withoutLocation($0) },
        encode: (Data) -> (data: Data, width: Int, height: Int)? = { jpeg(from: $0) }
    ) throws -> OutgoingAttachment {
        let mime = type.preferredMIMEType ?? "application/octet-stream"
        let base = (name as NSString).deletingPathExtension
        if losslessImages.contains(mime) || (mime == "image/gif" && !containsLocation(data)) {
            let candidate = mime == "image/gif" ? data : strip(data)
            if let candidate, !containsLocation(candidate), let size = pixelSize(candidate) {
                return OutgoingAttachment(kind: .image, data: candidate, mime: mime, filename: name, pixelWidth: size.0, pixelHeight: size.1)
            }
            // A PNG whose metadata can't be rewritten: the same pixels as a metadata-free PNG
            // (keeps transparency).
            if mime == "image/png", let png = metadataFreePNG(data), !containsLocation(png), let size = pixelSize(png) {
                return OutgoingAttachment(kind: .image, data: png, mime: mime, filename: name, pixelWidth: size.0, pixelHeight: size.1)
            }
        }
        // Re-encode: a JPEG with no metadata at all. Never fall back to the original.
        guard let j = encode(data), !containsLocation(j.data) else { throw ImportError.locationNotRemovable }
        return OutgoingAttachment(kind: .image, data: j.data, mime: "image/jpeg", filename: base + ".jpg", pixelWidth: j.width, pixelHeight: j.height)
    }

    // MARK: From a file (Files, Photos' file representation, Camera videos)

    /// Read a file the owner picked (inside its security scope, coordinated so iCloud items
    /// download first). Pictures are read into memory (after the size check); videos and other
    /// files are copied — or, for videos, re-exported without location — to a temporary file.
    public static func make(fileURL url: URL, limit: Int? = nil) async throws -> OutgoingAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true {
            // A package with a refused kind (an .app) says why; any other folder is a folder.
            if let type = values?.contentType, isRefusedType(type) { throw ImportError.unsupportedType }
            throw ImportError.folder
        }
        if let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension), isRefusedType(type) { throw ImportError.unsupportedType }
        let ext = url.pathExtension
        // Coordinated copy into our temp directory (downloads a File Provider item first).
        let copy = OutgoingFiles.newURL(extension: ext)
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading], error: &coordinationError) { readable in
            do {
                let size = (try readable.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                if let limit, size > limit { throw ImportError.tooLarge(limit: limit) }
                try FileManager.default.copyItem(at: readable, to: copy)
            } catch {
                copyError = error
            }
        }
        if let e = copyError as? ImportError { throw e }
        guard coordinationError == nil, copyError == nil else {
            OutgoingFiles.remove(copy)
            throw ImportError.unreadable
        }
        do {
            return try await make(ownedFile: copy, originalName: url.lastPathComponent, limit: limit)
        } catch {
            OutgoingFiles.remove(copy)
            throw error
        }
    }

    /// A file already in ``OutgoingFiles`` (ours to keep or delete).
    public static func make(ownedFile file: URL, originalName: String, limit: Int?) async throws -> OutgoingAttachment {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        guard size > 0 else { throw ImportError.unreadable }
        if let limit, size > limit { throw ImportError.tooLarge(limit: limit) }
        let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: file.pathExtension) ?? .data
        if isRefusedType(type) {
            OutgoingFiles.remove(file)
            throw ImportError.unsupportedType
        }
        let name = named(originalName, type: type)
        if type.conforms(to: .image) {
            guard let data = try? Data(contentsOf: file) else { throw ImportError.unreadable }
            OutgoingFiles.remove(file)
            if pixelSize(data) != nil { return try picture(data: data, type: type, name: name) }
            return OutgoingAttachment(kind: .file, data: data, mime: type.preferredMIMEType ?? "application/octet-stream", filename: name)
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            let clean = try await videoWithoutLocation(file)
            OutgoingFiles.remove(file)
            let asset = AVURLAsset(url: clean)
            let duration = (try? await asset.load(.duration)).map { Int(($0.seconds * 1000).rounded()) }
            var w: Int?, h: Int?
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = natural.applying(transform)
                w = Int(abs(r.width).rounded())
                h = Int(abs(r.height).rounded())
            }
            if let limit, let n = (try? FileManager.default.attributesOfItem(atPath: clean.path))?[.size] as? Int, n > limit {
                OutgoingFiles.remove(clean)
                throw ImportError.tooLarge(limit: limit)
            }
            return OutgoingAttachment(kind: .video, fileURL: clean, mime: "video/quicktime", filename: ((name as NSString).deletingPathExtension) + ".mov",
                                      durationMs: duration, pixelWidth: w, pixelHeight: h)
        }
        return OutgoingAttachment(kind: .file, fileURL: file, mime: type.preferredMIMEType ?? "application/octet-stream", filename: name)
    }

    // MARK: Location

    /// The same picture without its GPS block (pixels untouched: the image data is copied,
    /// only the metadata changes). Nil when ImageIO cannot rewrite it.
    static func withoutLocation(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let uti = CGImageSourceGetType(src) else { return nil }
        guard containsLocation(data) else { return data }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else { return nil }
        return out as Data
    }

    /// Whether a picture carries a location anywhere ImageIO can see it: the EXIF GPS block,
    /// IPTC city/region/country/sublocation, or XMP GPS / location fields.
    public static func containsLocation(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        for i in 0..<max(1, CGImageSourceGetCount(src)) {
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] {
                if props[kCGImagePropertyGPSDictionary] != nil { return true }
                if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                    let keys: [CFString] = [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName,
                                            kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCountryPrimaryLocationCode]
                    if keys.contains(where: { iptc[$0] != nil }) { return true }
                }
            }
            if let meta = CGImageSourceCopyMetadataAtIndex(src, i, nil), xmpHasLocation(meta) { return true }
        }
        return false
    }

    static let locationNames: Set<String> = ["city", "state", "country", "countrycode", "location", "sublocation", "locationcreated", "locationshown", "gpscoordinates"]

    private static func xmpHasLocation(_ meta: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
            let name = (CGImageMetadataTagCopyName(tag) as String?)?.lowercased() ?? ""
            if name.hasPrefix("gps") || locationNames.contains(name) { found = true }
            return !found
        }
        return found
    }

    /// The video re-exported without re-encoding, through the sharing metadata filter (drops
    /// location, device and personal metadata). Refused if a location survives.
    static func videoWithoutLocation(_ file: URL) async throws -> URL {
        let asset = AVURLAsset(url: file)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw ImportError.locationNotRemovable }
        export.metadataItemFilter = .forSharing()
        export.metadata = []
        let out = OutgoingFiles.newURL(extension: "mov")
        do {
            try await export.export(to: out, as: .mov)
        } catch {
            OutgoingFiles.remove(out)
            throw ImportError.locationNotRemovable
        }
        if await videoHasLocation(out) {
            OutgoingFiles.remove(out)
            throw ImportError.locationNotRemovable
        }
        return out
    }

    /// Whether a movie carries a location (QuickTime ISO 6709, the common location key, or
    /// any metadata item whose key mentions a location), in the file or any track.
    public static func videoHasLocation(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.metadata)) ?? []
        for track in (try? await asset.load(.tracks)) ?? [] { items += (try? await track.load(.metadata)) ?? [] }
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        return items.contains { item in
            if item.commonKey == .commonKeyLocation { return true }
            if item.identifier == .quickTimeMetadataLocationISO6709 || item.identifier == .quickTimeUserDataLocationISO6709 { return true }
            let key = (item.identifier?.rawValue ?? "").lowercased()
            return key.contains("location") || key.contains("6709") || key.contains("%a9xyz") || key.contains("©xyz")
        }
    }

    // MARK: Helpers

    static func named(_ filename: String?, type: UTType) -> String {
        var name = (filename?.isEmpty == false ? filename! : "Attachment")
        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += ".\(ext)" }
        return name
    }

    /// Width and height after the EXIF orientation.
    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// The decoded pixels written back as PNG with no metadata.
    static func metadataFreePNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// JPEG (quality 0.85, longest side ≤ 4096, orientation applied, NO metadata) with its size.
    static func jpeg(from data: Data, maxPixel: Int = 4096) -> (data: Data, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }
}

/// A picked Photos item as a file (videos are never loaded into memory): the system copies
/// it out; we move it into ``OutgoingFiles``.
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let ext = received.file.pathExtension
            let dest = OutgoingFiles.newURL(extension: ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}
