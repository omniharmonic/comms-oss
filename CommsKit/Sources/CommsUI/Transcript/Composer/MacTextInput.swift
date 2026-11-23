#if os(macOS)
import Foundation

/// Round 3 (owner, 0.3.3): "a panel that looks like an iOS keyboard (ABC, emoji, globe, mic)
/// floats at the top-right of the window behind ⓘ". Nothing in Comms draws it: it is macOS 26's
/// TextInputUI cursor accessory (a `TUINSWindow`, the input-source indicator with its emoji,
/// input-menu and dictation buttons), which the system opens when a text field (the composer)
/// takes focus and anchors at the caret — and leaves where it was when the layout moves on.
/// The indicator is a Text Services Manager preference (`TSMLanguageIndicatorEnabled`, the key
/// behind the global "input source indicator"); it is switched off for Comms only, in Comms'
/// own preferences domain (no other app, and not the owner's global setting, is touched).
public enum MacTextInput {
    public static let indicatorKey = "TSMLanguageIndicatorEnabled"

    /// Before the first window: Comms' text fields show no input-source accessory.
    public static func suppressInputSourceIndicator(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [indicatorKey: false])
        // Registered values are volatile; the Text Services Manager reads the app's persistent
        // domain, so it is written there too (only when the owner has not set it himself).
        if defaults.object(forKey: indicatorKey) as? Bool != true {
            defaults.set(false, forKey: indicatorKey)
        }
    }
}
#endif
