import XCTest

/// Launch paths of the real Comms.app (Debug). Regression: the window once launched blank (the
/// main window's content was created in `onAppear` of an empty view, which a `WindowGroup`
/// never fires), so every launch must show its first screen promptly.
@MainActor
final class CommsMacLaunchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testDemoLaunchShowsTheSidebar() {
        app.launchArguments = ["-CommsDemo", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "a window")
        let rows = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread-row-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "the sidebar's rows within 10 s of launch")
        XCTAssertGreaterThan(rows.count, 3)
        XCTAssertTrue(window.descendants(matching: .any)["filter-button"].firstMatch.exists, "the sidebar toolbar")
        XCTAssertEqual(window.staticTexts.matching(NSPredicate(format: "value == 'Comms'")).count, 0, "no window title text (Messages shows none)")
    }

    /// No saved server (`-comms.serverOrigin ""` shadows any saved one for this launch only):
    /// the sign-in form, never an empty window.
    func testSignedOutLaunchShowsSignIn() {
        app.launchArguments = ["-comms.serverOrigin", "", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "a window")
        XCTAssertTrue(window.buttons["Sign In"].waitForExistence(timeout: 10), "the Sign In button")
        XCTAssertTrue(window.textFields.firstMatch.exists, "the server field")
        snap(app, "00-sign-in")
    }
}

/// Drives the real Comms.app (Debug) in demo mode (`-CommsDemo YES`: the staging rooms and
/// fixtures, no network, no sign-in), in the light appearance (`CommsMacUITestsDark` repeats
/// every test in dark). Every step's screenshot is attached to the result and exported to
/// design/refs/live/mac-<step>-<light|dark>.png.
@MainActor
class CommsMacUITests: XCTestCase {
    private var app: XCUIApplication!

    /// "light" or "dark" (`-CommsAppearance`, the demo window's DEBUG appearance switch).
    class var appearance: String { "light" }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-ApplePersistenceIgnoreState", "YES",
                               "-CommsAppearance", Self.appearance, "-CommsWindowSize", "1100x760"]
        app.launch()
        app.activate()
        XCTAssertTrue(row("Alice Example").waitForExistence(timeout: 15), "the demo sidebar never appeared")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    // MARK: Tests

    func testSidebarShowsTheStagingThreads() {
        XCTAssertTrue(row("Trail Crew").exists)
        XCTAssertTrue(row("bob").exists, "the plain DM")
        XCTAssertTrue(app.staticTexts["DEMO"].exists || app.descendants(matching: .any)["demo-badge"].exists)
        snap("01-sidebar")
    }

    func testTranscriptShowsTheStagingBubbles() {
        open("Alice Example")
        XCTAssertTrue(bubble(containing: "Hey! Plain first message.").waitForExistence(timeout: 10))
        // Formatted text (bold/italic/strike/code/link/quote) with 👍 and ❤️ on it.
        let formatted = bubble(containing: "bold italic strike")
        XCTAssertTrue(formatted.exists, "formatted message")
        XCTAssertTrue(formatted.label.contains(" by "), "reactions are read with the bubble: \(formatted.label)")
        XCTAssertTrue(bubble(containing: "typo message").exists, "edited message")
        XCTAssertTrue(app.staticTexts["Edited"].exists, "the Edited note")
        XCTAssertTrue(bubble(containing: "Replying to").exists, "the reply quote")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo'")).firstMatch.exists
            || bubble(containing: "Photo").exists, "the image bubble")
        // Messages chrome: FaceTime and Info circles in the transcript's toolbar band (Compose
        // only in the sidebar), the sidebar's search field, and the composer.
        XCTAssertFalse(app.descendants(matching: .any)["compose-button"].firstMatch.exists, "no second Compose in the transcript")
        XCTAssertTrue(app.descendants(matching: .any)["transcript-info"].firstMatch.exists, "the Info circle")
        XCTAssertTrue(app.descendants(matching: .any)["transcript-video"].firstMatch.exists, "FaceTime")
        XCTAssertTrue(app.descendants(matching: .any)["composer-plus"].firstMatch.exists, "the composer")
        XCTAssertTrue(app.searchFields.firstMatch.exists, "the sidebar search field")
        // The header pill is centred over the transcript column.
        let pill = app.buttons["transcript-name-pill"].firstMatch
        let table = app.tables["transcript"].firstMatch
        XCTAssertEqual(pill.frame.midX, table.frame.midX, accuracy: 2, "header centred over the transcript column")
        snap("02-transcript-alice")
        // ⌘F focuses the search field.
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Trail")
        XCTAssertTrue(row("Trail Crew").waitForExistence(timeout: 3))
        XCTAssertFalse(row("Theo Marsh").exists, "search narrows the list")
        app.typeKey(.escape, modifierFlags: [])

        open("Trail Crew")
        XCTAssertTrue(bubble(containing: "Hey! Plain first message.").waitForExistence(timeout: 10))
        snap("03-transcript-group")
    }

    func testScrollingUpLoadsOlderHistory() {
        open("Alice Example")
        XCTAssertTrue(bubble(containing: "Hey! Plain first message.").waitForExistence(timeout: 10))
        let table = app.tables["transcript"].firstMatch
        XCTAssertTrue(table.exists, "the transcript table")
        let oldest = bubble(containing: "Older message 50 (page 2)")
        for _ in 0..<25 where !oldest.exists {
            table.scroll(byDeltaX: 0, deltaY: 1500)
        }
        XCTAssertTrue(bubble(containing: "Older message").exists, "older history loaded")
        XCTAssertTrue(oldest.exists, "both older pages loaded")
        snap("04-older-history")
    }

    func testInspectorShowsPhotosAndLinks() {
        open("Alice Example")
        XCTAssertTrue(bubble(containing: "Hey! Plain first message.").waitForExistence(timeout: 10))
        app.typeKey("i", modifierFlags: [.command, .option])
        let inspector = app.descendants(matching: .any)["inspector"].firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "⌥⌘I opens the inspector")
        let photos = inspector.buttons["Photos"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "the Photos tab")
        photos.click()
        // The transcript column narrowed: bubbles reflow inside it and the header re-centres.
        let table = app.tables["transcript"].firstMatch
        let first = bubble(containing: "Hey! Plain first message.")
        XCTAssertGreaterThanOrEqual(first.frame.minX, table.frame.minX + 8, "incoming bubbles keep their leading margin")
        XCTAssertLessThanOrEqual(table.frame.maxX, inspector.frame.minX + 1, "the column ends at the inspector")
        let pill = app.buttons["transcript-name-pill"].firstMatch
        XCTAssertEqual(pill.frame.midX, table.frame.midX, accuracy: 2, "header re-centred over the narrower column")
        snap("05-inspector-photos")
        inspector.buttons["Links"].firstMatch.click()
        snap("06-inspector-links")
        // The name pill toggles it too.
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "⌥⌘I closes the inspector")
        XCTAssertTrue(pill.exists, "the name pill")
        pill.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "the name pill opens the inspector")
        pill.click()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "and closes it")
        let info = app.descendants(matching: .any)["transcript-info"].firstMatch
        info.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "the Info circle opens it")
        info.click()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "and closes it")
    }

    func testFolderSwitching() {
        // ⌃⌘5: Archived.
        app.typeKey("5", modifierFlags: [.control, .command])
        XCTAssertTrue(row("Old Roommates").waitForExistence(timeout: 5), "Archived via ⌃⌘5")
        XCTAssertFalse(row("Alice Example").exists)
        snap("07-folder-archived")
        // The Filter menu: Low Priority.
        let filter = app.descendants(matching: .any)["filter-button"].firstMatch
        XCTAssertTrue(filter.exists, "the Filter button")
        filter.click()
        let low = app.menuItems["Low Priority"].firstMatch
        XCTAssertTrue(low.waitForExistence(timeout: 5))
        snap("08-filter-menu")
        low.click()
        XCTAssertTrue(row("Coastline Deals").waitForExistence(timeout: 5), "Low Priority via the Filter menu")
        // ⌃⌘1: back to Messages.
        app.typeKey("1", modifierFlags: [.control, .command])
        XCTAssertTrue(row("Alice Example").waitForExistence(timeout: 5), "Messages via ⌃⌘1")
    }

    func testLiveMessageAndReactionAppear() {
        open("Alice Example")
        XCTAssertTrue(bubble(containing: "Hey! Plain first message.").waitForExistence(timeout: 10))
        app.menuBarItems["Demo"].click()
        let injectMessage = app.menuItems["demo-inject-message"].firstMatch
        (injectMessage.waitForExistence(timeout: 2) ? injectMessage : app.menuItems["Inject Message"].firstMatch).click()
        let live = bubble(containing: "Live message 1")
        XCTAssertTrue(live.waitForExistence(timeout: 5), "the injected message appears in the transcript")
        XCTAssertTrue(row("Live message 1").waitForExistence(timeout: 5), "and in the sidebar row preview")
        XCTAssertFalse(row("Live message 1").label.contains("unread"), "the open conversation reads as read: \(row("Live message 1").label)")
        app.menuBarItems["Demo"].click()
        let inject = app.menuItems["demo-inject-reaction"].firstMatch
        (inject.waitForExistence(timeout: 2) ? inject : app.menuItems["Inject Reaction"].firstMatch).click()
        let reacted = bubble(containing: "Live message 1")
        let predicate = NSPredicate(format: "label CONTAINS ' by '")
        expectation(for: predicate, evaluatedWith: reacted)
        waitForExpectations(timeout: 5)
        snap("09-live-message-reaction")
    }

    // MARK: Helpers

    /// A sidebar row (`thread-row-<id>`) or pinned tile (`thread-tile-<id>`) whose label
    /// contains `text`.
    private func row(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "(identifier BEGINSWITH 'thread-row-' OR identifier BEGINSWITH 'thread-tile-') AND label CONTAINS %@", text))
            .firstMatch
    }

    /// A transcript element whose label contains `text` (never a sidebar row or tile, whose
    /// preview can carry the same text).
    private func bubble(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'thread-row-' OR identifier BEGINSWITH 'thread-tile-')", text))
            .firstMatch
    }

    private func open(_ title: String) {
        let r = app.descendants(matching: .any)
            .matching(NSPredicate(format: "(identifier BEGINSWITH 'thread-row-' OR identifier BEGINSWITH 'thread-tile-') AND label BEGINSWITH %@", "\(title),"))
            .firstMatch
        XCTAssertTrue(r.waitForExistence(timeout: 5), "row \(title)")
        r.click()
    }

    private func snap(_ name: String) {
        snap(app, "\(name)-\(Self.appearance)")
    }
}

/// Every `CommsMacUITests` test again, in the dark appearance.
final class CommsMacUITestsDark: CommsMacUITests {
    override class var appearance: String { "dark" }
}

extension XCTestCase {
    /// Attach the window's screenshot as `mac-<name>`. The sandboxed runner cannot write into
    /// the repo; scripts/run-mac-ui-tests.sh exports these to design/refs/live/mac-<name>.png.
    @MainActor
    func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "mac-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
