import CommsClient
import CommsCore
import CommsUI
import PrismAuth
import AppKit
import AuthenticationServices
import SwiftUI
import UserNotifications

@main
struct CommsMacApp: App {
    @NSApplicationDelegateAdaptor(CommsMacDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Comms") {
            #if DEBUG
            if DemoMode.isEnabled {
                DemoWindow()
            } else {
                signedInRoot
            }
            #else
            signedInRoot
            #endif
        }
        // Messages-sized; the sidebar's floating glass carries the traffic lights and the
        // window shows no title text (`ThreadListSplitView` and the sign-in view remove it).
        // The content's minimum size also clamps a stale, too-small saved frame (one
        // restored at 900 × 450 hid the composer).
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        #if DEBUG
        .commands { DemoCommands() }
        #endif

        // Comms › Settings… (⌘,): Notifications (Sprint Task 1).
        Settings { CommsSettingsWindow() }
    }

    /// Sign-in, then the main window over the signed-in session's backend.
    private var signedInRoot: some View {
        RootView(
                makeSession: { origin in
                    Session(
                        origin: origin,
                        store: Self.tokenStore,
                        backendFactory: { PrismChatBackend(client: CommsClient(client: $0)) },
                        // The comms-native client may only return to its own `comms://auth/callback`
                        // (the server refuses loopback redirects for restricted clients), so the Mac
                        // signs in with ASWebAuthenticationSession exactly like the iPhone app.
                        signer: DeviceSignInSigner(
                            origin: origin, store: Self.tokenStore,
                            flow: WebAuthenticationSessionFlow(configuration: .commsNative, anchor: { Self.presentationAnchor() })),
                        deviceLabel: "Comms on \(Self.hostName)"
                    )
                },
                ready: { session in
                    AnyView(Group {
                        if let backend = session.backend { MainWindow(backend: backend) }
                    })
                }
            )
    }

    /// The window the sign-in sheet attaches to.
    @MainActor private static func presentationAnchor() -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }

    /// Read once; `Host.current()` can block on name lookups.
    private static let hostName = ProcessInfo.processInfo.hostName

    /// Release (Developer ID + profile): the data-protection keychain, migrating a token the
    /// earlier login-keychain build stored. Debug: the login keychain (see `CommsTokenStorage`).
    private static var tokenStore: any TokenStore { CommsTokenStorage.keychain() }
}

/// Remote notifications (Sprint Task 1). Registers with APNs only when this build carries the
/// push entitlement (Release, Developer ID profile); Debug / demo / UI-test runs ask nothing.
/// Payloads are ids only as far as this code is concerned: nothing is logged.
final class CommsMacDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Round 3 (owner): no floating input-source panel (ABC · emoji · globe · mic).
        MacTextInput.suppressInputSourceIndicator()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DemoMode.isEnabled { return }
        #endif
        guard PushEnvironment.current() != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            CommsPushCenter.shared.permissionGranted = granted
            NSApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in CommsPushCenter.shared.setDeviceToken(deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // No token: notifications stay off on this Mac; the in-app list still updates live.
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let type = info["type"] as? String
        let thread = info["threadId"] as? String
        await MainActor.run {
            CommsPushCenter.shared.handleTap(userInfo: ["type": type as Any, "threadId": thread as Any])
            NSApplication.shared.activate()
        }
    }
}
