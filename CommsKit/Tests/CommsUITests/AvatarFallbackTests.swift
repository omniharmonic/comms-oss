import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import Foundation
import os
import PrismTransport
import SwiftUI
import XCTest

/// The live backend answers 404 for most bridged avatars: the media fetch throws.
private struct NotFoundMediaBackend: ChatBackend {
    let base: FixtureBackend
    let fetches: OSAllocatedUnfairLock<Int>

    func capabilities() async throws -> CommsCapabilities { try await base.capabilities() }
    func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage { try await base.threads(q) }
    func thread(id: String) async throws -> CommsThreadDetail { try await base.thread(id: id) }
    func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage {
        try await base.messages(threadID: threadID, before: before, limit: limit)
    }
    func mediaURL(token: String) -> URL { base.mediaURL(token: token) }
    func media(token: String) async throws -> (Data, String) {
        fetches.withLock { $0 += 1 }
        // What a 404 from the media proxy surfaces as.
        throw PrismError.rejected(ServerFailure(status: 404, code: "not_found", detail: nil, body: Data()))
    }
    func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error> { base.events(lastEventID: lastEventID) }
}

@MainActor
final class AvatarFallbackTests: XCTestCase {
    func testAFailedAvatarIsNotRefetchedUntilTheRetryInterval() async throws {
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let backend = NotFoundMediaBackend(base: try DemoBackend.make(), fetches: fetches)
        let loader = AvatarLoader { token in try await backend.media(token: token).0 }
        let cache = AvatarCache()

        let first = await cache.load("tok_404", with: loader)
        XCTAssertNil(first)
        XCTAssertEqual(fetches.withLock { $0 }, 1)
        XCTAssertTrue(cache.hasRecentFailure("tok_404"))

        // Scrolling the row back in does not fetch again.
        for _ in 0..<5 { _ = await cache.load("tok_404", with: loader) }
        XCTAssertEqual(fetches.withLock { $0 }, 1, "a failed token is cached as failed")

        // After the retry interval it is tried again.
        XCTAssertFalse(cache.hasRecentFailure("tok_404", now: Date().addingTimeInterval(AvatarCache.retryAfter + 1)))
        _ = await cache.load("tok_404", with: loader)
        XCTAssertEqual(fetches.withLock { $0 }, 2)
    }

    func testATransientFailureIsNotRemembered() async {
        let cache = AvatarCache()
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let loader = AvatarLoader { _ in
            fetches.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        _ = await cache.load("tok_offline", with: loader)
        XCTAssertFalse(cache.hasRecentFailure("tok_offline"), "offline is not a missing avatar")
        _ = await cache.load("tok_offline", with: loader)
        XCTAssertEqual(fetches.withLock { $0 }, 2, "tried again next time")
        // A 5xx neither.
        let five = AvatarLoader { _ in throw PrismError.outcomeUnknown(OutcomeUnknown(status: 502, code: nil, reason: "bad gateway")) }
        _ = await cache.load("tok_5xx", with: five)
        XCTAssertFalse(cache.hasRecentFailure("tok_5xx"))
    }

    func testForgettingFailuresAllowsARefetch() async throws {
        let cache = AvatarCache()
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let backend = NotFoundMediaBackend(base: try DemoBackend.make(), fetches: fetches)
        let loader = AvatarLoader { token in try await backend.media(token: token).0 }
        _ = await cache.load("tok_404b", with: loader)
        XCTAssertTrue(cache.hasRecentFailure("tok_404b"))
        cache.forgetFailures() // foreground reconnect / successful Retry
        _ = await cache.load("tok_404b", with: loader)
        XCTAssertEqual(fetches.withLock { $0 }, 2)
    }

    func testMediaLoaderRemembers410AndSharesOneFetch() async throws {
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let gone = MediaLoader(fetch: { _ in
            fetches.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            throw CommsError.mediaExpired
        })
        async let a: MediaImage? = try? gone.load("tok_410")
        async let b: MediaImage? = try? gone.load("tok_410")
        _ = await (a, b)
        XCTAssertEqual(fetches.withLock { $0 }, 1, "two bubbles, one fetch")
        _ = try? await gone.load("tok_410")
        XCTAssertEqual(fetches.withLock { $0 }, 1, "a 410 is remembered")
        gone.forgetFailures()
        _ = try? await gone.load("tok_410")
        XCTAssertEqual(fetches.withLock { $0 }, 2)

        let offline = MediaLoader(fetch: { _ in
            fetches.withLock { $0 += 1 }
            throw URLError(.timedOut)
        })
        _ = try? await offline.load("tok_t")
        _ = try? await offline.load("tok_t")
        XCTAssertEqual(fetches.withLock { $0 }, 4, "timeouts are retried")
    }

    func testNonImageBytesCountAsAFailure() async {
        let cache = AvatarCache()
        let loader = AvatarLoader { _ in Data("<html>not found</html>".utf8) }
        let image = await cache.load("tok_html", with: loader)
        XCTAssertNil(image)
        XCTAssertTrue(cache.hasRecentFailure("tok_html"))
    }

    func testAnUnavailablePhotoRendersTheMonogramNotAnEmptyCircle() throws {
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let backend = NotFoundMediaBackend(base: try DemoBackend.make(), fetches: fetches)
        let loader = AvatarLoader { token in try await backend.media(token: token).0 }
        let avatar = AvatarView(.token("tok_unavailable_\(UUID().uuidString)"), kind: .dm, size: 60, name: "Alice Example")
            .environment(\.avatarLoader, loader)
        let monogram = AvatarFallback(kind: .dm, size: 60, name: "Alice Example").frame(width: 60, height: 60).clipShape(Circle())
        let a = try XCTUnwrap(render(avatar))
        let b = try XCTUnwrap(render(monogram))
        XCTAssertEqual(a, b, "the photo slot shows the monogram")
        let silhouette = try XCTUnwrap(render(AvatarFallback(kind: .dm, size: 60, name: nil).frame(width: 60, height: 60)))
        XCTAssertNotEqual(a, silhouette, "not the empty silhouette")
    }

    func testInitials() {
        XCTAssertEqual(AvatarFallback.initials("Alice Example"), "AE")
        XCTAssertEqual(AvatarFallback.initials("bob"), "B")
        XCTAssertEqual(AvatarFallback.initials("Mary Jane Watson"), "MW")
        XCTAssertNil(AvatarFallback.initials("+1 (555) 010-2000"))
        XCTAssertNil(AvatarFallback.initials(nil))
    }

    private func render(_ view: some View) -> Data? {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
        r.scale = 2
        guard let cg = r.cgImage, let data = cg.dataProvider?.data else { return nil }
        return data as Data
    }
}
