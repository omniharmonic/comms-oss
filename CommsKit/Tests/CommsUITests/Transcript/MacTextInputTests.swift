#if os(macOS)
@testable import CommsUI
import XCTest

/// Round 3: the input-source accessory is switched off in Comms' own domain only, and an
/// explicit owner choice (true) is respected.
final class MacTextInputTests: XCTestCase {
    func testSuppressesTheIndicatorInTheAppDomainOnly() throws {
        let suite = "comms.test.textinput.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        MacTextInput.suppressInputSourceIndicator(d)
        XCTAssertEqual(d.object(forKey: MacTextInput.indicatorKey) as? Bool, false)

        let suite2 = "comms.test.textinput.\(UUID().uuidString)"
        let owner = try XCTUnwrap(UserDefaults(suiteName: suite2))
        defer { owner.removePersistentDomain(forName: suite2) }
        owner.set(true, forKey: MacTextInput.indicatorKey)
        MacTextInput.suppressInputSourceIndicator(owner)
        XCTAssertEqual(owner.object(forKey: MacTextInput.indicatorKey) as? Bool, true, "the owner's own choice stays")
    }
}
#endif
