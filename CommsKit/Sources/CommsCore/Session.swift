import CommsClient
import Foundation
import Observation
import PrismAuth
import PrismTransport

/// The sign-in step the session drives. The live one wraps PrismKit's `DeviceSignIn`;
/// tests substitute a fake so nothing touches a server.
public protocol DeviceSigner: Sendable {
    func signIn(label: String) async throws
    /// Revoke the token on the server and forget it locally.
    func signOut() async
}

/// `DeviceSignIn` with the `comms-native` client plus a browser leg (`RedirectFlow`).
public struct DeviceSignInSigner: DeviceSigner {
    private let signer: DeviceSignIn
    private let flow: any RedirectFlow

    public init(origin: ServerOrigin, store: any TokenStore, flow: any RedirectFlow) {
        self.signer = DeviceSignIn(origin: origin, configuration: .commsNative, tokenStore: store)
        self.flow = flow
    }

    public func signIn(label: String) async throws { try await signer.signIn(using: flow, label: label) }
    public func signOut() async { await signer.signOut() }
}

/// Sign-in plus capability verification for one server origin.
///
/// Fails closed: the session is `.ready` only after the server's capabilities pass
/// `CommsClient.capabilities()` (Comms integration, restricted grant, schema 1, read ops).
@MainActor @Observable
public final class Session {
    /// `.offline`: a saved token exists but the server could not be reached (or its bridge is
    /// down). The token is kept; `retry()` verifies again. Only a dead token (401) or an
    /// unsupported server returns to `.signedOut` / `.failed`.
    public enum State: Equatable { case signedOut, signingIn, verifying, ready, offline(String), failed(String) }

    public let origin: ServerOrigin
    public private(set) var state: State = .signedOut
    public private(set) var backend: (any ChatBackend)?
    /// A `retry()` from `.offline` is in flight (the state stays `.offline` meanwhile).
    public private(set) var isRetrying = false
    public var isOffline: Bool { if case .offline = state { true } else { false } }
    /// A device token is stored for this origin (minted by a sign-in, kept while offline).
    public var hasStoredToken: Bool { ((try? store.token(for: origin)) ?? nil) != nil }
    /// The app should remember this origin for the next launch: whenever a token is stored
    /// (ready, or offline right after minting one). Remembering it only when `.ready` made a
    /// sign-in followed by a failed check mint a second device token on the next launch.
    public var shouldRememberOrigin: Bool { state == .ready || hasStoredToken }

    @ObservationIgnored private let store: any TokenStore
    @ObservationIgnored private let backendFactory: (PrismClient) -> any ChatBackend
    @ObservationIgnored private let signer: (any DeviceSigner)?
    @ObservationIgnored private let deviceLabel: String
    @ObservationIgnored private var clientGeneration = 0

    /// - Parameter signer: the sign-in step. When nil, a macOS system-browser loopback flow is
    ///   used; on iOS (no flow yet) `signIn()` reports a failure.
    public init(
        origin: ServerOrigin,
        store: any TokenStore,
        backendFactory: @escaping (PrismClient) -> any ChatBackend,
        signer: (any DeviceSigner)? = nil,
        deviceLabel: String = "Comms"
    ) {
        self.origin = origin
        self.store = store
        self.backendFactory = backendFactory
        self.deviceLabel = deviceLabel
        #if os(macOS)
        self.signer = signer ?? DeviceSignInSigner(origin: origin, store: store, flow: LoopbackRedirectFlow.systemBrowser())
        #else
        self.signer = signer
        #endif
    }

    /// Browser sign-in, then verify capabilities. A server that is not a supported Comms
    /// server has the fresh token revoked and leaves the session `.failed`.
    public func signIn() async {
        guard state != .signingIn, state != .verifying else { return }
        guard let signer else { return fail("Sign-in is not available on this platform yet.") }
        state = .signingIn
        do {
            try await signer.signIn(label: deviceLabel)
        } catch let error as DeviceAuthError {
            if error == .cancelled { state = .signedOut } else { fail(Self.describe(error)) }
            return
        } catch {
            // Name the cause (e.g. a keychain status code) so a failure can be diagnosed.
            return fail("Sign-in failed (\(String(describing: error))).")
        }
        await verify()
    }

    /// Use a saved token, if any: verify capabilities, then `.ready`. With no network the
    /// session goes `.offline` and keeps the token (never back to the sign-in screen).
    public func restore() async {
        guard state != .signingIn, state != .verifying, !isRetrying else { return }
        let token: String?
        do { token = try store.token(for: origin) } catch { return fail("Could not read the saved sign-in.") }
        guard token != nil else { state = .signedOut; return }
        await verify()
    }

    /// From `.offline`: verify the saved token again (the Retry button, and the automatic
    /// retries while offline). The state stays `.offline` until the answer is known.
    public func retry() async {
        guard isOffline, !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        let token = try? store.token(for: origin)
        guard token != nil else { state = .signedOut; return }
        await verify(quietly: true)
    }

    /// Revoke the device token and return to the sign-in screen.
    public func signOut() async {
        // Best effort first (review M4): drop this device's push registration, bounded so an
        // offline sign-out is not held up. Revoking the device removes it server-side as well; if
        // both fail (offline), the row lives until the credential expires.
        if let backend {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await backend.unregisterPush() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
        }
        await revokeAndForget()
        clientGeneration += 1
        backend = nil
        state = .signedOut
    }

    /// `quietly`: keep the current (offline) state while checking instead of `.verifying`.
    private func verify(quietly: Bool = false) async {
        if !quietly { state = .verifying }
        clientGeneration += 1
        let generation = clientGeneration
        let client = PrismClient(origin: origin, tokenStore: store, userAgent: "Comms/1", onSignedOut: { [weak self] in
            await self?.tokenRejected(generation: generation)
        })
        let candidate = backendFactory(client)
        do {
            _ = try await candidate.capabilities()
            backend = candidate
            state = .ready
        } catch let error as CommsError {
            if case .sourceUnavailable = error {
                // The server answered but its bridge is down: keep the token, retry later.
                backend = nil
                state = .offline(Self.describe(error))
                return
            }
            guard case .unsupportedServer = error else { return fail(Self.describe(error)) }
            // Wrong server or an over-broad grant: never keep a token that would be used against it.
            await revokeAndForget()
            fail("This server is not a supported Comms server.")
        } catch PrismError.signedOut, PrismError.unauthorized, PrismError.notSignedIn {
            // The token is dead: forget it so a relaunch does not retry it forever.
            try? store.removeToken(for: origin)
            backend = nil
            state = .signedOut
        } catch {
            // Network trouble: keep the token and offer Retry, never a fresh sign-in.
            backend = nil
            state = .offline("Can't reach the server.")
        }
    }

    /// Revoke on the server (when a signer exists) and always drop the local token.
    private func revokeAndForget() async {
        await signer?.signOut()
        try? store.removeToken(for: origin)
    }

    /// A stale client's late signed-out callback must not undo a newer session.
    private func tokenRejected(generation: Int) {
        guard generation == clientGeneration else { return }
        backend = nil
        state = .signedOut
    }

    private func fail(_ message: String) {
        backend = nil
        state = .failed(message)
    }

    private static func describe(_ error: CommsError) -> String {
        switch error {
        case .sourceUnavailable: return "The server's chat bridge is unavailable right now."
        case .clientScope: return "This sign-in is not allowed to use Comms."
        default: return "The server refused the request."
        }
    }

    private static func describe(_ error: DeviceAuthError) -> String {
        switch error {
        case .denied: return "Sign-in was denied."
        case .timedOut: return "Sign-in timed out."
        case .unreachable: return "Could not reach the server."
        default: return "Sign-in failed."
        }
    }
}
