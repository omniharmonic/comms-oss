#if DEBUG
import CommsCore
import CommsTestSupport
import CommsUI
import AppKit
import SwiftUI

/// DEBUG-only demo mode: `-CommsDemo YES` (or `COMMS_DEMO=1`) skips sign-in and runs the app
/// over `DemoBackend` (staging rooms + fixtures; nothing touches the network or the keychain).
/// The Demo menu injects live events; `COMMS_DEMO_LIVE=1` also starts the live simulation
/// (an event every few seconds) at launch. None of this is compiled into Release.
enum DemoMode {
    static var isEnabled: Bool { LaunchMode.resolve(demoAllowed: true) == .demo }
    static var startsLive: Bool { ProcessInfo.processInfo.environment["COMMS_DEMO_LIVE"] == "1" }
    /// `-CommsAppearance light|dark` pins the demo window's appearance (UI-test screenshots in
    /// both); otherwise it follows the system.
    /// `-CommsWindowSize 1100x760` sizes the demo window at launch (a saved window frame
    /// otherwise wins over the scene's default size), so screenshots are comparable.
    static var windowSize: CGSize? {
        guard let parts = UserDefaults.standard.string(forKey: "CommsWindowSize")?.split(separator: "x"),
              parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return CGSize(width: w, height: h)
    }
    /// `-CommsSimulatedRecorder YES` (UI tests): audio messages record made-up levels, no microphone.
    static var simulatedRecorder: Bool { UserDefaults.standard.bool(forKey: "CommsSimulatedRecorder") }
    static var colorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "CommsAppearance") {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

/// The demo backend and its simulator, shared by the window and the Demo menu.
@MainActor @Observable
final class DemoController {
    static let shared = DemoController()

    let backend: FixtureBackend?
    let simulator: DemoSimulator?
    /// The open conversation, else "Alice Example".
    var selectedThreadID: String?
    private(set) var isLive = false
    private var liveTask: Task<Void, Never>?
    private var tick = 0

    private init() {
        // `-CommsDemoOmni YES`: Omni in Comms over the fixture (DEBUG demo only).
        let backend = try? DemoBackend.make(omni: UserDefaults.standard.bool(forKey: "CommsDemoOmni"))
        self.backend = backend
        simulator = backend.map(DemoSimulator.init)
    }

    private var target: String { selectedThreadID ?? DemoBackend.aliceThreadID }

    func injectMessage() { simulator?.injectMessage(threadID: target) }
    func injectReaction() { simulator?.injectReaction(threadID: target) }

    func setLive(_ on: Bool) {
        liveTask?.cancel()
        liveTask = nil
        isLive = on
        guard on else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                if tick % 3 == 0 { injectReaction() } else { injectMessage() }
            }
        }
    }
}

/// The main window over the demo backend, with a "DEMO" badge so it is never mistaken for live data.
struct DemoWindow: View {
    @State private var demo = DemoController.shared

    var body: some View {
        if let backend = demo.backend {
            // The demo answers the Touch ID check itself (fixture data, nothing leaves the Mac).
            MainWindow(backend: backend, presence: FixedPresence(true), onSelectionChange: { demo.selectedThreadID = $0 })
                // Top-trailing, left of the FaceTime circle: at the bottom it covered the
                // composer's emoji button.
                .overlay(alignment: .topTrailing) {
                    Text(demo.isLive ? "DEMO · LIVE" : "DEMO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: .capsule)
                        .padding(.top, 2)
                        .padding(.trailing, 60)
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("demo-badge")
                }
                .preferredColorScheme(DemoMode.colorScheme)
                .environment(\.simulatedVoiceRecorder, DemoMode.simulatedRecorder)
                .onAppear {
                    if DemoMode.startsLive, !demo.isLive { demo.setLive(true) }
                    if let size = DemoMode.windowSize {
                        // After this pass, once the window is on screen.
                        Task { @MainActor in
                            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                            window.setContentSize(size)
                            window.center()
                        }
                    }
                }
        } else {
            ContentUnavailableView("Demo fixtures missing", systemImage: "exclamationmark.triangle")
        }
    }
}

/// Demo ▸ Inject Message (⌃⌥⌘M), Inject Reaction (⌃⌥⌘R), Live Simulation (⌃⌥⌘L).
struct DemoCommands: Commands {
    var body: some Commands {
        CommandMenu("Demo") {
            Button("Inject Message") { DemoController.shared.injectMessage() }
                .keyboardShortcut("m", modifiers: [.control, .option, .command])
                .accessibilityIdentifier("demo-inject-message")
                .disabled(!DemoMode.isEnabled)
            Button("Inject Reaction") { DemoController.shared.injectReaction() }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
                .accessibilityIdentifier("demo-inject-reaction")
                .disabled(!DemoMode.isEnabled)
            Button("Toggle Live Simulation") { DemoController.shared.setLive(!DemoController.shared.isLive) }
                .keyboardShortcut("l", modifiers: [.control, .option, .command])
                .disabled(!DemoMode.isEnabled)
        }
    }
}
#endif
