import CommsCore
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Opens a call-menu URL (FaceTime, Phone, a network's app) — separate from message links
/// (`SafeLinks`): only what `CallLinks` allows ever leaves the app, and only from a person's
/// explicit choice in a call menu. No `canOpenURL` is used, so iOS needs no
/// `LSApplicationQueriesSchemes`; a scheme with no app installed simply does nothing (iOS)
/// or shows the system's "no application" alert (macOS).
@MainActor
public enum CallOpener {
    /// Replaced by tests (records instead of opening).
    static var open: (URL) -> Void = { url in
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Open `url` if the call allowlist admits it. Returns whether it was handed to the system.
    @discardableResult
    public static func openIfAllowed(_ url: URL) -> Bool {
        guard CallLinks.isAllowed(url) else { return false }
        open(url)
        return true
    }
}
