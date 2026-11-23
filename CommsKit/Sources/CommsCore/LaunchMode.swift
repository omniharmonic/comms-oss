import Foundation

/// What the app shows at launch: the demo window (DEBUG builds asked for it) or sign-in,
/// which becomes the main window once a session is ready.
public enum LaunchMode: Equatable, Sendable {
    case demo
    case signIn

    /// `-CommsDemo YES` on the command line (it lands in the defaults' argument domain) or
    /// `COMMS_DEMO=1` in the environment asks for the demo; anything else signs in.
    /// Release builds never pass `demoAllowed`.
    public static func resolve(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment, demoAllowed: Bool) -> LaunchMode {
        guard demoAllowed else { return .signIn }
        return defaults.bool(forKey: "CommsDemo") || environment["COMMS_DEMO"] == "1" ? .demo : .signIn
    }
}
