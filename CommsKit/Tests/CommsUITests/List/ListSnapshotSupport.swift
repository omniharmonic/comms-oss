import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Snapshot helper for the list views (same conventions as the bubble snapshots: `ImageRenderer`
/// at scale 2 on macOS, light + dark, ≤ 1 % differing pixels, `RECORD_SNAPSHOTS=1` records).
/// References live in `__Snapshots__/List/` (excluded from the target, read by path).
enum ListSnapshot {
    static let scale: CGFloat = 2
    static let tolerance = 0.01
    /// A pixel differs when any channel differs by more than this (anti-aliasing noise is ignored).
    static let channelThreshold = 8
    /// Reference comparison runs on macOS only (see `__Snapshots__/README.md`).
    #if os(macOS)
    static let comparesReferences = true
    #else
    static let comparesReferences = false
    #endif
    static var recording: Bool { ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" }

    static func directory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/List")
    }

    /// Approximations of the opaque sidebar (the system glass cannot be rendered off-screen).
    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.965, green: 0.965, blue: 0.965)
    }

    /// Fixed locale, calendar and time zone so timestamps render the same everywhere.
    @MainActor
    static func canvas<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return view
            .padding(10)
            .frame(width: width, alignment: .topLeading)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, calendar.timeZone)
            .environment(\.calendar, calendar)
            .background(sidebarBackground(scheme))
    }

    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme, scale: CGFloat = scale) -> CGImage? {
        let renderer = ImageRenderer(content: canvas(view, width: width, scheme: scheme))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.cgImage
    }

    @MainActor
    static func assert<V: View>(_ view: V, named name: String, width: CGFloat = 300, scale: CGFloat = scale, file: StaticString = #filePath, line: UInt = #line) {
        for scheme in [ColorScheme.light, .dark] {
            let id = "\(name)-\(scheme == .dark ? "dark" : "light")"
            let url = directory().appendingPathComponent("\(id).png")
            guard let image = render(view, width: width, scheme: scheme, scale: scale) else {
                XCTFail("\(id): ImageRenderer produced no image", file: file, line: line)
                continue
            }
            // References are macOS renders (SF on macOS at Mac sizes): other platforms only
            // check that the view renders, and never record over the macOS references.
            guard comparesReferences else {
                if image.width == 0 || image.height == 0 { XCTFail("\(id): empty render", file: file, line: line) }
                continue
            }
            if recording {
                do { try writePNG(image, to: url) } catch { XCTFail("\(id): cannot record: \(error)", file: file, line: line) }
                continue
            }
            guard let reference = readPNG(url) else {
                let failed = failureURL(id)
                try? writePNG(image, to: failed)
                XCTFail("\(id): no reference at \(url.path) (actual: \(failed.path)); run with RECORD_SNAPSHOTS=1", file: file, line: line)
                continue
            }
            guard image.width == reference.width, image.height == reference.height else {
                let failed = failureURL(id)
                try? writePNG(image, to: failed)
                XCTFail("\(id): size \(image.width)×\(image.height) ≠ reference \(reference.width)×\(reference.height) (actual: \(failed.path))", file: file, line: line)
                continue
            }
            let fraction = differingFraction(image, reference)
            if fraction > tolerance {
                let failed = failureURL(id)
                try? writePNG(image, to: failed)
                XCTFail("\(id): \(String(format: "%.2f", fraction * 100)) % of pixels differ (> 1 %) (actual: \(failed.path))", file: file, line: line)
            }
        }
    }

    static func differingFraction(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = rgba(a), pb = rgba(b)
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<4 where abs(Int(pa[i + c]) - Int(pb[i + c])) > channelThreshold {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(a.width * a.height)
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func failureURL(_ id: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CommsUISnapshotFailures/List")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).png")
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func readPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
