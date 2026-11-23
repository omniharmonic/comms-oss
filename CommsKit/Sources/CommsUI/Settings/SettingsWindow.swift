#if os(macOS)
import CommsCore
import SwiftUI

/// The Mac app's Settings window (Comms › Settings…, ⌘,): Notifications. It follows the
/// signed-in window's backend; signed out, it says so.
public struct CommsSettingsWindow: View {
    private let push = CommsPushCenter.shared
    @State private var store: NotificationSettingsStore?
    @State private var generation = -1

    public init() {}

    public var body: some View {
        TabView {
            Tab("Notifications", systemImage: "bell.badge") {
                Group {
                    if let store {
                        NotificationSettingsView(store: store, devicePermission: push.permissionGranted)
                    } else {
                        ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.questionmark",
                                               description: Text("Sign in to Comms to choose what notifies you."))
                    }
                }
                .frame(width: 500, height: 620)
            }
        }
        .onChange(of: push.backendGeneration, initial: true) { _, g in
            guard g != generation else { return }
            generation = g
            store = push.currentBackend.map { NotificationSettingsStore(backend: $0) }
        }
    }
}
#endif
