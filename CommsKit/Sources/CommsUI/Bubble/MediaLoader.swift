import CommsCore
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A decoded image (CGImage wrapped so it can cross concurrency domains; it is immutable).
public final class MediaImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }

    /// Decoded bytes this image holds (the cache's cost).
    public var cost: Int { cgImage.bytesPerRow * cgImage.height }

    /// The longest side, in pixels, bubbles decode to: 2× the Mac media box's long side
    /// (≈ 483 pt) rounded up. Quick Look fetches the original separately, so bubbles never
    /// need full resolution (a 12 MP photo would be ≈ 48 MB decoded).
    public static let defaultMaxPixelSize = 1024

    /// Decodes `data` downsampled so its longest side is at most `maxPixelSize`, decoded now
    /// (not lazily at first draw on the main thread). Call it off the main thread.
    public convenience init?(data: Data, maxPixelSize: Int = MediaImage.defaultMaxPixelSize) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary) else { return nil }
        self.init(image)
    }
}

/// How bubbles get media bytes. Media tokens are fetched only through the authenticated
/// backend (`CommsClient.media(token:)`), never with a plain URL load: build the loader with
/// `MediaLoader(fetch:)` over that call. `cached` answers synchronously so views (and
/// snapshot renders) can draw an image they already have without a loading flash.
public struct MediaLoader: Sendable {
    public var cached: @Sendable (String) -> MediaImage?
    public var load: @Sendable (String) async throws -> MediaImage

    public init(cached: @escaping @Sendable (String) -> MediaImage?, load: @escaping @Sendable (String) async throws -> MediaImage) {
        self.cached = cached
        self.load = load
    }

    public enum LoadError: Error { case undecodable, unavailable }

    /// The window's media budget: decoded bytes kept before the least recently used go.
    public static let defaultCostLimit = 64 * 1024 * 1024

    /// Fetch bytes with `fetch` (e.g. `{ try await client.media(token: $0).0 }`), decode them
    /// downsampled on a background thread (`decode`, default `MediaImage(data:)`), and keep
    /// them in a cache bounded by `costLimit` decoded bytes.
    public init(
        fetch: @escaping @Sendable (String) async throws -> Data,
        costLimit: Int = MediaLoader.defaultCostLimit,
        decode: @escaping @Sendable (Data) -> MediaImage? = { MediaImage(data: $0) }
    ) {
        let cache = MediaCache(costLimit: costLimit)
        self.init(fetch: fetch, cache: cache, decode: decode)
        forgetFailures = { cache.forgetFailures() }
    }

    init(fetch remote: @escaping @Sendable (String) async throws -> Data, cache: MediaCache, decode: @escaping @Sendable (Data) -> MediaImage?) {
        // Pending attachments (`local-…` tokens) are answered from this device, never fetched.
        let fetch: @Sendable (String) async throws -> Data = { token in
            guard LocalMedia.isLocal(token) else { return try await remote(token) }
            guard let data = LocalMedia.data(for: token) else { throw LoadError.unavailable }
            return data
        }
        self.init(cached: { cache[$0] }, load: { token in
            if let hit = cache[token] { return hit }
            if cache.hasRecentFailure(token) { throw LoadError.unavailable }
            // One fetch per token at a time: bubbles showing the same picture share it.
            let task = cache.inflightTask(for: token) {
                Task<MediaImage, any Error> {
                    let data: Data
                    do { data = try await fetch(token) } catch {
                        if MediaFailure.isPermanent(error) { cache.recordFailure(token) }
                        throw error
                    }
                    // Decoding is CPU work: never on the main thread (the caller is a view's task).
                    let image = await Task.detached(priority: .userInitiated) { decode(data) }.value
                    guard let image else {
                        cache.recordFailure(token)
                        throw LoadError.undecodable
                    }
                    cache[token] = image
                    return image
                }
            }
            defer { cache.finished(token) }
            return try await task.value
        })
    }

    /// Forget remembered failures (foreground reconnect, a successful Retry).
    public var forgetFailures: @Sendable () -> Void = {}

    /// Never loads: bubbles show their placeholder fill.
    public static let none = MediaLoader(cached: { _ in nil }, load: { _ in throw LoadError.unavailable })

    /// Synthetic placeholder pictures for previews and snapshots (no network, no real media).
    public static let placeholder: MediaLoader = {
        let cache = MediaCache(costLimit: 16 * 1024 * 1024)
        let make: @Sendable (String) -> MediaImage? = { token in
            if let hit = cache[token] { return hit }
            guard let image = PlaceholderArt.image(seed: token) else { return nil }
            cache[token] = image
            return image
        }
        return MediaLoader(cached: make, load: { token in
            guard let image = make(token) else { throw LoadError.undecodable }
            return image
        })
    }()
}

/// Decoded images by token, bounded by total decoded bytes (`costLimit`): inserting past
/// the limit evicts the least recently used first. (NSCache with no cost limit evicts only
/// under system memory pressure; this bound is deterministic.)
final class MediaCache: @unchecked Sendable {
    let costLimit: Int
    private let lock = NSLock()
    private var images: [String: MediaImage] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var cost = 0

    /// Tokens that failed permanently (404 / 410 / not an image) and when; see `AvatarCache`.
    private var failures: [String: Date] = [:]
    private var inflight: [String: Task<MediaImage, any Error>] = [:]
    static let retryAfter: TimeInterval = 10 * 60

    init(costLimit: Int) { self.costLimit = costLimit }

    func hasRecentFailure(_ token: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let at = failures[token] else { return false }
            if now.timeIntervalSince(at) < Self.retryAfter { return true }
            failures[token] = nil
            return false
        }
    }

    func recordFailure(_ token: String) { lock.withLock { failures[token] = Date() } }
    func forgetFailures() { lock.withLock { failures.removeAll() } }

    /// The running fetch for `token`, or a new one from `make`.
    func inflightTask(for token: String, make: () -> Task<MediaImage, any Error>) -> Task<MediaImage, any Error> {
        lock.withLock {
            if let t = inflight[token] { return t }
            let t = make()
            inflight[token] = t
            return t
        }
    }

    func finished(_ token: String) { _ = lock.withLock { inflight.removeValue(forKey: token) } }

    var count: Int { lock.withLock { images.count } }
    var totalCost: Int { lock.withLock { cost } }

    subscript(token: String) -> MediaImage? {
        get {
            lock.withLock {
                guard let hit = images[token] else { return nil }
                touch(token)
                return hit
            }
        }
        set {
            guard let newValue else { return }
            lock.withLock {
                if let old = images.removeValue(forKey: token) { cost -= old.cost; order.removeAll { $0 == token } }
                // An image bigger than the whole budget is not kept (it is still shown).
                guard newValue.cost <= costLimit else { return }
                images[token] = newValue
                order.append(token)
                cost += newValue.cost
                while cost > costLimit, let oldest = order.first {
                    order.removeFirst()
                    if let gone = images.removeValue(forKey: oldest) { cost -= gone.cost }
                }
            }
        }
    }

    private func touch(_ token: String) {
        guard let i = order.firstIndex(of: token), i != order.count - 1 else { return }
        order.remove(at: i)
        order.append(token)
    }
}

/// A deterministic "landscape" (sky, sun, hills) so placeholder media looks like a photo.
enum PlaceholderArt {
    static func image(seed: String, size: Int = 480) -> MediaImage? {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        func unit(_ shift: UInt64) -> CGFloat { CGFloat((h >> shift) & 0xFF) / 255 }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.98, green: 0.80 + 0.1 * unit(0), blue: 0.62, alpha: 1),
            CGColor(srgbRed: 0.42 + 0.1 * unit(8), green: 0.66, blue: 0.92, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.70, alpha: 1))
        let sunX = s * (0.25 + 0.5 * unit(16))
        ctx.fillEllipse(in: CGRect(x: sunX, y: s * 0.62, width: s * 0.16, height: s * 0.16))
        for (i, shade) in [(0, 0.46), (1, 0.34)].map({ ($0.0, CGFloat($0.1)) }) {
            // Sand / terracotta hills (no green anywhere, even in placeholders).
            ctx.setFillColor(CGColor(srgbRed: shade + 0.4, green: shade + 0.22, blue: shade + 0.08, alpha: 1))
            let base = s * (0.42 - 0.14 * CGFloat(i))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: 0, y: base))
            ctx.addCurve(to: CGPoint(x: s, y: base * (0.8 + 0.4 * unit(24 + UInt64(i) * 8))),
                         control1: CGPoint(x: s * 0.3, y: base + s * 0.18), control2: CGPoint(x: s * 0.6, y: base - s * 0.1))
            ctx.addLine(to: CGPoint(x: s, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage().map(MediaImage.init)
    }
}

/// An image for a media token: cached synchronously when possible, else loaded, with a flat
/// placeholder fill until then. A new token clears the previous image; a failed load shows a
/// retry button.
struct MediaImageView: View {
    let token: String?
    var placeholder: Color
    /// Small images (avatars) just keep their placeholder on failure.
    var retryable = true

    @Environment(\.mediaLoader) private var loader
    @State private var loaded: (token: String, image: MediaImage)?
    @State private var failed = false
    @State private var attempt = 0

    private struct LoadKey: Equatable {
        let token: String?
        let attempt: Int
    }

    var body: some View {
        let image = loaded.flatMap { $0.token == token ? $0.image : nil } ?? token.flatMap { loader.cached($0) }
        ZStack {
            placeholder
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if failed, retryable {
                Button {
                    attempt += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry loading media")
            }
        }
        .task(id: LoadKey(token: token, attempt: attempt)) {
            if loaded?.token != token { loaded = nil }
            failed = false
            guard let token, loader.cached(token) == nil else { return }
            do {
                let image = try await loader.load(token)
                loaded = (token, image)
            } catch is CancellationError {
            } catch MediaLoader.LoadError.unavailable {
                // No loader (previews): keep the placeholder, nothing to retry.
            } catch {
                failed = true
            }
        }
    }
}
