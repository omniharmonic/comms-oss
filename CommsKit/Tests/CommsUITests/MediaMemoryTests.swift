import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CommsUI

/// I4: bubble media is decoded downsampled, off the main thread, into a cache bounded by
/// decoded bytes.
@MainActor
final class MediaMemoryTests: XCTestCase {
    private static func png(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private static func image(_ side: Int) -> MediaImage {
        MediaImage(data: png(width: side, height: side), maxPixelSize: side)!
    }

    func testLargePhotoIsDecodedDownsampled() throws {
        let image = try XCTUnwrap(MediaImage(data: Self.png(width: 3000, height: 2000)))
        XCTAssertEqual(max(image.cgImage.width, image.cgImage.height), MediaImage.defaultMaxPixelSize)
        XCTAssertEqual(image.cgImage.width, 1024)
        XCTAssertEqual(image.cgImage.height, 683, "aspect ratio kept")
        XCTAssertLessThanOrEqual(image.cost, 1024 * 683 * 4 + 1024 * 64, "≈ 2.8 MB, not the 24 MB full decode")
        // Small images are not upscaled.
        let small = try XCTUnwrap(MediaImage(data: Self.png(width: 64, height: 48)))
        XCTAssertEqual(small.cgImage.width, 64)
    }

    func testCacheStaysWithinItsCostLimitEvictingLeastRecentlyUsed() {
        let one = Self.image(100)
        let cache = MediaCache(costLimit: 3 * one.cost)
        cache["a"] = Self.image(100)
        cache["b"] = Self.image(100)
        cache["c"] = Self.image(100)
        XCTAssertNotNil(cache["a"], "touching a makes b the least recently used")
        cache["d"] = Self.image(100)
        XCTAssertEqual(cache.count, 3)
        XCTAssertLessThanOrEqual(cache.totalCost, cache.costLimit)
        XCTAssertNil(cache["b"])
        XCTAssertNotNil(cache["a"])
        XCTAssertNotNil(cache["d"])
        // Replacing a key does not double-count it.
        cache["d"] = Self.image(100)
        XCTAssertEqual(cache.totalCost, 3 * one.cost)
        // An image bigger than the whole budget is not kept.
        cache["huge"] = Self.image(400)
        XCTAssertNil(cache["huge"])
        XCTAssertEqual(cache.count, 3)
    }

    func testDefaultWindowBudgetIs64MB() {
        XCTAssertEqual(MediaLoader.defaultCostLimit, 64 * 1024 * 1024)
    }

    func testLoaderDecodesOffTheMainThreadAndCaches() async throws {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var decodedOnMain: [Bool] = []
            var fetches = 0
        }
        let probe = Probe()
        let data = Self.png(width: 2000, height: 1500)
        let loader = MediaLoader(
            fetch: { _ in probe.lock.withLock { probe.fetches += 1 }; return data },
            decode: { bytes in
                probe.lock.withLock { probe.decodedOnMain.append(Thread.isMainThread) }
                return MediaImage(data: bytes)
            })
        XCTAssertTrue(Thread.isMainThread, "the caller (a view's task) is on the main thread")
        let image = try await loader.load("tok")
        XCTAssertEqual(image.cgImage.width, 1024)
        XCTAssertEqual(probe.decodedOnMain, [false], "decode ran off the main thread")
        XCTAssertNotNil(loader.cached("tok"))
        _ = try await loader.load("tok")
        XCTAssertEqual(probe.fetches, 1, "the second load is a cache hit")
    }
}
