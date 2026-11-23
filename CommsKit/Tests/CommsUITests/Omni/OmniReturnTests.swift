@testable import CommsUI
import XCTest

/// Polish r2 (owner: "it won't send when I tag Omni … and press enter"): in Omni mode Return (Mac)
/// and the keyboard's Send key (iOS) submit the instruction exactly like the ✦ button.
final class OmniReturnTests: XCTestCase {
    func testSendKeyIsOneTypedNewline() {
        XCTAssertEqual(ComposerBar.omniSubmitOnReturn(old: "@Omni tell her", new: "@Omni tell her\n"), "@Omni tell her")
        // The caret in the middle: the newline is still the Send key; the text stays as it was.
        XCTAssertEqual(ComposerBar.omniSubmitOnReturn(old: "@Omni ab", new: "@Omni a\nb"), "@Omni ab")
        XCTAssertEqual(ComposerBar.omniSubmitOnReturn(old: "", new: "\n"), "")
    }

    func testOtherEditsAreNotASubmit() {
        XCTAssertNil(ComposerBar.omniSubmitOnReturn(old: "@Omni tell", new: "@Omni tell "), "typing")
        XCTAssertNil(ComposerBar.omniSubmitOnReturn(old: "@Omni tell", new: "@Omni tel"), "deleting")
        XCTAssertNil(ComposerBar.omniSubmitOnReturn(old: "@Omni", new: "@Omni a\nb"), "a paste with a newline")
        XCTAssertNil(ComposerBar.omniSubmitOnReturn(old: "@Omni a", new: "@Omni b\n"), "a replaced character")
    }

    func testMacReturnStillSendsAndOptionReturnIsANewline() {
        // Omni mode uses the same Return rule as a chat message: Return submits (to Omni),
        // Option/Shift-Return is a new line, an input method's Return is its own.
        XCTAssertEqual(ComposerBar.returnAction(option: false, shift: false, composing: false), .send)
        XCTAssertEqual(ComposerBar.returnAction(option: true, shift: false, composing: false), .newline)
        XCTAssertEqual(ComposerBar.returnAction(option: false, shift: false, composing: true), .passThrough)
    }
}
