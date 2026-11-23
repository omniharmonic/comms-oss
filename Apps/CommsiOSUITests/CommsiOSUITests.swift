import XCTest

/// Launches the iOS app (Debug) in demo mode on a simulator, opens a thread and exports
/// screenshots to design/refs/live/ios-*.png (and attaches them to the result).
@MainActor
final class CommsiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(appearance: String = "light") {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", appearance]
        app.launch()
    }

    /// The fidelity captures (design/fidelity): the screens the real Messages references show,
    /// in light and dark, each with an accessibility-frame dump (`*.ax.txt`) for diff.py.
    func testFidelityCapturesLight() { fidelityCaptures(appearance: "light") }
    func testFidelityCapturesDark() { fidelityCaptures(appearance: "dark") }

    private func fidelityCaptures(appearance: String) {
        launch(appearance: appearance)
        let jamie = element(labelBeginsWith: "Jamie Abbott,")
        XCTAssertTrue(jamie.waitForExistence(timeout: 15), "the demo list")
        snap("list-\(appearance)", ax: true)

        jamie.tap()
        XCTAssertTrue(app.descendants(matching: .any)["receipt"].firstMatch.waitForExistence(timeout: 10), "Delivered under the newest message")
        XCTAssertEqual(app.staticTexts["receipt"].firstMatch.label, "Delivered")
        XCTAssertTrue(app.buttons["composer-plus"].exists, "the composer")
        XCTAssertFalse(app.buttons["composer-send"].exists, "no send arrow while empty")
        snap("transcript-\(appearance)", ax: true)

        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        field.tap()
        field.typeText("Typing a longer reply so the composer grows onto two lines")
        XCTAssertTrue(app.buttons["composer-send"].waitForExistence(timeout: 3), "the send arrow morphs in")
        snap("composer-text-\(appearance)", ax: true)
        // Demo backend: the fixture answers the send (nothing leaves the simulator) and echoes it.
        app.buttons["composer-send"].tap()
        XCTAssertTrue(app.buttons["composer-send"].waitForNonExistence(timeout: 3), "sent: the draft clears")
        XCTAssertTrue(element(labelContains: "Typing a longer reply").waitForExistence(timeout: 5), "the sent bubble")
    }

    /// "+" opens Messages' app menu; "Audio" turns the field into the recorder (red waveform,
    /// timer, stop), then preview (play, send); sending posts an audio bubble. Demo backend and
    /// a simulated recorder: no microphone, nothing leaves the simulator.
    func testPlusMenuAndAudioRecorder() {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", "light", "-CommsSimulatedRecorder", "YES"]
        app.launch()
        let theo = element(labelBeginsWith: "Theo Marsh,")
        XCTAssertTrue(theo.waitForExistence(timeout: 15), "the demo list")
        theo.tap()

        let plus = app.buttons["composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["composer-record"].exists, "the field's waveform records audio")
        plus.tap()
        for item in ["Photos", "Audio", "Files"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), "+ menu: \(item)")
        }
        snap("send-plus-menu")
        app.buttons["Audio"].tap()

        let stop = app.buttons["recorder-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "recording: the stop button")
        XCTAssertTrue(app.buttons["recorder-delete"].exists, "cancel")
        Thread.sleep(forTimeInterval: 1.2)
        snap("send-recording")
        stop.tap()
        XCTAssertTrue(app.buttons["recorder-play"].waitForExistence(timeout: 3), "preview: play")
        XCTAssertTrue(app.buttons["recorder-send"].exists, "preview: send")
        snap("send-recorded")
        app.buttons["recorder-send"].tap()
        XCTAssertTrue(app.buttons["recorder-send"].waitForNonExistence(timeout: 3), "the recorder closes")
        XCTAssertTrue(plus.waitForExistence(timeout: 3), "back to the + and the field")
        XCTAssertTrue(element(labelBeginsWith: "Audio message").waitForExistence(timeout: 5) || element(labelContains: "Audio message").exists,
                      "the audio bubble")

        // Deleting a recording sends nothing.
        app.buttons["composer-record"].tap()
        XCTAssertTrue(app.buttons["recorder-delete"].waitForExistence(timeout: 5))
        app.buttons["recorder-delete"].tap()
        XCTAssertTrue(app.buttons["recorder-stop"].waitForNonExistence(timeout: 3))
    }

    /// Messages' interaction menu on a bubble (demo backend, nothing leaves the simulator):
    /// long press → the glass tapback bar + action menu → ❤️ → the badge; Reply → the reply
    /// banner; a tap on someone else's badges → who reacted, by name.
    func testLongPressTapbackAndReactionDetails() {
        launch()
        let theo = element(labelBeginsWith: "Theo Marsh,")
        XCTAssertTrue(theo.waitForExistence(timeout: 15), "the demo list")
        theo.tap()

        let bubble = element(labelBeginsWith: "Theo Marsh: Call me when you can")
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the incoming message")
        bubble.press(forDuration: 0.8)
        let love = app.buttons["tapback-love"]
        XCTAssertTrue(love.waitForExistence(timeout: 3), "the tapback bar")
        for t in ["tapback-like", "tapback-dislike", "tapback-laugh", "tapback-emphasize", "tapback-question", "tapback-more"] {
            XCTAssertTrue(app.buttons[t].exists, t)
        }
        for item in ["reply", "copy", "translate", "select"] {
            XCTAssertTrue(app.buttons["message-menu-\(item)"].exists, "menu: \(item)")
        }
        snap("reactions-menu")
        love.tap()
        XCTAssertTrue(love.waitForNonExistence(timeout: 3), "the overlay closes")
        XCTAssertTrue(element(labelContains: "Loved by you").waitForExistence(timeout: 3), "the badge, at once")
        snap("reactions-badge")

        // Reply from the menu: the composer shows what it answers.
        bubble.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["message-menu-reply"].waitForExistence(timeout: 3))
        app.buttons["message-menu-reply"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reply-banner"].waitForExistence(timeout: 3), "replying")
        app.buttons["reply-cancel"].tap()

        // Someone else's reactions: who it was.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let climbers = element(labelBeginsWith: "Weekend Climbers,")
        XCTAssertTrue(climbers.waitForExistence(timeout: 10))
        climbers.tap()
        let liked = element(labelBeginsWith: "Noor Haddad: Who's driving Saturday?")
        XCTAssertTrue(liked.waitForExistence(timeout: 10))
        XCTAssertTrue(liked.label.contains("Liked by Eli Brandt and Priya Natarajan"), liked.label)
        // The badges sit at the bubble's top trailing corner (incoming).
        liked.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: liked.frame.width - 8, dy: 9)).tap()
        let eli = element(labelBeginsWith: "Eli Brandt: Thumbs Up")
        XCTAssertTrue(eli.waitForExistence(timeout: 3), "the reaction details list names who reacted")
        XCTAssertTrue(element(labelBeginsWith: "Priya Natarajan: Thumbs Up").exists)
        snap("reactions-details")
    }

    /// iMessage has no threaded replies (BlueBubbles): Reply still quotes the message, with the
    /// note that it goes out as a normal message. No tapback bar there (react is false).
    func testIMessageReplyQuotesWithNote() {
        launch()
        let jamie = element(labelBeginsWith: "Jamie Abbott,")
        XCTAssertTrue(jamie.waitForExistence(timeout: 15))
        jamie.tap()
        let bubble = element(labelBeginsWith: "You: See you soon")
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        bubble.press(forDuration: 0.8)
        let reply = app.buttons["message-menu-reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 3), "Reply offered on iMessage")
        XCTAssertFalse(app.buttons["tapback-love"].exists, "no tapbacks on iMessage")
        reply.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reply-banner"].waitForExistence(timeout: 3))
        let note = app.staticTexts["reply-note"]
        XCTAssertTrue(note.exists)
        XCTAssertEqual(note.label, "Sent as a normal message — iMessage threaded replies aren't available")
        snap("reply-imessage-note")
        app.buttons["reply-cancel"].tap()
    }

    // MARK: Task 5 (polish)

    private func launchPolish() {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", "light", "-CommsDemoPolish", "YES"]
        app.launch()
    }

    /// Any emoji as a reaction: long-press → the smiley → search "taco" → pick → the badge.
    func testEmojiPickerReactsWithAnyEmoji() {
        launch()
        let theo = element(labelBeginsWith: "Theo Marsh,")
        XCTAssertTrue(theo.waitForExistence(timeout: 15), "the demo list")
        theo.tap()
        let bubble = element(labelBeginsWith: "Theo Marsh: Call me when you can")
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        bubble.press(forDuration: 0.8)
        let more = app.buttons["tapback-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), "the smiley beside the tapbacks")
        more.tap()
        let search = app.textFields["emoji-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the emoji picker")
        XCTAssertTrue(app.buttons["emoji-grinning face"].exists, "the full grid")
        snap("emoji-picker")
        focus(search)
        search.typeText("taco")
        let taco = app.buttons["emoji-taco"].firstMatch
        XCTAssertTrue(taco.waitForExistence(timeout: 3), "search finds the taco")
        snap("emoji-picker-search")
        taco.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3), "the picker closes")
        XCTAssertTrue(element(labelContains: "Reacted 🌮 by you").waitForExistence(timeout: 5), "the 🌮 badge")
        snap("emoji-picker-badge")
    }

    /// A merged conversation (Jonah on Telegram and WhatsApp): the placeholder is "Telegram ⌄"
    /// (his latest message came on Telegram); picking WhatsApp switches it.
    func testMergedConversationChannelPicker() {
        launchPolish()
        let jonah = element(labelBeginsWith: "Jonah Reyes,")
        XCTAssertTrue(jonah.waitForExistence(timeout: 15))
        jonah.tap()
        let picker = app.buttons["composer-channel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the channel picker in the placeholder")
        XCTAssertEqual(picker.label, "Send with Telegram", "default: the newest inbound message's channel")
        snap("channel-picker")
        picker.tap()
        let whatsapp = app.buttons["WhatsApp"].firstMatch
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 3), "the person's channels")
        snap("channel-picker-menu")
        whatsapp.tap()
        XCTAssertTrue(app.buttons["Send with WhatsApp"].waitForExistence(timeout: 3), "switched")
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        // The placeholder itself is the picker: focus the field beside it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        field.typeText("Over WhatsApp")
        XCTAssertFalse(app.buttons["composer-channel"].exists, "the text takes the field")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(element(labelContains: "Over WhatsApp").waitForExistence(timeout: 5), "sent")
    }

    /// A Telegram forum (demo `-CommsDemoForum YES`): ONE row with its topic count; the transcript
    /// opens on All Topics (each run labelled "# Topic"); the header pill switches to one topic;
    /// the composer replies in the topic of the newest message, then in the chosen one.
    func testForumTopicsSwitchAndReply() {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", "light", "-CommsDemoForum", "YES"]
        app.launch()
        let row = element(labelBeginsWith: "Trailhead Collective,")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the forum is one row")
        XCTAssertTrue(row.label.contains("forum, 3 topics"), row.label)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Trailhead Collective,'")).count, 1)
        snap("forum-row")
        row.tap()
        let pill = app.buttons["topic-switcher"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the topic switcher under the header")
        XCTAssertEqual(pill.label, "All Topics")
        XCTAssertTrue(element(labelBeginsWith: "Eli Brooks in Gear:").waitForExistence(timeout: 5), "All Topics labels each message with its topic")
        XCTAssertTrue(element(labelBeginsWith: "Maya Chen in Rides:").exists)
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.placeholderValue, "Reply in #Gear", "the newest message's topic")
        // Fix round 1 (C-1): All Topics shows where Send posts, and the chip changes it.
        let chip = app.buttons["compose-topic"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the To #… chip above the composer")
        XCTAssertEqual(chip.label, "Sending to Gear")
        snap("forum-all-topics")
        chip.tap()
        let toGeneral = app.buttons.matching(NSPredicate(format: "identifier == 'compose-topic-tp_general'")).firstMatch
        XCTAssertTrue(toGeneral.waitForExistence(timeout: 5), "the topics to send to")
        toGeneral.tap()
        XCTAssertTrue(app.buttons["Sending to General"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.placeholderValue, "Reply in #General")
        focus(field)
        field.typeText("Hello General")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(element(labelBeginsWith: "You in General:").waitForExistence(timeout: 5), "sent, labelled with the chosen topic")
        snap("forum-sent-to-chosen-topic")

        pill.tap()
        let rides = app.buttons.matching(NSPredicate(format: "identifier == 'topic-tp_rides'")).firstMatch
        XCTAssertTrue(rides.waitForExistence(timeout: 5), "the topics menu")
        XCTAssertTrue(rides.label.contains("1 unread message"), rides.label)
        snap("forum-topic-menu")
        rides.tap()
        XCTAssertTrue(app.buttons["topic-switcher"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["topic-switcher"].label.hasPrefix("Topic Rides"), app.buttons["topic-switcher"].label)
        XCTAssertTrue(element(labelBeginsWith: "Maya Chen:").waitForExistence(timeout: 5), "one topic: no labels")
        XCTAssertFalse(element(labelBeginsWith: "Ivy Moreno").exists, "another topic's messages are not shown")
        XCTAssertEqual(field.placeholderValue, "Reply in #Rides")
        focus(field)
        field.typeText("Count me in")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(element(labelContains: "Count me in").waitForExistence(timeout: 5), "sent into Rides")
        snap("forum-topic-rides")

        // Back to All Topics: the sent message carries its topic label.
        app.buttons["topic-switcher"].tap()
        let all = app.buttons.matching(NSPredicate(format: "identifier == 'topic-all'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertTrue(element(labelBeginsWith: "Eli Brooks in Gear:").waitForExistence(timeout: 5))
    }

    /// @ in a WhatsApp group lists its members; picking one puts the name in the draft.
    func testMentionSuggestionsInAGroup() {
        launch()
        let climbers = element(labelBeginsWith: "Weekend Climbers,")
        XCTAssertTrue(climbers.waitForExistence(timeout: 15))
        climbers.tap()
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Lunch @No")
        let noor = app.buttons["Mention Noor Haddad"]
        XCTAssertTrue(noor.waitForExistence(timeout: 3), "the member suggestion")
        snap("mention-suggestions")
        noor.tap()
        XCTAssertEqual(field.value as? String, "Lunch Noor Haddad ")
        field.typeText("today?")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(element(labelContains: "Lunch Noor Haddad today?").waitForExistence(timeout: 5), "sent with the mention")
        snap("mention-sent")
    }

    /// A ~20 000 px message (Jonah, demo polish): drawn to its end and from its start (layers
    /// beyond ~16 384 px would come out blank without the stacked-text split).
    func testVeryLongMessageRendersTopToBottom() throws {
        launchPolish()
        let jonah = element(labelBeginsWith: "Jonah Reyes,")
        XCTAssertTrue(jonah.waitForExistence(timeout: 15))
        jonah.tap()
        let long = element(labelContains: "The end.")
        XCTAssertTrue(long.waitForExistence(timeout: 10), "the long message")
        let scale = UIScreen.main.scale
        XCTAssertGreaterThan(long.frame.height * scale, 16_384, "taller than one layer could be")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(try textPixels(in: long.frame), 300, "the end of the message is drawn")
        snap("long-message-end")
        // Up through the middle to the top: text everywhere.
        for i in 0..<14 {
            app.swipeDown(velocity: .fast)
            if i % 4 == 3 {
                Thread.sleep(forTimeInterval: 0.6)
                XCTAssertGreaterThan(try textPixels(in: long.frame), 300, "drawn after \(i + 1) swipes")
            }
        }
        snap("long-message-middle")
    }

    /// Dark (text) pixels inside the visible part of `frame` (an incoming gray bubble).
    private func textPixels(in frame: CGRect) throws -> Int {
        let shot = XCUIScreen.main.screenshot().image
        let cg = try XCTUnwrap(shot.cgImage)
        let scale = CGFloat(cg.width) / shot.size.width
        let screen = CGRect(origin: .zero, size: shot.size)
        // The middle band of the screen, clear of the bars.
        let visible = frame.intersection(screen).intersection(CGRect(x: 0, y: screen.height * 0.25, width: screen.width, height: screen.height * 0.45))
        guard !visible.isEmpty else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for y in stride(from: Int(visible.minY * scale), to: Int(visible.maxY * scale), by: 2) {
            for x in stride(from: Int(visible.minX * scale), to: Int(visible.maxX * scale), by: 2) {
                let i = (y * w + x) * 4
                if data[i] < 80 && data[i + 1] < 80 && data[i + 2] < 80 { n += 1 }
            }
        }
        return n
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The Phase 1 flow on iPhone (stack) and iPad (split view): list → transcript → older
    /// history → a live message → Details → back.
    func testListThenThread() {
        launch()
        let alice = element(labelBeginsWith: "Alice Example,")
        XCTAssertTrue(alice.waitForExistence(timeout: 15), "the demo conversation list")
        XCTAssertTrue(element(labelBeginsWith: "Trail Crew,").exists)
        XCTAssertTrue(element(labelBeginsWith: "bob,").exists)
        XCTAssertTrue(app.descendants(matching: .any)["preview-badge"].exists, "labelled as a demo")
        XCTAssertFalse(element(labelBeginsWith: "Title ").exists, "no placeholder titles")
        XCTAssertTrue(app.buttons["list-edit"].exists, "Edit")
        XCTAssertTrue(app.buttons["list-compose"].exists, "Compose")
        snap(isPad ? "pad-01-list" : "01-list")

        alice.tap()
        // Alice's newest message is a 64 000-character text, shown in full (owner ruling).
        let transcript = app.collectionViews["transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "the UIKit transcript")
        XCTAssertTrue(element(labelContains: "lorem ipsum").waitForExistence(timeout: 10), "the transcript, at the bottom")
        XCTAssertFalse(app.buttons["Show more"].exists, "no Show more clamp")
        snap(isPad ? "pad-02-transcript-alice" : "02-transcript-alice")

        // The transcript is not part of the name-pill button in the accessibility tree.
        let pill = app.buttons["transcript-name-pill"].firstMatch
        XCTAssertTrue(pill.exists, "the name pill")
        XCTAssertEqual(pill.descendants(matching: .any).matching(identifier: "transcript").count, 0)
        XCTAssertTrue(app.buttons["composer-plus"].exists)

        if !isPad {
            // Messages' back button carries the other conversations' unread count.
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.exists, "the system back button")
            XCTAssertTrue(back.label.range(of: "[0-9]", options: .regularExpression) != nil, "unread count on the back button: \(back.label)")
        }

        // Details (sheet on iPhone, inspector on iPad), then a live message through the
        // DEBUG demo injector at the top of Details.
        pill.tap()
        XCTAssertTrue(app.descendants(matching: .any)["details-title"].waitForExistence(timeout: 5), "Details")
        XCTAssertTrue(app.staticTexts["details-title"].label.hasPrefix("Alice Example"))
        snap(isPad ? "pad-03-details" : "03-details")

        // The photo viewer from Details opens over the sheet (not under it on the transcript).
        app.segmentedControls["details-tabs"].buttons["Photos"].tap()
        let photo = app.buttons.matching(NSPredicate(format: "label == 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "a photo in Details")
        photo.tap()
        let viewerClose = app.buttons["media-viewer-close"]
        XCTAssertTrue(viewerClose.waitForExistence(timeout: 10), "the photo viewer is presented over Details")
        XCTAssertTrue(viewerClose.isHittable, "on top, reachable")
        snap(isPad ? "pad-03b-photo-viewer" : "03b-photo-viewer")
        viewerClose.tap()
        XCTAssertTrue(viewerClose.waitForNonExistence(timeout: 5), "the viewer closed")
        XCTAssertTrue(app.staticTexts["details-title"].waitForExistence(timeout: 5), "back on Details")
        app.segmentedControls["details-tabs"].buttons["Info"].tap()

        let demo = app.buttons["demo-menu"].firstMatch
        if !demo.isHittable { app.swipeUp() }
        demo.tap()
        app.buttons["Inject Message"].firstMatch.tap()
        let close = app.buttons["details-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3), "Details' close button")
        Thread.sleep(forTimeInterval: 0.6) // the menu closes first
        close.tap()
        let title = app.staticTexts["details-title"].firstMatch
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Details closed")
        XCTAssertTrue(element(labelContains: "Live message 1").waitForExistence(timeout: 5), "the injected message appears")
        XCTAssertTrue(onScreen(element(labelContains: "Live message 1")), "at the bottom, on screen")
        snap(isPad ? "pad-04-live-message" : "04-live-message")

        // Scroll up: formatted text and the edited message, then older history pages in.
        for _ in 0..<90 where !(onScreen(element(labelContains: "bold italic strike")) && onScreen(app.staticTexts["Edited"])) {
            transcript.swipeDown(velocity: onScreen(element(labelContains: "Check this out")) ? .default : .fast)
        }
        if !onScreen(element(labelContains: "bold italic strike")) { snap("debug-formatted") }
        XCTAssertTrue(onScreen(element(labelContains: "bold italic strike")), "formatted text, on screen")
        XCTAssertTrue(app.staticTexts["Edited"].exists, "the Edited note")
        for _ in 0..<20 where !onScreen(element(labelContains: "Older message")) {
            transcript.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(onScreen(element(labelContains: "Older message")), "older history loaded, on screen")
        snap(isPad ? "pad-05-older-history" : "05-older-history")

        // VoiceOver reads the flipped transcript top to bottom: its cells in accessibility
        // order are in on-screen order.
        let ys = transcript.cells.allElementsBoundByIndex.map(\.frame.minY)
        XCTAssertGreaterThan(ys.count, 3)
        XCTAssertEqual(ys, ys.sorted(), "accessibility order = visual order (oldest → newest)")

        if isPad {
            element(labelBeginsWith: "Trail Crew,").tap()
        } else {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(element(labelBeginsWith: "Trail Crew,").waitForExistence(timeout: 5), "back to the list")
            element(labelBeginsWith: "Trail Crew,").tap()
        }
        XCTAssertTrue(element(labelContains: "lorem ipsum").waitForExistence(timeout: 10), "the group's newest (long) message")
        snap(isPad ? "pad-06-transcript-group" : "06-transcript-group")

        // The keyboard lifts the transcript and an interactive drag down dismisses it.
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard up")
        let newest = element(labelContains: "lorem ipsum")
        XCTAssertTrue(newest.frame.maxY < app.keyboards.firstMatch.frame.minY, "the newest row rides above the keyboard")
        let start = app.collectionViews["transcript"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = start.withOffset(CGVector(dx: 0, dy: app.windows.firstMatch.frame.height * 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "dragging down dismisses the keyboard")
    }

    /// Owner report: "some are opening but its hard to swipe to close out of them." A photo
    /// opens full screen at once; a swipe down closes it (the picture follows the finger); a
    /// short drag springs back; the X closes too.
    func testPhotoOpensAndSwipesDownToClose() {
        launch()
        let climbers = element(labelBeginsWith: "Weekend Climbers,")
        XCTAssertTrue(climbers.waitForExistence(timeout: 15), "the demo list")
        climbers.tap()
        let bubble = app.collectionViews["transcript"].descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the photo bubble")
        bubble.tap()

        let image = app.images["media-viewer-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the viewer opens")
        XCTAssertTrue(waitForValue(image, "full"), "the full picture loads")
        XCTAssertFalse(app.staticTexts["media-viewer-error"].exists, "no error")
        snap("media-viewer-photo")

        // A short drag springs back.
        let mid = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: 40)), withVelocity: 120, thenHoldForDuration: 0.1)
        XCTAssertTrue(image.waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(image.exists, "a short drag does not close")

        // A swipe down closes it, back on the transcript.
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: 320)), withVelocity: 900, thenHoldForDuration: 0)
        XCTAssertTrue(image.waitForNonExistence(timeout: 5), "swipe down closes the viewer")
        XCTAssertTrue(app.buttons["composer-plus"].waitForExistence(timeout: 5), "back on the transcript")

        // The X closes it as well.
        bubble.tap()
        XCTAssertTrue(app.buttons["media-viewer-close"].waitForExistence(timeout: 10))
        app.buttons["media-viewer-close"].tap()
        XCTAssertTrue(image.waitForNonExistence(timeout: 5), "the X closes the viewer")
    }

    /// Owner report: "it won't open at all" — an iMessage HEIC photo (declared image/heic, HEIC
    /// bytes) opens and shows the full picture, not an error and not nothing.
    func testHEICPhotoOpens() {
        launch()
        let maya = element(labelBeginsWith: "Maya Okafor,")
        XCTAssertTrue(maya.waitForExistence(timeout: 15), "the demo list")
        maya.tap()
        let transcript = app.collectionViews["transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let bubble = transcript.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo'")).firstMatch
        for _ in 0..<5 where !bubble.exists { transcript.swipeDown() }
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the HEIC photo bubble")
        bubble.tap()
        let image = app.images["media-viewer-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the viewer opens")
        XCTAssertTrue(waitForValue(image, "full"), "the HEIC decodes and shows in full")
        XCTAssertFalse(app.staticTexts["media-viewer-error"].exists, "no error")
        snap("media-viewer-heic")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: 900, thenHoldForDuration: 0)
        XCTAssertTrue(image.waitForNonExistence(timeout: 5), "swipe down closes it")
    }

    private func waitForValue(_ e: XCUIElement, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let p = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout) == .completed
    }

    /// Phase 2a people: a DM's Details is a contact card listing every conversation shared
    /// with the person (opening one), the call menu is offered, and a group member opens
    /// their own card.
    func testDetailsShowsSharedConversationsAndMemberCards() {
        launch()
        let alice = element(labelBeginsWith: "Alice Example,")
        XCTAssertTrue(alice.waitForExistence(timeout: 15), "the demo conversation list")
        alice.tap()
        let call = app.descendants(matching: .any)["transcript-video"].firstMatch
        if !call.waitForExistence(timeout: 10) { print("AXDUMP", app.navigationBars.firstMatch.debugDescription) }
        XCTAssertTrue(call.exists, "the call menu (Alice has a phone)")
        app.buttons["transcript-name-pill"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["details-title"].firstMatch.waitForExistence(timeout: 5), "Details")
        XCTAssertTrue(app.buttons["details-call"].firstMatch.exists, "the call circle is a menu")
        let shared = app.buttons["shared-thread-th_demo_alice_tg"].firstMatch
        for _ in 0..<4 where !(shared.exists && shared.isHittable) { app.swipeUp() }
        XCTAssertTrue(shared.waitForExistence(timeout: 5), "Conversations lists her Telegram chat")
        XCTAssertTrue(app.buttons["shared-thread-th_stg1"].firstMatch.exists, "and the group she is in")
        snap(isPad ? "pad-07-details-conversations" : "07-details-conversations")
        shared.tap()
        XCTAssertTrue(element(labelContains: "trail map").waitForExistence(timeout: 10), "the shared conversation opened")
        XCTAssertTrue(app.staticTexts["details-title"].firstMatch.waitForNonExistence(timeout: 5), "Details went with the old conversation")

        // A group member Prism knows opens their own card, pushed inside Details.
        app.terminate()
        launch()
        let crew = element(labelBeginsWith: "Trail Crew,")
        XCTAssertTrue(crew.waitForExistence(timeout: 15))
        crew.tap()
        let pill = app.buttons["transcript-name-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        let member = app.buttons["member-0"].firstMatch
        for _ in 0..<4 where !(member.exists && member.isHittable) { app.swipeUp() }
        XCTAssertTrue(member.waitForExistence(timeout: 5), "Alice in the members list")
        member.tap()
        XCTAssertTrue(app.staticTexts["person-card-title"].firstMatch.waitForExistence(timeout: 5), "her card")
        XCTAssertTrue(app.buttons["shared-thread-th_stg2"].firstMatch.waitForExistence(timeout: 5), "with her conversations")
        snap(isPad ? "pad-08-member-card" : "08-member-card")
    }

    /// Live: opens the real sign-in sheet against the production server and cancels it (no
    /// device is minted: that needs the owner's login). Opt-in, it touches the network:
    /// TEST_RUNNER_COMMS_LIVE_SIGNIN=1.
    func testSignInOpensTheWebSheetAndCancels() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMMS_LIVE_SIGNIN"] == "1", "opt-in")
        app = XCUIApplication()
        app.launchArguments = ["-CommsAppearance", "light"]
        app.launch()
        let button = app.buttons["sign-in-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the sign-in screen")
        XCTAssertTrue(app.textFields["sign-in-server"].value as? String == "https://prism.example.com")
        snap("00-sign-in")
        button.tap()
        // "“Comms” Wants to Use “example.com” to Sign In"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let proceed = springboard.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), "the system's sign-in consent")
        proceed.tap()
        let web = app.webViews.firstMatch
        let anyWeb = web.waitForExistence(timeout: 15) || springboard.webViews.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(anyWeb, "the Prism login page in the sheet")
        snap("00b-sign-in-sheet")
        let cancel = app.buttons["Cancel"].exists ? app.buttons["Cancel"] : springboard.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(button.waitForExistence(timeout: 10), "back on sign-in after cancelling")
        XCTAssertFalse(app.staticTexts["sign-in-message"].exists && app.staticTexts["sign-in-message"].label.contains("failed"), "a cancel is not an error")
    }

    /// Built AND visible below the floating header (lazy rows exist before they scroll in).
    private func onScreen(_ e: XCUIElement) -> Bool {
        guard e.exists else { return false }
        let screen = app.windows.firstMatch.frame
        let visible = CGRect(x: screen.minX, y: screen.minY + 140, width: screen.width, height: screen.height - 210)
        return visible.contains(CGPoint(x: e.frame.midX, y: e.frame.midY))
    }

    /// Phase 2b C3: Compose → New Message sheet → type a name in To: → pick her existing
    /// conversation → it opens (nothing is sent).
    func testComposePickExistingConversationOpensIt() {
        launch()
        XCTAssertTrue(element(labelBeginsWith: "Alice Example,").waitForExistence(timeout: 15), "the demo conversation list")
        app.buttons["list-compose"].firstMatch.tap()
        let to = app.textFields["compose-to"].firstMatch
        XCTAssertTrue(to.waitForExistence(timeout: 5), "the To: field")
        XCTAssertTrue(app.navigationBars["New Message"].exists, "titled New Message")
        to.tap()
        to.typeText("Alice")
        let thread = app.buttons["compose-thread-th_stg2"].firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5), "her existing conversation is suggested")
        XCTAssertTrue(app.buttons["compose-person-+15550001"].firstMatch.exists, "and her phone number")
        thread.tap()
        XCTAssertTrue(to.waitForNonExistence(timeout: 5), "the sheet closed")
        XCTAssertTrue(element(labelContains: "lorem ipsum").waitForExistence(timeout: 10), "Alice's conversation opened")
    }

    /// Phase 2b C3: Cancel closes the sheet without doing anything.
    func testComposeCancel() {
        launch()
        XCTAssertTrue(element(labelBeginsWith: "Alice Example,").waitForExistence(timeout: 15))
        app.buttons["list-compose"].firstMatch.tap()
        XCTAssertTrue(app.textFields["compose-to"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["compose-cancel"].firstMatch.tap()
        XCTAssertTrue(app.textFields["compose-to"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(labelBeginsWith: "Alice Example,").exists, "back on the list")
    }

    /// Phase 2b C4: typing in Search narrows the list at once (local matches before the
    /// server's debounced answer), and clearing it brings the list back.
    func testSearchNarrowsInstantly() {
        launch()
        let alice = element(labelBeginsWith: "Alice Example,")
        XCTAssertTrue(alice.waitForExistence(timeout: 15))
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) { app.buttons["Search"].firstMatch.tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the Search field")
        search.tap()
        let start = Date()
        search.typeText("Trail")
        let crew = element(labelBeginsWith: "Trail Crew,")
        XCTAssertTrue(crew.waitForExistence(timeout: 2), "the match shows while typing")
        // Others leave the list (Alice's "trail map" MESSAGE may show as a message result:
        // full search, Task 4 — so check her list row, not any element labelled with her name).
        XCTAssertTrue(app.descendants(matching: .any)["thread-row-th_stg2"].firstMatch.waitForNonExistence(timeout: 2), "others leave the list")
        let elapsed = Date().timeIntervalSince(start)
        print("[search-ui] typed 5 characters and the list narrowed in \(String(format: "%.2f", elapsed)) s")
        XCTAssertLessThan(elapsed, 4, "responsive (typing itself takes most of this)")
        // The server's answer (after the pause) keeps the row; nothing flickers away.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(crew.exists, "still there after the server answered")
        search.buttons.firstMatch.tap() // clear
        XCTAssertTrue(alice.waitForExistence(timeout: 5), "the list is back")
    }

    /// Sprint Task 1: Mark as Read / Mark as Unread from the row's context menu (touch and
    /// hold) and the leading swipe; the row's VoiceOver label carries the unread count. Then
    /// Edit › Notifications opens Settings › Notifications. Demo backend: nothing leaves the
    /// simulator.
    func testMarkReadAndUnreadAndNotificationSettings() {
        launch()
        let theo = app.descendants(matching: .any)["thread-row-th_demo_theo"]
        XCTAssertTrue(theo.waitForExistence(timeout: 15), "the demo list")
        XCTAssertTrue(theo.label.contains("1 unread message"), "Theo starts unread: \(theo.label)")

        theo.press(forDuration: 1.0)
        let markRead = app.buttons["Mark as Read"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5), "the context menu offers Mark as Read")
        snap("read-context-menu")
        markRead.tap()
        XCTAssertTrue(waitFor(theo) { !$0.label.contains("unread") }, "read: \(theo.label)")

        theo.press(forDuration: 1.0)
        let markUnread = app.buttons["Mark as Unread"]
        XCTAssertTrue(markUnread.waitForExistence(timeout: 5), "and now Mark as Unread")
        markUnread.tap()
        XCTAssertTrue(waitFor(theo) { $0.label.contains("1 unread message") }, "unread again: \(theo.label)")

        // Messages' leading swipe: Read.
        theo.swipeRight()
        let swipeRead = app.buttons["swipe-read-th_demo_theo"]
        if swipeRead.waitForExistence(timeout: 2) { swipeRead.tap() }
        XCTAssertTrue(waitFor(theo) { !$0.label.contains("unread") }, "swiped read: \(theo.label)")
        snap("read-after-swipe")

        // Opening a conversation reads it.
        theo.press(forDuration: 1.0)
        app.buttons["Mark as Unread"].tap()
        XCTAssertTrue(waitFor(theo) { $0.label.contains("unread") })
        theo.tap()
        XCTAssertTrue(app.buttons["composer-plus"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(theo) { !$0.label.contains("unread") }, "opened = read: \(theo.label)")

        app.buttons["list-edit"].tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        let settings = menuItem("notification-settings", "Notifications")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let previews = app.switches["notify-show-previews"]
        XCTAssertTrue(app.switches["notify-allow"].waitForExistence(timeout: 5), "Settings › Notifications")
        snap("notification-settings")
        // Settings › Notifications grew (folder rules): scroll until the switch is on screen.
        for _ in 0..<4 where !(previews.exists && previews.isHittable) { app.swipeUp() }
        XCTAssertTrue(previews.waitForExistence(timeout: 3), "Show Previews")
        XCTAssertEqual(previews.value as? String, "1", "previews shown by default")
        // The switch itself sits at the row's trailing edge.
        previews.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(previews) { ($0.value as? String) == "0" }, "hide previews")
        app.buttons["notify-done"].tap()
        XCTAssertTrue(theo.waitForExistence(timeout: 5))
    }

    private func waitFor(_ e: XCUIElement, timeout: TimeInterval = 5, _ check: (XCUIElement) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if e.exists, check(e) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return e.exists && check(e)
    }

    /// Sprint Task 8: Pin from the row's long-press menu → the conversation moves into the
    /// pinned grid; Unpin from the tile's menu → back to the rows; a leading swipe pins again.
    /// Demo backend (the fixture keeps the pins like the server: order, at most nine).
    func testPinAndUnpin() {
        launch()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread-row-' AND label BEGINSWITH 'Jamie Abbott,'")).firstMatch
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread-tile-' AND label BEGINSWITH 'Jamie Abbott,'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the demo list")
        XCTAssertFalse(tile.exists)

        row.press(forDuration: 1.2)
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "Pin in the row's menu")
        pin.tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "pinned: a tile in the grid")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "and no longer a row")
        snap("pinned-jamie")

        tile.press(forDuration: 1.2)
        let unpin = app.buttons["Unpin"].firstMatch
        XCTAssertTrue(unpin.waitForExistence(timeout: 5), "Unpin in the tile's menu")
        unpin.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "unpinned: a row again")
        XCTAssertTrue(tile.waitForNonExistence(timeout: 5))

        // Messages' leading swipe: Read / Unread at the outer edge (the full-swipe action, sprint
        // integration), Pin beside it — a short drag (less than both buttons, so no full swipe) opens
        // them, then tap Pin. (The pan begins only on a clearly sideways velocity, so not .slow.)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 110, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0.1)
        let swipePin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swipe-pin-'")).firstMatch
        XCTAssertTrue(swipePin.waitForExistence(timeout: 5), "the leading swipe shows Pin")
        swipePin.tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the leading swipe pinned it")
    }

    /// Sprint Task 9 / polish r2: the trailing swipe on a row (Messages' circles) — Mute, Status
    /// (the statuses, with Undo) and Archive (with Undo); a touch on another row closes it; a
    /// full swipe archives at once.
    func testRowSwipeMuteStatusArchive() {
        launch()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread-row-' AND label BEGINSWITH 'Theo Marsh,'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the demo list")
        XCTAssertTrue(app.navigationBars["Comms"].exists, "the home page is titled Comms")
        XCTAssertFalse(row.label.contains("muted"))

        func swipeOpen() {
            // Less than the three buttons (222 pt): opens them, no full swipe.
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -170, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0.1)
        }

        swipeOpen()
        let mute = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swipe-mute-'")).firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "the trailing swipe shows Mute")
        snap("row-swipe-trailing")
        mute.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread-row-' AND label BEGINSWITH 'Theo Marsh,' AND label CONTAINS 'muted'")).firstMatch.waitForExistence(timeout: 5), "muted (bell-slash)")

        swipeOpen()
        let status = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swipe-status-'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "Status in the trailing swipe")
        status.tap()
        // The Status sheet (Theo is Urgent in the demo: checked).
        XCTAssertTrue(app.buttons["Urgent ✓"].firstMatch.waitForExistence(timeout: 5), "the triage statuses, the current one checked")
        let handled = app.buttons["status-handled"].firstMatch
        XCTAssertTrue(handled.exists)
        snap("row-swipe-status-sheet")
        handled.tap()
        let undo = app.buttons["undo-button"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo after a status change")
        XCTAssertTrue(element(labelContains: "Handled").exists)
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))

        swipeOpen()
        let archive = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swipe-archive-'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5), "Archive at the outer edge")
        archive.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "archived: gone from Comms")
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo after Archive")
        snap("row-archived-undo")
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back after Undo")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 8))

        // Polish r2: touching another row only closes the open swipe (no navigation).
        swipeOpen()
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "open again")
        let other = element(labelBeginsWith: "Jamie Abbott,")
        XCTAssertTrue(other.exists)
        other.tap()
        XCTAssertTrue(mute.waitForNonExistence(timeout: 3), "touching another row closes the swipe")
        XCTAssertTrue(app.navigationBars["Comms"].exists, "…and does not open it")

        // Full swipe (unchanged): far past the buttons archives at once, with Undo.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -340, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "full swipe: archived")
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo after the full swipe")
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back after Undo")
    }

    /// Sprint Task 9 / polish r2 (owner redirect): create a folder, add a chat to it (row menu)
    /// and another (Select), then choose it from the top-left menu — the only way to change page:
    /// no strip, and a swipe from the screen edge no longer pages.
    func testFolderCreateAddAndPage() {
        launch()
        let theo = element(labelBeginsWith: "Theo Marsh,")
        XCTAssertTrue(theo.waitForExistence(timeout: 15), "the demo list")
        XCTAssertFalse(app.descendants(matching: .any)["folder-strip"].exists, "no folder strip")
        app.buttons["list-edit"].tap()
        let newFolder = menuItem("new-folder", "New Folder…")
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5), "menu › New Folder…")
        newFolder.tap()
        // The alert's text field carries no identifier through SwiftUI.
        let name = app.alerts["New Folder"].textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the name prompt")
        focus(name)
        name.typeText("Work")
        app.buttons["new-folder-save"].firstMatch.tap()

        // The row's menu: Add to Folder › Work.
        theo.press(forDuration: 1.2)
        let add = app.buttons["Add to Folder"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add to Folder in the row's menu")
        add.tap()
        let work = app.buttons.matching(NSPredicate(format: "label == 'Work' AND identifier != 'folder-page-Work'")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()

        // Select another and add it.
        app.buttons["list-edit"].tap()
        let select = menuItem("select-conversations", "Select Conversations")
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let jamie = element(labelBeginsWith: "Jamie Abbott,")
        XCTAssertTrue(jamie.waitForExistence(timeout: 5))
        jamie.tap()
        let addSelected = app.buttons["selection-add-to-folder"]
        XCTAssertTrue(addSelected.waitForExistence(timeout: 5), "the selection toolbar")
        snap("folder-select")
        addSelected.tap()
        let workItem = app.buttons.matching(NSPredicate(format: "label == 'Work' AND identifier != 'folder-page-Work'")).firstMatch
        XCTAssertTrue(workItem.waitForExistence(timeout: 5))
        workItem.tap()

        // The top-left menu: Comms, Work, … — choose Work.
        app.buttons["list-edit"].tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5), "the folder menu")
        let workPage = menuItem("folder-page-Work", "Work")
        XCTAssertTrue(workPage.waitForExistence(timeout: 5), "Work in the folder menu")
        XCTAssertTrue(menuItem("folder-page-Comms", "Comms").exists, "Comms (all) in the folder menu")
        snap("folder-menu")
        workPage.tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 5), "the folder page is titled Work")
        XCTAssertTrue(element(labelBeginsWith: "Theo Marsh,").waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelBeginsWith: "Jamie Abbott,").exists)
        XCTAssertFalse(element(labelBeginsWith: "Northwind Billing,").exists, "not in Work")
        snap("folder-page-work")

        // A swipe from the screen edge no longer pages.
        let window = app.windows.firstMatch
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 180, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 2), "still Work: no paging swipes")

        // Back to Comms from the menu.
        app.buttons["list-edit"].tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        menuItem("folder-page-Comms", "Comms").tap()
        XCTAssertTrue(app.navigationBars["Comms"].waitForExistence(timeout: 5), "back to Comms")
        XCTAssertTrue(element(labelBeginsWith: "Northwind Billing,").waitForExistence(timeout: 5))
    }

    /// Email (PRD §5.8): the list row's subject line, email bubbles, the composer's To/Cc/Subject
    /// header, "View Full Email" in a sheet, and a reply that goes out (the demo answers it).
    func testEmailThreadReadAndReply() {
        launch()
        let row = element(labelBeginsWith: "Northwind Billing,")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the email conversation, titled by the sender")
        XCTAssertTrue(row.label.contains("Your November invoice"), "the subject in the row: \(row.label)")
        if !onScreen(row) { app.swipeUp() }
        row.tap()
        let bubble = element(labelContains: "email: Your November invoice")
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "an email bubble with its subject")
        XCTAssertTrue(element(labelContains: "email: Re: October receipt").exists, "the older email too")
        XCTAssertTrue(app.descendants(matching: .any)["email-header-to"].waitForExistence(timeout: 5), "the composer's To: row")
        XCTAssertTrue(app.descendants(matching: .any)["email-header-to"].label.contains("billing@northwind.example.test"))
        XCTAssertTrue(app.descendants(matching: .any)["email-header-subject"].label.contains("Re: Your November invoice"))
        // Mail's default is Reply: the sender only. Reply All is an explicit choice and adds the Cc.
        XCTAssertFalse(app.descendants(matching: .any)["email-header-cc"].exists, "Reply: no Cc")
        let mode = app.buttons["email-mode"].firstMatch
        XCTAssertTrue(mode.exists, "the Reply / Reply All menu")
        XCTAssertEqual(mode.label, "Reply")
        mode.tap()
        let all = app.buttons["Reply All"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), "Reply All in the menu")
        all.tap()
        let cc = app.descendants(matching: .any)["email-header-cc"]
        XCTAssertTrue(cc.waitForExistence(timeout: 5), "Reply All shows the Cc")
        XCTAssertTrue(cc.label.contains("finance@northwind.example.test"), cc.label)
        snap(isPad ? "pad-email-01-thread" : "email-01-thread")

        // "View Full Email": the bubble's last line (inside the combined element: tap where it is).
        bubble.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 40, dy: -16)).tap()
        let sheet = app.descendants(matching: .any)["email-original"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the full email sheet")
        XCTAssertTrue(app.descendants(matching: .any)["email-original-html"].waitForExistence(timeout: 5), "the sandboxed HTML view")
        let rendered = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Invoice #1124")).firstMatch
        XCTAssertTrue(rendered.waitForExistence(timeout: 10), "the mail's HTML is drawn (not a blank sheet)")
        snap(isPad ? "pad-email-02-full" : "email-02-full")
        app.buttons["email-original-done"].firstMatch.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))

        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"].firstMatch : app.textFields["composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer")
        field.tap()
        field.typeText("Thanks, paid today.")
        app.buttons["composer-send"].firstMatch.tap()
        XCTAssertTrue(element(labelContains: "email: Re: Your November invoice. Thanks, paid today.").waitForExistence(timeout: 10), "the reply shows as an email bubble")
        XCTAssertTrue(app.descendants(matching: .any)["email-header-to"].waitForExistence(timeout: 5), "still answerable after the reply")
        XCTAssertFalse(app.buttons["composer-record"].exists, "no audio on email")
                snap(isPad ? "pad-email-03-replied" : "email-03-replied")
    }

    /// Task 4: full search finds a message inside a conversation (a bubble with the words
    /// highlighted), opens it; "Who is this?" in Details ignores and undoes; People to Tidy
    /// opens from the Filter menu.
    func testFullSearchAndContactTidy() {
        launch()
        let alice = element(labelBeginsWith: "Alice Example,")
        XCTAssertTrue(alice.waitForExistence(timeout: 15))
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) { app.buttons["Search"].firstMatch.tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("trail map")
        let hit = app.descendants(matching: .any)["search-hit-0"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "a message result")
        XCTAssertTrue(hit.label.localizedCaseInsensitiveContains("trail map"), hit.label)
        snap(isPad ? "pad-09-search-results" : "09-search-results")
        hit.tap()
        XCTAssertTrue(app.buttons["transcript-name-pill"].firstMatch.waitForExistence(timeout: 10), "the conversation opened")
        app.terminate()

        // "Who is this?" for a DM that is no person yet.
        launch()
        let jonah = element(labelBeginsWith: "Jonah Reyes,")
        XCTAssertTrue(jonah.waitForExistence(timeout: 15))
        jonah.tap()
        let pill = app.buttons["transcript-name-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(pill.label.contains("not in your people yet"), pill.label)
        pill.tap()
        let ignore = app.buttons["tidy-ignore"].firstMatch
        XCTAssertTrue(ignore.waitForExistence(timeout: 5), "Who is this? offers Ignore")
        XCTAssertTrue(app.buttons["tidy-create"].firstMatch.exists, "and Create New Contact")
        snap(isPad ? "pad-10-who-is-this" : "10-who-is-this")
        ignore.tap()
        let undo = app.buttons["tidy-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo after the choice")
        undo.tap()
        XCTAssertTrue(app.buttons["tidy-ignore"].firstMatch.waitForExistence(timeout: 5), "the prompt is back after Undo")
        // Link to an existing person found by name (review I5).
        app.buttons["tidy-link-existing"].firstMatch.tap()
        let peopleSearch = app.searchFields["Search People"].firstMatch
        XCTAssertTrue(peopleSearch.waitForExistence(timeout: 5), "the people picker")
        peopleSearch.tap()
        peopleSearch.typeText("Priya")
        let priya = app.buttons["tidy-pick-p_demo_priya"].firstMatch
        XCTAssertTrue(priya.waitForExistence(timeout: 5), "Priya is found by name")
        snap(isPad ? "pad-12-link-person" : "12-link-person")
        priya.tap()
        XCTAssertTrue(app.buttons["tidy-undo"].firstMatch.waitForExistence(timeout: 5), "linked, with Undo")
        app.buttons["tidy-undo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tidy-ignore"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["details-close"].firstMatch.tap()
        app.terminate()

        // People to Tidy from the folder menu (round 3: not in the list or the Filter menu).
        launch()
        XCTAssertTrue(element(labelBeginsWith: "Alice Example,").waitForExistence(timeout: 15))
        XCTAssertFalse(element(labelBeginsWith: "People to Tidy").exists, "no Tidy row in the list")
        app.buttons["list-edit"].tap()
        // A system menu item: found by its title ("People to Tidy (4)").
        let tidy = element(labelBeginsWith: "People to Tidy")
        if !tidy.waitForExistence(timeout: 5) { print("AXDUMP", app.debugDescription) }
        XCTAssertTrue(tidy.exists, "People to Tidy in the folder menu")
        tidy.tap()
        XCTAssertTrue(app.descendants(matching: .any)["people-to-tidy-list"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tidy-menu-th_demo_jonah"].firstMatch.waitForExistence(timeout: 5), "Jonah is listed")
        snap(isPad ? "pad-11-people-to-tidy" : "11-people-to-tidy")
    }

    /// Omni in Comms over the fixture (`-CommsDemoOmni YES`). Polish r2: Needs You is a page of
    /// the top-left menu; its rows open — the waiting reply draft opens the review sheet (Show
    /// Conversation goes to it), a non-Comms proposal opens read-only with "Approve in Omni".
    /// Approving sends exactly that text (the demo answers Face ID). `@Omni` + the keyboard's Send
    /// key drafts privately (never a chat message); Discard removes it; the + menu's Omni row
    /// turns the field into "Ask Omni…". Nothing leaves the simulator.
    func testOmniDraftFlow() {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", "light", "-CommsDemoOmni", "YES"]
        app.launch()

        XCTAssertTrue(element(labelBeginsWith: "Theo Marsh,").waitForExistence(timeout: 15), "the demo list")
        app.buttons["list-edit"].tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        let needsPage = menuItem("folder-page-needs-you", "Needs You")
        XCTAssertTrue(needsPage.waitForExistence(timeout: 5), "Needs You in the folder menu")
        XCTAssertTrue(needsPage.label.contains("Needs You (2)"), needsPage.label)
        needsPage.tap()
        XCTAssertTrue(app.navigationBars["Needs You"].waitForExistence(timeout: 5), "the Needs You page")
        let rows = app.buttons.matching(identifier: "needs-you-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2, "the reply draft and the calendar proposal")
        snap("omni-needs-you")

        // The non-Comms proposal opens read-only, with Approve in Omni.
        let invite = app.buttons.matching(NSPredicate(format: "identifier == 'needs-you-row' AND label CONTAINS 'Grant call'")).firstMatch
        XCTAssertTrue(invite.exists, "the calendar proposal row")
        invite.tap()
        XCTAssertTrue(app.buttons["proposal-approve-in-omni"].waitForExistence(timeout: 5), "read-only, Approve in Omni")
        XCTAssertTrue(element(labelContains: "Grant call").exists)
        snap("omni-proposal-readonly")
        app.buttons["proposal-done"].tap()
        XCTAssertTrue(app.buttons["proposal-approve-in-omni"].waitForNonExistence(timeout: 5))

        // The reply draft opens the review sheet.
        let draftRow = app.buttons.matching(NSPredicate(format: "identifier == 'needs-you-row' AND label CONTAINS 'Thursday'")).firstMatch
        XCTAssertTrue(draftRow.exists, "the reply draft row")
        draftRow.tap()
        XCTAssertTrue(app.buttons["draft-approve"].waitForExistence(timeout: 5), "the draft review sheet")
        snap("omni-needs-you-review")
        app.buttons["needs-you-show-conversation"].tap()

        let draft = app.descendants(matching: .any)["omni-draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10), "the dashed draft bubble in Alice's conversation")
        XCTAssertTrue(draft.label.contains("Thursday at 3 works for me"), draft.label)
        XCTAssertFalse(app.buttons["draft-approve"].exists, "no Approve & Send inline (review round 2)")
        XCTAssertTrue(app.buttons["draft-edit"].exists && app.buttons["draft-refine"].exists && app.buttons["draft-discard"].exists)
        snap("omni-draft")
        app.buttons["draft-review"].tap()
        let approve = app.buttons["draft-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "the review sheet")
        XCTAssertTrue(approve.isEnabled, "a short draft fits the sheet: every line is on screen")
        // Round 3: Omni's identity and the recipient in the header, the network chip, Edit / Refine….
        let title = app.descendants(matching: .any)["draft-review-title"].firstMatch
        XCTAssertTrue(title.exists && title.label.contains("Omni's draft for Alice"), title.label)
        XCTAssertTrue(app.descendants(matching: .any)["draft-review-network"].firstMatch.exists, "the network chip")
        XCTAssertTrue(app.buttons["draft-review-edit"].exists && app.buttons["draft-review-refine"].exists)
        XCTAssertTrue(app.buttons["draft-review-cancel"].exists, "the close (×)")
        snap("omni-review")
        approve.tap()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 5), "approved: the draft goes")
        XCTAssertTrue(element(labelContains: "Thanks Alice — Thursday at 3 works for me").waitForExistence(timeout: 5), "sent as the owner's message")

        // @Omni + the keyboard's Send key: a private instruction (polish r2), never a message.
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        focus(field)
        field.typeText("@Omni tell her I'm running late")
        let ask = app.buttons["composer-omni-send"]
        XCTAssertTrue(ask.waitForExistence(timeout: 3), "the ✦ send button")
        XCTAssertFalse(app.buttons["composer-send"].exists, "no message send arrow while addressing Omni")
        snap("omni-composer-at")
        field.typeText("\n")
        XCTAssertTrue(app.buttons["draft-review"].waitForExistence(timeout: 8), "Send asked Omni: its new draft")
        XCTAssertFalse(element(labelContains: "tell her I'm running late").exists, "the instruction is not a message")
        XCTAssertFalse(ask.exists, "the field is empty again")
        snap("omni-draft-new")
        app.buttons["draft-discard"].tap()
        XCTAssertTrue(app.buttons["draft-review"].waitForNonExistence(timeout: 5), "discarded")

        // + → Omni: the field becomes Omni's ("Ask Omni…") until the token is tapped.
        app.buttons["composer-plus"].tap()
        let omniRow = app.buttons["Omni"]
        XCTAssertTrue(omniRow.waitForExistence(timeout: 3), "+ menu: Omni")
        omniRow.tap()
        XCTAssertTrue(app.buttons["composer-omni-token"].waitForExistence(timeout: 3), "Omni mode")
        snap("omni-composer-mode")
        app.buttons["composer-omni-token"].tap()
        XCTAssertTrue(app.buttons["composer-omni-token"].waitForNonExistence(timeout: 3), "back to messages")
    }

    /// Review C1 / round 2 (N1): a long draft at an accessibility text size, keyboard up. No Approve
    /// & Send inline; in the review sheet it stays disabled until every line has been on screen,
    /// then it sends.
    func testOmniLongDraftMustBeReadBeforeApproval() {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", "light", "-CommsDemoOmni", "YES", "-CommsDemoOmniLongDraft", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        let alice = element(labelBeginsWith: "Alice Example,")
        XCTAssertTrue(alice.waitForExistence(timeout: 15), "the demo list")
        alice.tap()

        let review = app.buttons["draft-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard up")
        XCTAssertFalse(app.buttons["draft-approve"].exists, "never inline")
        snap("omni-long-draft-keyboard")

        review.tap()
        let approve = app.buttons["draft-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "the review sheet")
        XCTAssertFalse(approve.isEnabled, "not approvable before every line was on screen")
        snap("omni-review-unread")
        var swipes = 0
        while !approve.isEnabled, swipes < 30 {
            app.staticTexts["draft-full-text"].swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(approve.isEnabled, "scrolled through to the end: approvable — \(approve.value ?? "")")
        XCTAssertGreaterThan(swipes, 1, "it took scrolling")
        approve.tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 5), "sent")
    }

    /// Round 2 (N1): iPhone landscape with the keyboard up and a short draft. Nothing is approvable
    /// inline (the bubble may be pushed off screen there); the review sheet shows the whole draft.
    func testOmniLandscapeKeyboardApprovesOnlyFromTheSheet() {
        app = XCUIApplication()
        app.launchArguments = ["-CommsDemo", "YES", "-CommsAppearance", "light", "-CommsDemoOmni", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let alice = element(labelBeginsWith: "Alice Example,")
        XCTAssertTrue(alice.waitForExistence(timeout: 15), "the demo list")
        alice.tap()
        let review = app.buttons["draft-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        let field = app.textViews["composer-field"].exists ? app.textViews["composer-field"] : app.textFields["composer-field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard up")
        XCTAssertFalse(app.buttons["draft-approve"].exists, "never inline")
        snap("omni-landscape-keyboard")
        review.tap()
        let approve = app.buttons["draft-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        var swipes = 0
        while !approve.isEnabled, swipes < 10 {
            app.staticTexts["draft-full-text"].swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(approve.isEnabled, "the whole short draft was shown")
        approve.tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 5), "sent")
        XCTAssertTrue(element(labelContains: "Thanks Alice").waitForExistence(timeout: 5))
    }

    /// An item of the open menu, by its id or (where the menu drops ids) its title.
    private func menuItem(_ id: String, _ title: String) -> XCUIElement {
        let byID = app.buttons[id]
        if byID.exists { return byID }
        return app.collectionViews.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", id, title, title)).firstMatch
    }

    private func element(labelBeginsWith text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func element(labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Tap a text field until it has keyboard focus. A fresh simulator shows the keyboard's
    /// first-run tip ("Speed up your typing by sliding…") the first time a keyboard comes up; it
    /// takes the focus until Continue (this is what failed testEmojiPickerReactsWithAnyEmoji on
    /// every fresh simulator: "Neither element nor any descendant has keyboard focus").
    private func focus(_ field: XCUIElement) {
        for _ in 0..<3 {
            field.tap()
            let tip = app.buttons["Continue"].firstMatch
            if tip.waitForExistence(timeout: 1.5) {
                // A tap at the tip's point, resolved from the app (not the tip, which may dismiss
                // itself as it loses first responder and invalidate an element-based tap).
                let f = tip.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
                Thread.sleep(forTimeInterval: 0.5)
            }
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
        }
    }

    private func snap(_ name: String, ax: Bool = false) {
        // Let pushes, sheets and scrolls settle (a capture mid-transition is blurred).
        Thread.sleep(forTimeInterval: 1.0)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "ios-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The simulator runner can write to the host's file system.
        let dir = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design/refs/live")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try shot.pngRepresentation.write(to: dir.appendingPathComponent("ios-\(name).png"))
            if ax {
                let fid = dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fidelity/comms-ios")
                try FileManager.default.createDirectory(at: fid, withIntermediateDirectories: true)
                try shot.pngRepresentation.write(to: fid.appendingPathComponent("\(name).png"))
                try app.debugDescription.write(to: fid.appendingPathComponent("\(name).ax.txt"), atomically: true, encoding: .utf8)
            }
        } catch {
            print("could not export ios-\(name).png: \(error)")
        }
    }
}
