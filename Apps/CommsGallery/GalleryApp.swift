#if DEBUG
import CommsTestSupport
import CommsUI
import SwiftUI

/// Developer tool, never shipped: the Comms design gallery (Comms renders from the staging
/// fixtures next to Apple's reference screenshots). Not sandboxed: it reads the references
/// from the repo checkout. Build the CommsGallery scheme (Debug).
@main
struct GalleryApp: App {
    var body: some Scene {
        WindowGroup("Comms Design Gallery") {
            if let backend = try? FixtureBackend.staging() {
                DesignGallery(backend: backend)
            } else {
                Text("Staging fixtures failed to load.")
            }
        }
    }
}
#endif
