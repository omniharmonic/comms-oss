import CommsClient
import CommsCore
import CommsTestSupport
import Foundation
import PrismAuth
import PrismTransport
import XCTest

private final class FakeSigner: DeviceSigner {
    let store: InMemoryTokenStore
    let origin: ServerOrigin
    let counts = NSLock()
    nonisolated(unsafe) private(set) var signInCalls = 0
    nonisolated(unsafe) private(set) var signOutCalls = 0

    init(store: InMemoryTokenStore, origin: ServerOrigin) { self.store = store; self.origin = origin }

    func signIn(label: String) async throws {
        counts.withLock { signInCalls += 1 }
        try store.setToken("pd_fake", for: origin)
    }
    func signOut() async {
        counts.withLock { signOutCalls += 1 }
        try? store.removeToken(for: origin)
    }
}

private struct NoSigner: DeviceSigner {
    func signIn(label: String) async throws {}
    func signOut() async {}
}

@MainActor
final class SessionTests: XCTestCase {
    let origin = try! ServerOrigin("https://prism.example.com")

    private func makeSession(_ backend: FixtureBackend, store: InMemoryTokenStore) -> (Session, FakeSigner) {
        let signer = FakeSigner(store: store, origin: origin)
        let session = Session(origin: origin, store: store, backendFactory: { _ in backend }, signer: signer)
        return (session, signer)
    }

    func testRestoreWithValidCapabilitiesBecomesReady() async throws {
        let store = InMemoryTokenStore()
        try store.setToken("pd_saved", for: origin)
        let backend = try FixtureBackend()
        let (session, _) = makeSession(backend, store: store)
        await session.restore()
        XCTAssertEqual(session.state, .ready)
        XCTAssertNotNil(session.backend)
        XCTAssertEqual(backend.capabilityCalls, 1)
    }

    func testCapabilityMismatchRevokesAndFails() async throws {
        let store = InMemoryTokenStore()
        let backend = try FixtureBackend(capabilities: .failure(CommsError.unsupportedServer("grant is not restricted")))
        let (session, signer) = makeSession(backend, store: store)
        await session.signIn()
        guard case .failed = session.state else { return XCTFail("expected failed, got \(session.state)") }
        XCTAssertNil(session.backend)
        XCTAssertEqual(signer.signInCalls, 1)
        XCTAssertEqual(signer.signOutCalls, 1, "the fresh token must be revoked")
        XCTAssertNil(try store.token(for: origin))
    }

    func testRestoreWithoutTokenIsSignedOut() async throws {
        let backend = try FixtureBackend()
        let (session, _) = makeSession(backend, store: InMemoryTokenStore())
        await session.restore()
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertEqual(backend.capabilityCalls, 0, "no token, no server call")
    }

    func testRestoreWithCapabilityMismatchRevokesAndSignsOut() async throws {
        let store = InMemoryTokenStore()
        try store.setToken("pd_saved", for: origin)
        let backend = try FixtureBackend(capabilities: .failure(CommsError.unsupportedServer("not a comms server")))
        let (session, signer) = makeSession(backend, store: store)
        await session.restore()
        guard case .failed = session.state else { return XCTFail("expected failed, got \(session.state)") }
        XCTAssertEqual(signer.signOutCalls, 1)
        XCTAssertNil(try store.token(for: origin))
        XCTAssertNil(session.backend)
    }

    func testDeadTokenIsForgottenOnRestore() async throws {
        for error in [PrismError.signedOut, .unauthorized, .notSignedIn] {
            let store = InMemoryTokenStore()
            try store.setToken("pd_dead", for: origin)
            let (session, _) = makeSession(try FixtureBackend(capabilities: .failure(error)), store: store)
            await session.restore()
            XCTAssertEqual(session.state, .signedOut, "\(error)")
            XCTAssertNil(try store.token(for: origin), "\(error)")
            await session.restore()
            XCTAssertEqual(session.state, .signedOut)
        }
    }

    func testSignOutWithoutSignerRemovesToken() async throws {
        let store = InMemoryTokenStore()
        try store.setToken("pd_saved", for: origin)
        let session = Session(origin: origin, store: store, backendFactory: { _ in try! FixtureBackend() }, signer: NoSigner())
        await session.signOut()
        XCTAssertNil(try store.token(for: origin))
        XCTAssertEqual(session.state, .signedOut)
    }

    func testSignInWithValidCapabilitiesBecomesReady() async throws {
        let store = InMemoryTokenStore()
        let (session, signer) = makeSession(try FixtureBackend(), store: store)
        await session.signIn()
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(signer.signOutCalls, 0)
    }

    /// I6: an offline launch keeps the token and goes `.offline` (Retry), not to sign-in.
    func testOfflineRestoreKeepsTokenAndRetryRecovers() async throws {
        let store = InMemoryTokenStore()
        try store.setToken("pd_saved", for: origin)
        let backend = try FixtureBackend(capabilities: .failure(PrismError.unreachable("offline")))
        let (session, signer) = makeSession(backend, store: store)
        await session.restore()
        XCTAssertEqual(session.state, .offline("Can't reach the server."))
        XCTAssertTrue(session.isOffline)
        XCTAssertNil(session.backend)
        XCTAssertEqual(signer.signOutCalls, 0)
        XCTAssertEqual(signer.signInCalls, 0, "never a fresh browser sign-in")
        XCTAssertEqual(try store.token(for: origin), "pd_saved")

        // Still offline: Retry keeps the state (no flash back to sign-in) and the token.
        await session.retry()
        XCTAssertTrue(session.isOffline)
        XCTAssertEqual(backend.capabilityCalls, 2)

        // Network back: Retry verifies the same token.
        backend.setCapabilities(.success(FixtureBackend.validCapabilities))
        await session.retry()
        XCTAssertEqual(session.state, .ready)
        XCTAssertNotNil(session.backend)
        XCTAssertEqual(signer.signInCalls, 0)
    }

    func testURLErrorAndBridgeOutageAreOfflineToo() async throws {
        for error in [URLError(.notConnectedToInternet), URLError(.timedOut)] as [any Error] + [CommsError.sourceUnavailable(network: .matrix)] {
            let store = InMemoryTokenStore()
            try store.setToken("pd_saved", for: origin)
            let (session, _) = makeSession(try FixtureBackend(capabilities: .failure(error)), store: store)
            await session.restore()
            XCTAssertTrue(session.isOffline, "\(error)")
            XCTAssertNotNil(try store.token(for: origin))
        }
    }

    func testOnlyARealRejectionLeavesOfflineForSignIn() async throws {
        let store = InMemoryTokenStore()
        try store.setToken("pd_saved", for: origin)
        let backend = try FixtureBackend(capabilities: .failure(PrismError.unreachable("offline")))
        let (session, _) = makeSession(backend, store: store)
        await session.restore()
        XCTAssertTrue(session.isOffline)
        backend.setCapabilities(.failure(PrismError.unauthorized))
        await session.retry()
        XCTAssertEqual(session.state, .signedOut, "a 401 forgets the token and asks to sign in")
        XCTAssertNil(try store.token(for: origin))
    }

    func testFixtureBackendProgrammableStream() async throws {
        let backend = try FixtureBackend()
        let stream = backend.events(lastEventID: "e1")
        backend.push(CommsEvent(id: "e2", kind: .reset, payload: .null))
        backend.finishStreams()
        var seen: [String?] = []
        for try await e in stream { seen.append(e.id) }
        XCTAssertEqual(seen, ["e2"])
        XCTAssertEqual(backend.requestedEventIDs, ["e1"])
        let page = try await backend.threads(CommsThreadQuery())
        XCTAssertGreaterThanOrEqual(page.threads.count, 5)
    }

    func testASignInThatEndsOfflineStillRemembersTheOrigin() async throws {
        let store = InMemoryTokenStore()
        // The token is minted, then the capability check cannot reach the server.
        let backend = try FixtureBackend(capabilities: .failure(URLError(.notConnectedToInternet)))
        let (session, _) = makeSession(backend, store: store)
        await session.signIn()
        XCTAssertTrue(session.isOffline)
        XCTAssertTrue(session.hasStoredToken)
        XCTAssertTrue(session.shouldRememberOrigin, "else the next launch signs in again and mints a second device")
    }

    func testAFailedSignInDoesNotRememberTheOrigin() async throws {
        let store = InMemoryTokenStore()
        let backend = try FixtureBackend(capabilities: .failure(CommsError.unsupportedServer("no")))
        let (session, _) = makeSession(backend, store: store)
        await session.signIn()
        XCTAssertFalse(session.hasStoredToken)
        XCTAssertFalse(session.shouldRememberOrigin)
    }
}
