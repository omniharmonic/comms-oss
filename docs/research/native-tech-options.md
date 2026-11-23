# Comms: Technical Research Report

Prepared 2026-11-21. Scope: native SwiftUI client in the style of Apple Messages (Liquid Glass) for macOS 26 and iOS 26, unifying mautrix-bridged networks on a self-hosted Matrix homeserver, backed by the Prism TypeScript server and its outbound approval gate.

**How to read this.** Claims marked *(verified)* were checked against primary source code or repos on 2026-11-21. Everything else is cited from docs, WWDC sessions, forums or press, with dates. Forum reports are anecdotal.

**A timing note.** iOS 27 and macOS 27 shipped in fall 2026 (WWDC26 was June 2026, and Apple's "next generation of Apple Intelligence available today" newsroom post is dated 2026-09). The brief targets 26. The sensible setup is to **build with the Xcode 27 SDK and set the deployment target to 26.0**. Some behaviour changes when you link against the 27 SDK, and those changes are noted below.

---

## 1. Liquid Glass in SwiftUI (iOS 26 / macOS 26)

### Core APIs
- **`glassEffect(_:in:)`** applies Liquid Glass to a custom view in a shape. Variants include `.regular`, `.clear` and `.identity`, plus `.tint(_:)` and `.interactive()`. **`GlassEffectContainer(spacing:)`** groups glass shapes so they blend and morph into one another. **`glassEffectID(_:in:)`** with a `@Namespace` animates morphs between shapes inside a container. All three require iOS 26.0 or later ([Apple docs: glassEffectID](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)), [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer); [LiquidGlassReference repo](https://github.com/conorluddy/LiquidGlassReference), 2025).
- **`.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)`** are the standard glass buttons. Use `.glassProminent` with a tint for the blue send button.
- **Automatic glass.** Toolbars, tab bars, sidebars, sheets, popovers and menus pick up glass with no code changes when you build with the 26 SDK. In `NavigationSplitView`, the sidebar is "a Liquid Glass sidebar that floats above your content", and content from the adjacent split can show through it ([WWDC25-323 "Build a SwiftUI app with the new design"](https://developer.apple.com/videos/play/wwdc2025/323/), June 2025; [WWDC25-310 AppKit](https://developer.apple.com/videos/play/wwdc2025/310/)).
- **`backgroundExtensionEffect()`** mirrors and blurs content beyond the safe area so it extends under the floating sidebar or inspector. Apple's Landmarks sample uses it on hero images ([Landmarks: Building an app with Liquid Glass](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass)). In Comms it is mainly useful for a conversation header or wallpaper. Ordinary transcripts do not need it. One forum report says `backgroundExtensionEffect(isEnabled: false)` does not disable it on iPad ([forum 803191](https://developer.apple.com/forums/thread/803191)).
- **Scroll edge effects.** The system applies a soft blur and fade under bars automatically. `.scrollEdgeEffectStyle(.hard | .soft, for: .top/.bottom)` tunes it ([WWDC25-323](https://developer.apple.com/videos/play/wwdc2025/323/)). **`safeAreaBar(edge:)`** is the iOS 26 API for a custom bar that takes part in the scroll edge effect, which `safeAreaInset` does not do. This is the right host for a floating composer.
- **`searchable`.** On iPhone the search field now sits at the bottom. On iPad and Mac it sits top-trailing. Apply `.searchable` to the `NavigationSplitView` itself to get the system placement. Use `Tab(role: .search)` with `TabView` ([WWDC Notes 323](https://wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design/)).
- **`tabViewBottomAccessory`** places a view above the tab bar, like the Music mini-player, and it collapses with the tab bar on scroll ([WWDC25-323](https://developer.apple.com/videos/play/wwdc2025/323/)). Messages has no tab bar, so this matters only if Comms adds tabs such as Inbox, Approvals or Assistant. It could then show a "3 drafts awaiting approval" accessory.

### Matching Messages
- **Layout.** Use a two-column `NavigationSplitView`: the floating glass sidebar holds the conversation list and the detail column holds the transcript. Put `.searchable` on the split view and a compose button in the sidebar toolbar. On iPhone the same view collapses to a stack.
- **Floating composer.** Put a `HStack` (plus button, text field capsule, send button) inside `.safeAreaBar(edge: .bottom)` on the transcript's scroll view. Wrap the controls in one `GlassEffectContainer`, give the text capsule `.glassEffect(.regular.interactive(), in: .capsule)`, and give the send button `.glassProminent`. Use `glassEffectID` so the send button morphs in when text is non-empty. That reproduces the Messages behaviour where the mic turns into send.
- **Known gaps:**
  - An early report found `safeAreaBar` behaving no differently from `safeAreaInset` ([forum 787796](https://developer.apple.com/forums/thread/787796), 2025).
  - Another reported laggy bar animation when content shows or hides inside a bottom `safeAreaBar` on the iOS 26 RC ([forum 800065](https://developer.apple.com/forums/thread/800065)).
  - **When you link against the iOS 27 SDK, the automatic edge style for `safeAreaBar` resolves to `.hard`.** To keep the Messages look, set `.scrollEdgeEffectStyle(.soft, for: .bottom)` explicitly ([Classmethod, Xcode 27](https://dev.classmethod.jp/en/articles/xcode-27-safeareabar-soft-to-hard/), 2026; [forum 834059](https://developer.apple.com/forums/thread/834059), iOS 27 beta 1).
  - On macOS, a May 2026 AppKit thread reports that a custom `NSGlassEffectView` or SwiftUI `.glassEffect()` composer pill shows content through it almost unblurred. It does not get the frosting seen in Mail and Messages, and there is no public API to control the frosting level. The thread had no answers ([forum 827251](https://developer.apple.com/forums/thread/827251)). The frosting in Apple's apps most likely comes from the scroll edge effect, not from the glass itself. **Prototype the Mac composer early.**
  - On macOS 26 betas, SwiftUI buttons overlaid on the titlebar or toolbar area did not receive clicks ([forum 788928](https://developer.apple.com/forums/thread/788928)).

### Performance pitfalls
- Each standalone `.glassEffect()` has its own sampling and backdrop cost. Grouping glass in one `GlassEffectContainer` shares one sampling region and is Apple's stated performance path ([GlassEffectContainer docs](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)). A community measurement (unverified) reported about 9 offscreen passes for 3 ungrouped buttons and 1 when they were grouped ([velog](https://velog.io/@jwlee010523/Improving-SwiftUI-Liquid-Glass-Rendering-Performance)).
- Glass cannot sample other glass. Follow Apple's guidance and keep glass to the navigation layer (bars, composer, floating controls). **Do not put glass on message bubbles**, because dozens of glass views inside a scrolling transcript is the worst case. Messages itself uses opaque bubbles.

### 26.1, 26.2 and 27 updates
- **iOS 26.1** added the user-facing **Clear / Tinted** Liquid Glass setting in Display & Brightness. It also applies to third-party apps that adopt Liquid Glass, so test both modes ([MacRumors](https://www.macrumors.com/how-to/ios-26-1-reduce-liquid-glass-effects/), Oct 2025; [9to5Mac](https://9to5mac.com/2025/10/21/ios-26-1s-new-liquid-glass-setting-is-a-win-for-apple-and-users-alike/)). One forum thread reports that 26.1 added an unexpected dark tint under transparent tab bars ([forum 807633](https://developer.apple.com/forums/thread/807633)).
- **iOS 26.2** (Dec 12, 2025) brought user-facing tweaks: a Lock Screen glass slider and new glass animations for menus and controls. I found no new SwiftUI glass API ([9to5Mac](https://9to5mac.com/2025/12/15/ios-26-2-expands-liquid-glass-in-three-ways-heres-whats-new/)).
- **`UIDesignRequiresCompatibility`**, the opt-out key, is slated for removal in the next major release ([forum 832543](https://developer.apple.com/forums/thread/832543)). Do not rely on it.
- **WWDC26 / iOS 27:**
  - Glass picks up a refined look and responds to the new glass slider automatically.
  - Custom glass on macOS can be marked interactive.
  - iPhone apps become resizable.
  - New toolbar APIs: visibility priority, pinned trailing placement, overflow menu container.
  - Drag-to-reorder works on any container.

  ([WWDC26-269 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269), June 2026; [InfoQ](https://infoq.com/news/2026/07/swiftui-wwdc26), Jul 2026.)

---

## 2. Building the chat transcript

### What SwiftUI provides
- iOS 17 and 18 added `defaultScrollAnchor(.bottom)`, `defaultScrollAnchor(_:for: ScrollAnchorRole)` (`.initialOffset`, `.sizeChanges`, `.alignment`), the `ScrollPosition` struct, `scrollPosition(id:anchor:)`, `onScrollGeometryChange`, `onScrollVisibilityChange` and `onScrollTargetVisibilityChange` ([Nil Coalescing: Modern SwiftUI APIs for programmatic scrolling](https://nilcoalescing.com/blog/ModernSwiftUIAPIsForProgrammaticScrolling); [defaultScrollAnchor docs](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:))).
- WWDC25 claimed macOS lists of 100k+ items load **6x faster** and update **16x faster**, with improved scroll scheduling and idle prefetching on all platforms ([WWDC25-256 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/)).

### Where it breaks: variable-height rows plus prepend
This is the central risk for a chat app, and the reports are consistent:
- **iOS 26:** `ScrollView` + `LazyVStack` with dynamic-height rows, `defaultScrollAnchor(.bottom)` and `scrollPosition(id:)` jumps unpredictably when the keyboard shows or hides. It works on iOS 18 and with fixed-height rows. The bug is filed as FB20979569, Apple could not reproduce it on 26.1 b3, and the reporter says it persists. The last comment, in Dec 2025, has no workaround ([forum 805306](https://developer.apple.com/forums/thread/805306)).
- **iOS 27 (Sept to Oct 2026):** `scrollTo` no longer reaches unrealized `LazyVStack` rows, and opening at the bottom stops 2 to 3 rows short.
  - **Prepend + restore by ID does nothing.** `.defaultScrollAnchor(.bottom, for: .sizeChanges)` re-applies on prepend and snaps to the newest message. `scrollPosition(id:)` re-targets the new first row.
  - Switching to `VStack` fixes it but does not scale.
  - The only working fix reported is to reach the backing `UIScrollView` and adjust `contentOffset` manually after the insert. Filed as FB24968838 ([forum 848608](https://developer.apple.com/forums/thread/848608)).
- **Inverted SwiftUI scroll views** (`.rotationEffect(.degrees(180))` or `scaleEffect(y: -1)`) are a common hack. They break context menus, VoiceOver order and scroll indicators, and they fight the system scroll edge effect.

### How Element X iOS does it *(verified in source, repo HEAD 2026-11-20)*
Element X's timeline is **not** a SwiftUI scroll view. `TimelineTableViewController` (713 lines) works like this:
- It hosts a **`UITableView` flipped with `CGAffineTransform(scaleX: 1, y: -1)`** and flips each cell's `contentView` back. Row 0 is the newest message and sits at the bottom, so prepending history becomes appending at the end. That needs no offset correction.
- Each cell renders SwiftUI through **`UIHostingConfiguration`**, so bubbles are still SwiftUI views.
- It uses a **`UITableViewDiffableDataSource`** keyed by timeline unique IDs.
- **Back-pagination is throttled through a Combine publisher.** It fires when `contentOffset.y > contentSize.height - 2 × visibleHeight`, about two screens of prefetch. The code notes that "backward pagination jumps if items are inserted whilst actively dragging" and that it defers those inserts.
- It nudges `contentOffset.y = -1` to work around edge cases at the bottom.

([element-x-ios TimelineTableViewController.swift](https://github.com/element-hq/element-x-ios/blob/develop/ElementX/Sources/Screens/Timeline/TimelineTableViewController.swift).) Element X's deployment target is iOS 18.5 and macOS 14.5 (project.yml, verified).

Another option that avoids flipping is **ChatLayout**, a custom `UICollectionViewLayout`. It does not rotate the view, works with diffable data sources and keeps position through content insets ([ChatLayout](https://github.com/ekazaev/ChatLayout)). VoiceOver swipe order inverts in flipped collection views, so a flipped table needs accessibility fixes ([forum 759997](https://developer.apple.com/forums/thread/759997)).

### Recommendation for the transcript
- **iOS:** use a `UIViewControllerRepresentable` around a flipped `UITableView` or `UICollectionView` with `UIHostingConfiguration` cells (the Element X pattern). Prefetch two screens ahead and defer inserts while dragging.
- **macOS:** use an `NSTableView` or `NSCollectionView` with `NSHostingView` cells. Stick to Apple's normal geometry and correct the scroll offset manually on prepend, because flipping is awkward in AppKit. Alternatively, try SwiftUI `List` on macOS and keep it if it holds up, since macOS list performance was the WWDC25 focus.
- **Bubbles:** keep the bubbles in pure SwiftUI so they are shared across platforms.
- **SwiftUI-only fallback:** a `ScrollView` + `LazyVStack` that only ever appends works well for a small personal app. Load a large initial window and paginate rarely. Keep it behind a protocol so it can be swapped out.

### Composer text input
- `TextField("", text:, axis: .vertical).lineLimit(1...6)` grows and then scrolls ([Use Your Loaf](https://useyourloaf.com/blog/swiftui-multi-line-text-fields)). It is fine for an MVP.
- Limits:
  - There is no paste-image hook.
  - There is no attributed text for @-mention pills.
  - Return / Shift-Return control is limited, with `onSubmit` and `onKeyPress` quirks on macOS.
  - A 26 report says `lineLimit` was ignored after 10 to 20 lines inside a `Form` ([forum 802101](https://developer.apple.com/forums/thread/802101)).
- iOS 26 added `TextEditor` with `AttributedString` support, so test whether it covers mention pills.
- For a Messages-grade composer you will likely end up with a **`UITextView` / `NSTextView` wrapper**. That gives `NSTextAttachment` mention tokens, image paste via `NSItemProvider`, Return to send and Shift-Return for a newline, and inline "@assistant" detection. Plan for that wrapper. It is also where the assistant-tagging UX lives (section 6).

### Bubbles with tails
- Write a custom `Shape` that draws the body and tail as one path, so strokes and shadows follow the whole outline ([Cookpad](https://techlife.cookpad.com/entry/2023/06/21/162523); [theswiftkit chat-bubble](https://theswiftk.it.com/swiftui/chat-bubble)).
- Signal's iOS `BubbleConfiguration.swift` is worth reading for grouping rules: the tail appears only on the last bubble of a run, and corner radii shrink between consecutive bubbles ([Signal-iOS](https://github.com/signalapp/Signal-iOS/blob/main/SignalUI/Appearance/BubbleConfiguration.swift)). `UnevenRoundedRectangle` handles the grouped bubbles without tails.

---

## 3. How the client talks to Matrix

### Option A: matrix-rust-sdk through uniffi (`MatrixRustSDK` Swift package)
- **Maturity** *(verified)*: the package has moved to **`element-hq/matrix-rust-components-swift`**. Releases use calendar versioning and ship several times a month (26.11.17 on 2026-11-17, 26.11.11, 26.10.27). The Rust `matrix-sdk` is at 0.19.1 (2026-09-18). It is the engine of Element X iOS and Android and is under active development. Element X moved to Swift 6.2 ([TWIM 2026-07-03](https://matrix.org/blog/2026/07/03/this-week-in-matrix-2026-07-03/)), and the room list got a new loading and sorting algorithm ([TWIM 2026-01-16](https://matrix.org/blog/2026/01/16/this-week-in-matrix-2026-01-16/)).
- **What it covers** *(verified from `bindings/matrix-sdk-ffi`)*:
  - `RoomListService` (sliding-sync-backed filtered and sorted lists) and `SyncService`.
  - A **Timeline** with `paginate_backwards/forwards`, `send`, `send_reply`, `edit`, `toggle_reaction`, `redact_event`, `send_read_receipt` / `mark_as_read`, `send_image/video/audio/voice_message/file/gallery`, polls, location, threads (`thread_root`, `thread_summary`), `edit_revisions`, `retry_send` / `abort_send` (a send queue with local echo), and `load_reply_details`.
  - Timeline items already aggregate reactions, edits (`is_edited`), replies (`in_reply_to`) and read receipts. Typing notifications are exposed on the room.
  - **URL previews** were added in Aug 2026: `Client::get_media_preview(url, ts)` returns raw OpenGraph JSON ([PR #6918](https://github.com/matrix-org/matrix-rust-sdk/pull/6918), [PR #6949](https://github.com/matrix-org/matrix-rust-sdk/pull/6949), merged 2026-09-01).
  - The FFI also now has a `sync_v2.rs` module (2026), so a classic `/sync` path appears to be coming back.
- **Server requirements:** native **Simplified Sliding Sync (MSC4186)** has been in Synapse since 1.114 (Sept 2024), enabled by default with no proxy. The proxy was decommissioned on 2024-11-21 ([matrix.org: moving to native sliding sync](https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/)). The core MSC4186 was **accepted by the SCT in early July 2026**, though its extension MSCs were still in review ([TWIM 2026-07-03](https://matrix.org/blog/2026/07/03/this-week-in-matrix-2026-07-03/)). Any current Synapse works.
- **Encryption:** full Olm/Megolm, cross-signing, key backup and recovery, all built in. This matters only if bridge portal rooms are encrypted. In mautrix, `encryption.allow` / `default` are off unless enabled.
- **macOS:** the Swift package's `Package.swift` declares only `.iOS(.v16)`. The build script (`xtask/src/swift.rs`) does target `aarch64-apple-darwin` and `x86_64-apple-darwin` as top-tier, so a macOS slice can be built. You may need to build the xcframework yourself and verify the published one contains macOS. Expect a large binary (tens of MB) and Rust build tooling in CI.
- **Costs for Comms:**
  - The app becomes a second Matrix **device** with its own access token and crypto store, verified separately.
  - Most importantly, **the app would hold a credential that can send to humans directly, which bypasses the Prism gate.** Owner-typed messages are allowed, but any assistant feature in the client would need discipline so it never calls `timeline.send` itself.

### Option B: legacy matrix-ios-sdk / MatrixKit
- **MatrixKit is deprecated.** Its CocoaPods page says "MatrixKit will no longer be supported" and its code was merged into Element iOS ([CocoaPods MatrixKit](https://cocoapods.org/pods/MatrixKit)).
- matrix-ios-sdk (Objective-C) survives only to support classic Element iOS, which Element X replaces.
- **Not recommended.**

### Option C: thin client through the Prism API
- **Upsides:**
  - Prism already holds the Matrix credentials and syncs.
  - **One choke point for every send.** The approval gate stays where it is and becomes unbypassable from the client.
  - The client has no crypto store, no second device and no Rust binary, so it is small and simple to build on both Macs and iOS.
  - The assistant runs server-side with full context.
- **Costs:**
  - **Prism must expose a chat-shaped API:** a room list with unread counts and bridge metadata, a paginated timeline with aggregated reactions, edits and replies, read markers, typing, media proxy and thumbnails, and send/react/edit/redact.
  - It also needs **a push channel** (WebSocket/SSE) and APNs for background notifications. A Notification Service Extension would fetch from Prism.
  - You re-implement relation aggregation that the Rust SDK gives you for free. Offline cache and outbox are yours to build (SwiftData or GRDB).
  - Latency is one extra hop. That is irrelevant on a LAN or Tailscale.
- **Middle path:** Prism could run matrix-rust-sdk via its Node bindings (`@matrix-org/matrix-sdk-crypto-nodejs` covers crypto only), or simply keep its existing Matrix client. It would then serve **pre-aggregated** timeline items, so the Swift client stays dumb.

### Trade-off summary (single user, server already has credentials)

| | Rust SDK in app | Thin client via Prism |
|---|---|---|
| Time to first useful build | Medium (SDK does timeline, room list, sync) | Medium-high (must build Prism endpoints and push) |
| Approval-gate integrity | Weak: the client can send directly | **Strong: one gateway** |
| Offline and local search | Built in (SQLite stores, search service) | Must build |
| E2EE rooms | Native | Prism decrypts (it already must, to gate) |
| macOS support | Needs a self-built xcframework or verification | Trivial |
| Bridge metadata (`m.bridge`, `com.beeper.*`) | Read raw state yourself; the SDK does not interpret it | Prism normalises it |
| Maintenance | Track fast-moving FFI (breaking changes are common) | Your own API, stable |

### How mautrix bridges represent things *(verified in mautrix-go `event/` package)*
- **Room-level network identity:** state event **`m.bridge`**, with the legacy duplicate **`uk.half-shot.bridge`** (MSC2346). Its content is `BridgeEventContent`:
  - `bridgebot`, `creator`
  - `protocol` {`id`, `displayname`, `avatar_url` (mxc), `external_url`}, for example `id: "whatsapp"`
  - optional `network` {…} for multi-workspace networks such as a Slack workspace or Discord guild
  - `channel` {`id`, `displayname`, `avatar_url`, `external_url`, `fi.mau.receiver`, `com.beeper.message_request`, `com.beeper.user_blocked`}
  - `com.beeper.room_type` / `com.beeper.room_type.v2`, which tells DMs from groups

  **For network badges, use `protocol.id` with a local icon set. Fall back to `protocol.avatar_url`.** ([state.go](https://github.com/mautrix/go/blob/main/event/state.go); [MSC2346](https://github.com/matrix-org/matrix-doc/blob/hs/msc-bridge-inf/proposals/2346-bridge-info-state-event.md).)
- **Ghost-user profiles** carry `com.beeper.bridge.network`, `.service`, `.remote_id` and `.identifiers`, which give the phone number or handle (`BeeperProfileExtra`, beeper.go).
- **Reactions** are standard `m.reaction` with an `m.annotation` relation. **Edits** are `m.replace` with `m.new_content`. **Replies** are `m.relates_to.m.in_reply_to`. **Threads** use `m.thread`. **Redactions** are standard; `com.beeper.dont_render_redacted_placeholder` hides the tombstone.
- **Media** is standard `m.image`, `m.video` and so on, plus `fi.mau.gif`, `fi.mau.bridged_sticker`, `com.beeper.bridged_emojis` and `com.beeper.view_limited` (view-once). Voice messages use MSC3245 `org.matrix.msc3245.voice`.
- **Delivery and failure status:** the message event **`com.beeper.message_send_status`** has a `status`, a `reason`, a human `message`, `network` and `delivered_to_users`. **This is how you show "Not delivered" or a retry badge.** The bridge also emits `m.receipt` read receipts from the remote network.
- **Other useful events:**
  - Link previews arrive inline as **`com.beeper.linkpreviews`**: OpenGraph plus `matched_url`, an encrypted image and a blurhash.
  - Room capabilities arrive as **`com.beeper.room_features`** state. Use it to grey out edit and react where the network does not support them.
  - Disappearing-message timers arrive as `com.beeper.disappearing_timer` state.
  - Beeper also defines `com.beeper.mute` account data, `com.beeper.delete_chat`, `com.beeper.accept_message_request` and `com.beeper.block_user`. Some of these depend on Beeper's server (hungryserv).

---

## 4. Link previews

| Source | Who sees the URL | Notes |
|---|---|---|
| **Bridge-supplied `com.beeper.linkpreviews`** | Nobody new; the remote network already generated it | Best default for bridged chats. No extra fetch. |
| **Homeserver `GET /_matrix/client/v1/media/preview_url`** (authenticated media, spec v1.11+) | Your homeserver; the target site sees the server's IP | Synapse default `url_preview_enabled: false`. It needs `url_preview_ip_range_blacklist`. There is SSRF history: [CVE-2023-32683](https://github.com/matrix-org/synapse/security/advisories/GHSA-98px-6486-j7qc), fixed in 1.85. On a self-hosted server you own, the "server sees links" concern largely disappears. |
| **Apple `LPMetadataProvider` / `LPLinkView`** | The target site sees the **device IP** | One provider per fetch. Apple advises caching `LPLinkMetadata` (it supports NSSecureCoding) ([LPMetadataProvider docs](https://developer.apple.com/documentation/linkpresentation/lpmetadataprovider)). The forum question about whether Apple proxies the fetch is unanswered ([forum 712999](https://developer.apple.com/forums/thread/712999)). `LPLinkView` is heavy in scrolling cells, so render your own card from the metadata. |

**Prior art** *(verified)*: Element X iOS shipped link previews with Apple's LinkPresentation framework, cached in memory only ([PR #4520](https://github.com/element-hq/element-x-ios/pull/4520), merged 2025-09-19). An open PR from **2026-11-17** adds homeserver previews as a developer option, set separately for each room type. It is on or off for unencrypted rooms; for encrypted rooms the choice is off, homeserver or Apple. The PR notes, "the homeserver sees every previewed link, while Apple's on device LinkPresentation fetch exposes the device IP address to the linked site" ([PR #6526](https://github.com/element-hq/element-x-ios/pull/6526)).

**Recommendation for Comms:**
1. Use `com.beeper.linkpreviews` when present.
2. Otherwise ask **Prism or the homeserver** to fetch the preview (one egress IP, cached centrally, shared by both Macs and iOS).
3. Never fetch previews automatically for links in message requests or from unknown senders.

LinkPresentation is only a fallback.

---

## 5. Prior art: unified inboxes on Matrix

- **Beeper architecture:**
  - Beeper runs **hungryserv**, an unfederated Matrix homeserver that is not fully compliant with the client-server API ("hungryserv doesn't implement the full client-server API, so some bridges may not work") ([bridge-manager](https://pkg.go.dev/github.com/beeper/bridge-manager)).
  - It also runs **mautrix bridgev2 ("megabridge")** connectors, and megahungry multiplexes single-tenant instances ([mau.fi 2024-H1](https://mau.fi/blog/2024-h1-mautrix-updates/)).
  - The Desktop app was rebuilt on the **Texts.com** codebase after the merger, and iOS was rebuilt mostly from scratch ([Beeper 2024 roadmap](https://blog.beeper.com/2024/06/04/2024-beeper-roadmap/); [beta announcement](https://blog.beeper.com/2025/02/24/try-out-the-new-beeper-desktop-and-ios-beta/), Feb 2025).
  - **On-device bridges** now run inside the client. Messages go straight from the device to the network, and only chat state (archive, pins, reminders) syncs through Beeper ([help center](https://help.beeper.com/en_US/troubleshooting/beeper-on-device-vs-beeper-cloud-what-goes-to-beeper-servers), 2026).
- **iOS notifications.** Beeper's write-up is directly relevant to the Comms NSE ([Beeper blog, 2025-10-01](https://blog.beeper.com/2025/10/01/how-beeper-ios-implements-notifications/)):
  - The NSE is a separate process, so it needs a lock to keep the app and the NSE from processing at the same time.
  - The NSE memory limit is 50 MB, and higher on Apple Intelligence devices.
  - Blowing the limit produces blank notifications.
  - **A thin client avoids almost all of this:** Prism can send APNs with the sender, network and a preview already rendered.
- **Developer surface.** Beeper offers a **local Desktop API with a built-in MCP server**, self-hostable bridges via `bbctl`, and a bounty of up to $50k for bridgev2 bridges ([developers.beeper.com](https://developers.beeper.com/); [build a Beeper bridge](https://blog.beeper.com/2025/10/28/build-a-beeper-bridge/), Oct 2025).
- **UX Beeper nailed:**
  - One inbox with **network badges on avatars**.
  - **Inbox / Low priority / Archive** with snooze and reminders.
  - Per-chat "mark unread" and pins.
  - **Merged contacts** (one person across four networks) ([Digital Trends](https://www.digitaltrends.com/phones/beeper-just-solved-the-headache-of-messaging-the-same-person-on-four-different-apps/)).
  - Keyboard-first desktop with Cmd-K jump and fast search.
  - Message requests kept separate.
  - Clear "sending / sent / failed" states.
- **Open source:**
  - **gomuks** (Tulir, mautrix author) is the most bridge-aware open client. It is Go with a web frontend, and it has URL previews, archivemuks and pop-out widgets ([gomuks](https://github.com/gomuks/gomuks); [mau.fi Feb 2026](https://mau.fi/blog/2026-02-mautrix-release/), [Aug 2026](https://mau.fi/blog/2026-08-mautrix-release/)). Its handling of `m.bridge` is a good reference.
  - Beeper's own clients are closed. Only `bridge-manager`, `platform-imessage` and the bridges are open ([Beeper open source](https://developers.beeper.com/open-source)).
  - Element X is the best open SwiftUI reference for code structure. It is not bridge-aware.

---

## 6. AI-assistant-in-messaging prior art

- **Apple Intelligence in Messages (iOS 26):**
  - Summaries of unread messages under each conversation in the list.
  - Smart Reply chips on the keyboard that draft into the field.
  - Priority notifications and notification summaries.
  - Unknown-sender screening ([Apple support](https://support.apple.com/en-ph/guide/iphone/iph64709c5c3/ios); [MacRumors guide](https://www.macrumors.com/guide/apple-intelligence-smart-replies-summaries)).
- **Apple Intelligence in Messages (iOS 27):**
  - Smart Reply matches your writing style.
  - "Write with Siri" button above the keyboard.
  - Contextual one-tap suggestions such as attaching a requested photo or adding an event.
  - Failed sends auto-retry.
  - Faster large-conversation scrolling.

  ([MacRumors, 2026-08-26](https://www.macrumors.com/guide/ios-27-messages/).)
- **Developer access.** There is no public API for the Messages summary or Smart Reply features. Third-party levers are the `relevanceScore` and `interruptionLevel` notification settings that feed priority and summaries ([Courier](https://www.courier.com/blog/apple-intelligence-notifications)). The Foundation Models framework (iOS 26) gives on-device LLM access for local summaries.
- **Gmail / Gemini:**
  - Help Me Write and Suggested Replies became free in Jan 2026.
  - Personalization from past mail, chats and Drive, with a **"Sources"** disclosure, arrived Feb to May 2026.
  - **Follow-up refinement instructions** on a draft arrived Jul 2026.
  - Wider Workspace rollout came Nov 2026.

  ([Google blog](https://blog.google/products-and-platforms/products/gmail/gmail-is-entering-the-gemini-era/); [Workspace Updates, 2026-07-14](https://workspaceupdates.googleblog.com/2026/07/new-refinement-capabilities-allow-custom-editing-with-Help-me-write-in-Gmail.html); [2026-11-10](https://workspaceupdates.googleblog.com/2026/11/expanding-gemini-in-gmail-to-more-Google-Workspace-users.html).)
- **Superhuman** pre-writes drafts in your voice for threads that need a reply and inserts them into the composer for edit-then-send. My searches did not return 2026 primary sources, so treat this as background.
- **Beeper AI (Desktop, Beeper Plus):**
  - Type **`@ChatGPT` or `@Apple Intelligence`** in any chat.
  - A placeholder appears and then updates in place.
  - **The answer is sent into the chat, visible to every participant.** It requires an opt-in setting and shows a warning modal on first use.
  - Apple Intelligence requires macOS 26 on Apple Silicon.

  ([Beeper help: AI in chats](https://help.beeper.com/en_US/beeper-plus/ai-in-beeper-chats), ~Mar 2026.) **Comms should not do this.** A public in-chat answer violates the owner's rule that nothing goes to a human without approval of that exact message.

### Patterns for "tag in the assistant" in Comms
1. **A mention token in the composer routes privately.** Typing `@assistant …` (or pressing a glass sparkle button in the composer container) turns the composer into an *instruction* field, visibly tinted. Sending it goes to Prism's assistant, **never to the room**.
2. **The result returns as a draft card pinned above the composer.** It is a "suggested reply" bubble with a distinct style (dashed outline or sparkle) and actions: **Insert into composer**, **Approve & send this exact text**, **Refine…** (Gmail-style follow-up) and **Discard**. Approval binds to a hash of the exact text. Any edit returns it to "owner-typed", which is the owner's own action.
3. **Smart-reply chips** above the composer (Apple pattern) only ever **insert**, never send.
4. **Per-conversation summary** in the list row (Apple pattern) and a "catch me up" header at the top of unread runs. Both are generated server-side and shown with a sparkle glyph and a "Sources" disclosure (Gmail pattern).
5. **Approval inbox.** Use a sidebar section and/or `tabViewBottomAccessory` showing "N drafts awaiting approval". This matches Omni's finished-work cards and one-tap approve.
6. **Provenance on sent messages.** A locally stored flag (never sent to the network) marks messages that were assistant-drafted and approved, so the transcript stays honest for the owner.

---

## 7. Recommendation

**Architecture: thin native client over a new Prism "chat API". Do not embed matrix-rust-sdk in v1.**
- The approval gate is the product's hard safety line. A client holding a Matrix access token is a second, ungated send path. With Prism as the only gateway, the rule is enforced in one place.
  - Owner-typed sends go `POST /comms/rooms/:id/send` with `origin: owner`, logged and sent at once.
  - Assistant content can only enter as drafts that need `approve(draftId, sha256(text))`.
- Single user, server already syncing, LAN or Tailscale access: the Rust SDK's main advantages (crypto, multi-account sync, offline-first) mostly duplicate what Prism has. Its costs (a second device, an iOS-only package manifest, a large binary, fast-moving FFI) fall entirely on the client.
- Prism should normalise bridge metadata into the API:
  - `network` from `m.bridge.protocol.id` plus icon
  - DM or group from `com.beeper.room_type`
  - capabilities from `com.beeper.room_features`
  - delivery state from `com.beeper.message_send_status`
  - previews from `com.beeper.linkpreviews` or a server-side `preview_url` call
  - reactions, edits and replies aggregated server-side
- Add a WebSocket/SSE stream for live updates. Add APNs sent by Prism with rendered content, which removes most of the NSE complexity Beeper describes.
- **Keep a door open:** define a `ChatBackend` protocol in Swift. If offline-first or E2EE-to-device ever matters, a `RustSDKBackend` built on `MatrixRustSDK` can slot in, still restricted to read-only plus owner-typed sends.

**UI stack:**
- Use `NavigationSplitView` (floating glass sidebar on Tahoe, collapsing on iPhone) with `.searchable` on the split view.
- The composer is a `.safeAreaBar(edge: .bottom)` containing one `GlassEffectContainer`, an interactive glass capsule and a `.glassProminent` send button that morphs in via `glassEffectID`. Set `.scrollEdgeEffectStyle(.soft, for: .bottom)` explicitly for the iOS 27 SDK.
- Bubbles are opaque custom `Shape`s with tails and **no glass**.
- **Transcript:** a flipped `UITableView` / `UICollectionView` with `UIHostingConfiguration` cells on iOS (the Element X pattern, prefetching two screens ahead), and `NSTableView` with `NSHostingView` on macOS. Avoid relying on `ScrollView` + `LazyVStack` prepend behaviour, given the open iOS 26 and 27 bugs (FB20979569, FB24968838).
- **Composer text:** start with `TextField(axis: .vertical)`. Budget a `UITextView` / `NSTextView` wrapper for v1.1 for image paste, Return to send and `@assistant` tokens.
- **Assistant UX:** private `@assistant` instructions → a draft card above the composer → Insert / Approve-exact / Refine / Discard. Never Beeper's public in-chat replies.

**Prototype first, because these carry the most risk:**
1. The macOS composer frosting and scroll edge effect (forum 827251 has no answer).
2. Transcript prepend stability on iOS 26.x and iOS 27 with real variable-height bubbles.
3. Clear vs Tinted glass appearance.
4. NSE / APNs payload flow from Prism.
