#if DEBUG
import CommsClient
import CommsCore
import CommsTestSupport
import CommsUI
import SwiftUI

/// DEBUG-only: `-CommsDemo YES` / `COMMS_DEMO=1`. None of this is compiled into Release.
enum DemoMode {
    static var isEnabled: Bool { LaunchMode.resolve(demoAllowed: true) == .demo }

    /// `-CommsSimulatedRecorder YES` (UI tests): audio messages record made-up levels, no microphone.
    static var simulatedRecorder: Bool { UserDefaults.standard.bool(forKey: "CommsSimulatedRecorder") }

    /// `-CommsDemoOmni YES` (UI tests): Omni in Comms over the fixture; Approve & Send's Face ID
    /// check is answered yes (the simulator has no enrolled face). Never in Release.
    static var omni: Bool { UserDefaults.standard.bool(forKey: "CommsDemoOmni") }
    static var omniLongDraft: Bool { UserDefaults.standard.bool(forKey: "CommsDemoOmniLongDraft") }

    /// `-CommsAppearance dark|light` (UI tests capture both appearances on one simulator).
    static var colorScheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "CommsAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }
}

/// The production app (`PhoneMainView`) over the fixture backend, with a "Demo" injector at
/// the top of Details for live events. Labelled as a preview in the list.
struct DemoRoot: View {
    @State private var backend = try? DemoBackend.make(omni: DemoMode.omni, longDraft: DemoMode.omniLongDraft)
    @State private var simulator: DemoSimulator?

    var body: some View {
        if let backend {
            let simulator = self.simulator ?? DemoSimulator(backend: backend)
            PhoneMainView(backend: backend, presence: FixedPresence(true), detailsAccessory: { id in
                AnyView(DemoInjector(simulator: simulator, threadID: id))
            })
            .onAppear { if self.simulator == nil { self.simulator = simulator } }
            // In the home-indicator strip, clear of the glass bars (its orange tinted them).
            .overlay {
                ZStack(alignment: .bottom) {
                    Color.clear
                    Text("DEMO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange, in: .capsule)
                        .padding(.bottom, 1)
                        .accessibilityIdentifier("preview-badge")
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .preferredColorScheme(DemoMode.colorScheme)
            .environment(\.simulatedVoiceRecorder, DemoMode.simulatedRecorder)
        } else {
            ContentUnavailableView("Demo fixtures missing", systemImage: "exclamationmark.triangle")
        }
    }
}

/// DEBUG preview only: inject live events into the open conversation.
private struct DemoInjector: View {
    let simulator: DemoSimulator
    let threadID: String

    var body: some View {
        Menu {
            Button("Inject Message") { simulator.injectMessage(threadID: threadID) }
            Button("Inject Reaction") { simulator.injectReaction(threadID: threadID) }
        } label: {
            Label("Demo", systemImage: "wand.and.stars")
        }
        .accessibilityIdentifier("demo-menu")
    }
}
#endif
