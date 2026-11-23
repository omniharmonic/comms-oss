import AuthenticationServices
import CommsClient
import CommsCore
import CommsUI
import PrismAuth
import SwiftUI
import UIKit
import UserNotifications

/// Comms for iPhone and iPad — Phase 1, read-only. Sign in to a Prism server (the browser leg
/// is `ASWebAuthenticationSession` with the `comms://auth/callback` redirect, which the
/// session receives directly: no URL type is registered), then the
/// conversation list and transcripts, kept live by the server's event stream. Nothing is
/// ever sent from this build.
///
/// DEBUG builds launched with `-CommsDemo YES` run over the demo fixtures instead (UI tests);
/// Release builds contain no demo code.
@main
struct CommsiOSApp: App {
    @UIApplicationDelegateAdaptor(CommsiOSDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if DemoMode.isEnabled {
                DemoRoot()
            } else {
                signedInRoot
            }
            #else
            signedInRoot
            #endif
        }
    }

    /// Sign-in, then the app over the signed-in session's backend.
    private var signedInRoot: some View {
        RootView(
            makeSession: { origin in
                let store = Self.tokenStore
                return Session(
                    origin: origin,
                    store: store,
                    backendFactory: { PrismChatBackend(client: CommsClient(client: $0)) },
                    signer: DeviceSignInSigner(
                        origin: origin, store: store,
                        flow: WebAuthenticationSessionFlow(configuration: .commsNative, anchor: { Self.presentationAnchor() })),
                    deviceLabel: "Comms on \(UIDevice.current.name)"
                )
            },
            ready: { session in
                AnyView(Group {
                    if let backend = session.backend {
                        PhoneMainView(backend: backend, onSignOut: {
                            Task {
                                await session.signOut()
                                try? await UNUserNotificationCenter.current().setBadgeCount(0) // review M4
                            }
                        })
                    }
                })
            }
        )
    }

    /// One Keychain item per server origin, this device only (the data-protection keychain;
    /// see `CommsTokenStorage`).
    private static var tokenStore: any TokenStore { CommsTokenStorage.keychain() }

    @MainActor
    private static func presentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let key = windows.first(where: \.isKeyWindow) { return key }
        if let any = windows.first { return any }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        return ASPresentationAnchor()
    }
}

/// Remote notifications (Sprint Task 1): ask once, register with APNs, open the thread a tapped
/// notification names. Demo / UI-test runs ask nothing (no permission alert in tests).
final class CommsiOSDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if DemoMode.isEnabled { return true }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            CommsPushCenter.shared.permissionGranted = granted
            UIApplication.shared.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in CommsPushCenter.shared.setDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {}

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let type = info["type"] as? String
        let thread = info["threadId"] as? String
        await MainActor.run { CommsPushCenter.shared.handleTap(userInfo: ["type": type as Any, "threadId": thread as Any]) }
    }
}
