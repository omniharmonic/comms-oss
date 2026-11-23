import Foundation
import PrismAuth
#if os(macOS)
import Security
#endif

/// Where Comms keeps its device tokens: one Keychain item per server origin under the app's
/// identifier. The keychain flavour is chosen per platform:
///
/// - **iOS / iPadOS**: the data-protection keychain (this-device-only items). Automatic
///   development signing gives the app its application identifier, which that keychain needs.
/// - **macOS**: the data-protection keychain when the running app is signed with an
///   `application-identifier` (the Release build, Developer ID + the "Comms Developer ID"
///   provisioning profile — ruling R20 retired, Sprint Task 1). Builds without one (Debug's
///   local signing, UI tests) keep the legacy login keychain, which needs no entitlement; the
///   data-protection keychain would fail there with -34018 (errSecMissingEntitlement).
///   A token the earlier login-keychain build stored moves over once, on first read
///   (`MigratingTokenStore`).
public enum CommsTokenStorage {
    public static let service = "com.example.comms"

    #if os(macOS)
    /// True when this process carries an application identifier (checked once).
    /// Off on macOS for now: with the Developer ID build the data-protection keychain write
    /// appeared to succeed but the token could not be read back, so every sign-in was silently
    /// lost (owner, 2026-11-22). The login keychain (0.2.x behaviour, ruling R20) is used until
    /// that is diagnosed; `hasApplicationIdentifier()` stays for the diagnosis.
    public static let usesDataProtectionKeychain: Bool = false

    private static func hasApplicationIdentifier() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
        return (value as? String)?.isEmpty == false
    }
    #else
    public static let usesDataProtectionKeychain = true
    #endif

    public static func keychain() -> any TokenStore {
        let primary = KeychainTokenStore(service: service, useDataProtectionKeychain: usesDataProtectionKeychain)
        #if os(macOS)
        if usesDataProtectionKeychain {
            return MigratingTokenStore(primary: primary, legacy: KeychainTokenStore(service: service, useDataProtectionKeychain: false))
        }
        #endif
        return primary
    }
}

/// Reads through to a legacy store once: a token found only in `legacy` is written to
/// `primary`, and removed from `legacy` only after that write succeeded (a failed write keeps
/// the old item, so the owner stays signed in). Writes and removals go to `primary`, and
/// removals also clear `legacy` — signing out never leaves an old copy behind.
public struct MigratingTokenStore: TokenStore {
    let primary: any TokenStore
    let legacy: any TokenStore

    public init(primary: any TokenStore, legacy: any TokenStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func token(for origin: ServerOrigin) throws -> String? {
        // A failing data-protection read falls back to the legacy item instead of signing the
        // owner out (review M6); with neither readable the primary's error is reported.
        let fresh: String?
        do {
            fresh = try primary.token(for: origin)
        } catch {
            if let old = try? legacy.token(for: origin) { return old }
            throw error
        }
        if let fresh { return fresh }
        guard let old = try? legacy.token(for: origin) else { return nil }
        do {
            try primary.setToken(old, for: origin)
        } catch {
            return old // the new keychain refused: keep using (and keeping) the old item
        }
        try? legacy.removeToken(for: origin)
        return old
    }

    public func setToken(_ token: String, for origin: ServerOrigin) throws {
        do {
            try primary.setToken(token, for: origin)
        } catch {
            // The data-protection keychain refused the write (seen on the owner's Mac with the
            // Developer ID build): keep the owner signed in with the login keychain instead of
            // failing the sign-in. Reads already fall back to `legacy`.
            Self.lastPrimaryWriteError = String(describing: error)
            try legacy.setToken(token, for: origin)
            return
        }
        try? legacy.removeToken(for: origin)
    }

    /// The last data-protection write failure (diagnostics; shown in Settings › About).
    nonisolated(unsafe) public static var lastPrimaryWriteError: String?

    public func removeToken(for origin: ServerOrigin) throws {
        try? legacy.removeToken(for: origin)
        try primary.removeToken(for: origin)
    }
}
