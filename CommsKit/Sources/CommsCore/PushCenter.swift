import CommsClient
import Foundation
import Observation
#if os(macOS)
import Security
#endif

/// Remote notifications glue (Sprint Task 1), shared by the app delegate and the signed-in
/// window:
/// - the APNs device token (from the delegate) is registered with the server once a signed-in
///   backend is known (whichever arrives second triggers it), with this build's APNs
///   environment;
/// - a tapped notification names a thread: `pendingThreadID` until the window opens it;
/// - the app badge follows the list's "Needs attention" unread count.
///
/// Nothing here reads or logs notification content.
@MainActor @Observable
public final class CommsPushCenter {
    public static let shared = CommsPushCenter()

    /// The thread a tapped notification asked for (the window clears it once opened).
    public var pendingThreadID: String?
    /// Whether the server will push to this device (after a registration).
    public private(set) var serverPushEnabled: Bool?
    /// The system permission (nil = not asked yet).
    public var permissionGranted: Bool?
    /// Bumped whenever the signed-in backend changes (the Mac Settings window follows it).
    public private(set) var backendGeneration = 0
    /// The signed-in backend, if any.
    public var currentBackend: (any ChatBackend)? { backend }

    @ObservationIgnored private var backend: (any ChatBackend)?
    @ObservationIgnored private var deviceToken: Data?
    @ObservationIgnored private var registeredKey: String?
    @ObservationIgnored public private(set) var registration: Task<Void, Never>?
    @ObservationIgnored let environment: CommsPushEnvironment?
    @ObservationIgnored let platform: CommsPushPlatform

    public init(environment: CommsPushEnvironment? = PushEnvironment.current(), platform: CommsPushPlatform = PushEnvironment.platform) {
        self.environment = environment
        self.platform = platform
    }

    /// The signed-in backend (nil when signed out).
    public func setBackend(_ backend: (any ChatBackend)?) {
        self.backend = backend
        backendGeneration += 1
        if backend == nil { registeredKey = nil }
        registerIfReady()
    }

    /// From `didRegisterForRemoteNotificationsWithDeviceToken`.
    public func setDeviceToken(_ token: Data) {
        deviceToken = token
        registerIfReady()
    }

    /// A notification was tapped: its payload's `threadId` (ids only — never content).
    public func handleTap(userInfo: [AnyHashable: Any]) {
        guard (userInfo["type"] as? String) == "comms.message", let id = userInfo["threadId"] as? String, !id.isEmpty, id.count <= 200 else { return }
        pendingThreadID = id
    }

    /// The app came back to the foreground: send the registration again (it may have failed
    /// while offline, and the server stamps `last_seen_at`), whatever was sent before.
    public func reregister() {
        registeredKey = nil
        registerIfReady()
    }

    private func registerIfReady() {
        guard let backend, let token = deviceToken, let environment else { return }
        let key = token.base64EncodedString() + environment.rawValue
        guard key != registeredKey else { return }
        registeredKey = key
        let platform = self.platform
        registration = Task { [weak self] in
            do {
                let r = try await backend.registerPush(deviceToken: token, environment: environment, platform: platform)
                self?.serverPushEnabled = r.pushEnabled
            } catch {
                // Try again with the next token / sign-in.
                if self?.registeredKey == key { self?.registeredKey = nil }
            }
        }
    }
}

/// Which APNs environment this build's tokens belong to.
public enum PushEnvironment {
    #if os(macOS)
    public static let platform: CommsPushPlatform = .macos
    #else
    public static let platform: CommsPushPlatform = .ios
    #endif

    /// nil = this build has no push entitlement (Debug Mac, unsigned test runs): do not register.
    public static func current() -> CommsPushEnvironment? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String
        else { return nil }
        return map(value)
        #elseif targetEnvironment(simulator)
        return .sandbox
        #else
        // A development / ad hoc build embeds its profile; an App Store / TestFlight build has
        // none and is production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        return fromProvisioningProfile(data) ?? .production
        #endif
    }

    static func map(_ value: String) -> CommsPushEnvironment? {
        switch value {
        case "development": .sandbox
        case "production": .production
        default: nil
        }
    }

    /// The `aps-environment` entitlement of a (CMS-wrapped) provisioning profile.
    public static func fromProvisioningProfile(_ data: Data) -> CommsPushEnvironment? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let ent = root["Entitlements"] as? [String: Any] else { return nil }
        let value = (ent["aps-environment"] ?? ent["com.apple.developer.aps-environment"]) as? String
        return value.flatMap(map)
    }
}
