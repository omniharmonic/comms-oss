import CommsUI
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Minimal snapshot testing: render with `ImageRenderer` at scale 2 on macOS, in light and
/// dark, and compare with PNG references in `__Snapshots__` (≤ 1 % of pixels may differ).
/// `RECORD_SNAPSHOTS=1` (re)writes the references. Fonts are the system's (SF), so the
/// references are machine-specific; see `__Snapshots__/README.md`.
enum Snapshot {
    static let scale: CGFloat = 2
    /// Fraction of pixels allowed to differ.
    static let tolerance = 0.01
    /// A pixel differs when any channel differs by more than this (0–255), so anti-aliasing
    /// noise is not counted.
    static let channelThreshold = 8

    /// Reference comparison runs on macOS only (see `__Snapshots__/README.md`).
    #if os(macOS)
    static let comparesReferences = true
    #else
    static let comparesReferences = false
    #endif
    static var recording: Bool { ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" }

    static func directory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("__Snapshots__")
    }

    /// The canvas every bubble snapshot sits on: a transcript column at Mac sizes.
    @MainActor
    static func canvas<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) -> some View {
        view
            .padding(.horizontal, Tokens.calibration.sideMarginRegular)
            .padding(.vertical, 24)
            .frame(width: width, alignment: .top)
            .environment(\.bubbleMetrics, .mac)
            .environment(\.bubbleMaxWidth, (width - 2 * Tokens.calibration.sideMarginRegular) * BubbleMetrics.mac.maxWidthRatio)
            .environment(\.mediaLoader, .placeholder)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color.black : Color.white)
    }

    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: canvas(view, width: width, scheme: scheme))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.cgImage
    }

    @MainActor
    static func assert<V: View>(_ view: V, named name: String, width: CGFloat = 420, file: StaticString = #filePath, line: UInt = #line) {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let url = directory().appendingPathComponent("\(name)-\(suffix).png")
            guard let image = render(view, width: width, scheme: scheme) else {
                XCTFail("\(name)-\(suffix): ImageRenderer produced no image", file: file, line: line)
                continue
            }
            // References are macOS renders (SF on macOS at Mac sizes): other platforms only
            // check that the view renders, and never record over the macOS references.
            guard comparesReferences else {
                if image.width == 0 || image.height == 0 { XCTFail("\(name)-\(suffix): empty render", file: file, line: line) }
                continue
            }
            if recording {
                do { try writePNG(image, to: url) } catch { XCTFail("\(name)-\(suffix): cannot record: \(error)", file: file, line: line) }
                continue
            }
            guard let reference = readPNG(url) else {
                let failed = failureURL(name, suffix)
                try? writePNG(image, to: failed)
                XCTFail("\(name)-\(suffix): no reference image at \(url.path) (actual written to \(failed.path)); run with RECORD_SNAPSHOTS=1", file: file, line: line)
                continue
            }
            switch compare(image, reference) {
            case .sizeMismatch(let a, let r):
                let failed = failureURL(name, suffix)
                try? writePNG(image, to: failed)
                XCTFail("\(name)-\(suffix): size \(a) ≠ reference \(r) (actual: \(failed.path))", file: file, line: line)
            case .differs(let fraction) where fraction > tolerance:
                let failed = failureURL(name, suffix)
                try? writePNG(image, to: failed)
                XCTFail("\(name)-\(suffix): \(String(format: "%.2f", fraction * 100)) % of pixels differ (> 1 %) (actual: \(failed.path))", file: file, line: line)
            case .differs:
                break
            }
        }
    }

    /// As `assert`, but drawn by a hosting view in an offscreen window (macOS), so AppKit-backed
    /// controls (text fields) and glass render as they do on screen. Elsewhere: `ImageRenderer`.
    @MainActor
    static func assertHosted<V: View>(_ view: V, named name: String, width: CGFloat = 420, file: StaticString = #filePath, line: UInt = #line) {
        #if os(macOS)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let url = directory().appendingPathComponent("\(name)-\(suffix).png")
            guard let image = renderHosted(view, width: width, scheme: scheme) else {
                XCTFail("\(name)-\(suffix): no image", file: file, line: line)
                continue
            }
            if recording {
                do { try writePNG(image, to: url) } catch { XCTFail("\(name)-\(suffix): cannot record: \(error)", file: file, line: line) }
                continue
            }
            guard let reference = readPNG(url) else {
                let failed = failureURL(name, suffix)
                try? writePNG(image, to: failed)
                XCTFail("\(name)-\(suffix): no reference image at \(url.path) (actual written to \(failed.path)); run with RECORD_SNAPSHOTS=1", file: file, line: line)
                continue
            }
            switch compare(image, reference) {
            case .sizeMismatch(let a, let r):
                let failed = failureURL(name, suffix)
                try? writePNG(image, to: failed)
                XCTFail("\(name)-\(suffix): size \(a) ≠ reference \(r) (actual: \(failed.path))", file: file, line: line)
            case .differs(let fraction) where fraction > tolerance:
                let failed = failureURL(name, suffix)
                try? writePNG(image, to: failed)
                XCTFail("\(name)-\(suffix): \(String(format: "%.2f", fraction * 100)) % of pixels differ (> 1 %) (actual: \(failed.path))", file: file, line: line)
            case .differs:
                break
            }
        }
        #else
        assert(view, named: name, width: width, file: file, line: line)
        #endif
    }

    #if os(macOS)
    @MainActor
    static func renderHosted<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) -> CGImage? {
        let content = view
            .frame(width: width)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color.black : Color.white)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
    #endif

    private static func failureURL(_ name: String, _ suffix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CommsUISnapshotFailures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name)-\(suffix).png")
    }

    enum Comparison {
        case sizeMismatch(String, String)
        case differs(Double)
    }

    static func compare(_ a: CGImage, _ b: CGImage) -> Comparison {
        guard a.width == b.width, a.height == b.height else {
            return .sizeMismatch("\(a.width)×\(a.height)", "\(b.width)×\(b.height)")
        }
        let pa = rgba(a), pb = rgba(b)
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<4 where abs(Int(pa[i + c]) - Int(pb[i + c])) > channelThreshold {
                differing += 1
                break
            }
        }
        return .differs(Double(differing) / Double(a.width * a.height))
    }

    /// Redraw into a known sRGB RGBA8 layout so a decoded PNG and a fresh render compare.
    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
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
