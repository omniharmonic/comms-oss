# Apple Messages (iOS 26 / macOS 26 Tahoe) — UX Study for "Comms"

Research date: 2026-11-21. Scope: Messages as shipped in iOS 26 / macOS Tahoe 26 (Liquid Glass era). Note that iOS 27 / macOS 27 are now current (Apple's guides already carry iOS 27 versions, and 9to5Mac covers "everything new for Messages in iOS 27"). This spec targets the 26 design as requested. Diff against 27 before locking the PRD.

Reference images: `refs/` (36 files, listed in section 12). Every image was opened and checked by eye.

**Confidence labels used throughout**
- **[doc]**: stated in Apple documentation (HIG, Support guide, WWDC, Newsroom).
- **[meas]**: measured with a pixel scan (Pillow) on a reference image, then converted to points with the scale factor noted.
- **[est]**: estimated by eye from screenshots, or from general platform knowledge. Validate on device.

Scale factors used for [meas]:
- Apple Newsroom iPhone renders: screen ≈ 700 px for 402 pt (iPhone 16/17 Pro), so **1.741 px/pt**.
- Apple Support guide iPhone illustrations: screen ≈ 445 px for 402 pt, so **1.107 px/pt**.
- 9to5Mac real-device crop (typing indicator): screen 1260 px for 402 pt, so **3.13 px/pt**.
- MacRumors real-device dark screenshots: about **1.115 px/pt**.

Marketing renders can be slightly stylised. Where a real-device screenshot and a render disagree, the device value wins.

---

## 1. Global design language (Liquid Glass)

### Layers
Liquid Glass "forms a distinct functional layer for controls and navigation elements… that floats above the content layer." HIG also says "Don't use Liquid Glass in the content layer" [doc: HIG Materials].

In Messages, glass appears **only** on:
- the top toolbar buttons: back, Edit, Filter, video call, and the avatar/name pill;
- the bottom search field and Compose button on the list;
- the composer: the `+` circle and the message capsule;
- menus and popovers: the Filter menu, the `+` app menu, context menus, and the Tapback bar;
- the sidebar and inspector on Mac.

Message bubbles are **not glass**. They are opaque content, with two exceptions noted under Backgrounds.

### Variants
- **Regular glass** is the default. It "blurs and adjusts the luminosity of background content." Use it for anything carrying lots of text (sidebars, popovers, menus) [doc].
- **Clear glass** is only for controls over rich media. Add a 35% dark dimming layer if the content behind is bright [doc]. Messages uses tinted and clear glass for the toolbar and composer when a conversation background is set [meas/visual: custom-background images].

### Scroll edge effect
- This effect replaces hard dividers. Content under the floating bars is blurred and faded [doc: WWDC25 356].
- **Soft** style is used on iOS. **Hard** style is used mainly on macOS.
- Apply **one per view** [doc].
- In Messages the top ~110 pt of the transcript fades and blurs under the header (bubbles visibly ghost under the avatar pill), and the bottom of the list fades under the search bar [visual: polls, transcript, and list images].

### Shapes
Three shape types: fixed, capsule (radius = height ÷ 2), and concentric (child radius = parent radius − padding) [doc: WWDC25 356].
- iPhone toolbar buttons are glass **circles**.
- Text buttons ("Edit") are glass **capsules**.
- Menus are large-radius rounded rectangles that sit concentric to the screen corners.
- Mac sidebar and inspector are **inset floating** panels with concentric corners [doc + visual].

### Grouping
- Related toolbar items share one glass background.
- Don't mix text and symbol items in one group.
- Keep the primary action separate and tinted. The send arrow is the tinted primary.
- Aim for at most three groups [doc: HIG Toolbars, WWDC25 356].

### Motion
- Glass "morphs": menus, popovers, and sheets grow out of the control that presents them. The Filter menu emerges from the filter button, and the `+` menu from the `+` button.
- The SwiftUI building blocks are `GlassEffectContainer`, `glassEffectID`, and `.navigationTransition(.zoom)` / `matchedTransitionSource` [doc: WWDC25 323].

### Typography
- SF Pro, with Dynamic Type on iOS. iOS Large (default) sizes: Body 17/22, Headline 17/22 semibold, Subheadline 15/20, Footnote 13/18, Caption1 12/16, Caption2 11/13 [doc: HIG Typography].
- macOS fixed sizes: Body 13/16, Headline 13 bold, Subheadline 11/14, Caption 10/13, Title3 15/20 [doc].
- Messages on Mac lets the user scale transcript text with ⌘+ / ⌘− [doc: keyboard shortcuts].

### Accessibility
Reduce Transparency, Increase Contrast, and the user's "Liquid Glass look" setting change glass appearance [doc: HIG Materials]. Comms must use system glass APIs (`.glassEffect`, `.buttonStyle(.glass)`) rather than hand-rolled blur, so it inherits this behaviour.

---

## 2. Colors

| Token | Light | Dark | Source |
|---|---|---|---|
| iMessage outgoing bubble | ≈ #37AAFC at top of screen → #2AA0FD at bottom (vertical gradient tied to **screen position**, not to the bubble) | Same blue family | [meas] guide PNG: y=215 px → (76,185,248); y=490 → (51,167,252); y=580 → (42,160,253). Device JPEG: (52,170,254) |
| macOS outgoing bubble | ≈ #1896FE | — | [meas] Mac guide PNG (24,150,254) |
| System accent / selection blue | #0088FF (iOS 26 HIG systemBlue light; dark ≈ #0091FF) | | [meas] Mac sidebar selection (0,136,254) matches. Dark value is [est] from HIG 2025 palette |
| Incoming bubble | **#E9E9EB** | **≈ #262628** | [meas] (233,233,235) in 4 separate images. Dark (38,38,40) from MacRumors device shot |
| SMS / RCS outgoing bubble | systemGreen ≈ #34C759 (dark #30D158), same screen-position gradient | | [est] Apple guide confirms "green bubbles = not iMessage" [doc] |
| Typing-indicator bubble | #E9E9EB; dots ≈ #808080 (active) / #ABABAD (resting) | | [meas] |
| Secondary label ("Read 3:06 PM", timestamps) | ≈ #8D8D8F | | [meas] (141,141,143) |
| Poll bubble (selected / unselected) | Solid orange (≈ systemOrange) / 15% orange tint with orange text | | [est] newsroom polls |
| Destructive text ("Delete", "Leave this Conversation") | systemRed | | [visual] |
| Unread dot | systemBlue | | [doc + visual] |

**Implementation note.** The bubble gradient is the classic iMessage effect. Implement it as a single full-screen gradient layer masked by the bubble shapes, so colour depends on the bubble's on-screen y-position and shifts as you scroll. Don't give each bubble its own gradient.

**Implication for Comms.** Apple Messages has only blue and green, and per-network colour coding by bubble isn't supported in Apple's UI. Keep blue for "your outgoing message on a rich network" and green for SMS. Signal network identity with a small badge or the composer placeholder ("Text Message • SMS" / "iMessage") rather than recoloring bubbles. Apple already uses placeholder text to signal transport [doc + visual: `ios26-guide-transcript-1to1-add-button.png` shows "Text Message • SMS"].

---

## 3. iPhone: Conversation List

Reference images: `ios26-guide-conversation-list-compose-unread.png`, `ios26-guide-list-unread-swipe.png`, `ios26-guide-list-filter-menu.png`, `ios26-9to5-screening-spam.jpg`, `ios26-mr-screening-settings.jpg`.

### Structure, top to bottom

1. **Top toolbar** (floating glass, no bar background):
   - Leading: **Edit** glass capsule.
   - Center: inline title **"Messages"** in 17 pt semibold. This changed from iOS 18, which used a large-title "Messages" that collapsed on scroll [visual + est].
   - Trailing: **Filter** glass circle with the `line.3.horizontal.decrease` glyph.
   - The Filter button shows a **blue numeric badge** when filtered folders have new items (for example "2" for new Unknown Senders) [visual: `ios26-9to5-screening-spam.jpg`].
   - When a filter is active, the icon turns blue [doc].
2. **Pinned conversations grid**:
   - Three columns of large circular avatars with the name below in Caption/Footnote secondary.
   - Up to 9 pins [doc via Apple HT201287].
   - Pinned items can show a **typing or last-message bubble** popping off the avatar, plus an unread blue dot before the name [visual: Mac guide image, same on iOS].
3. **Conversation rows**, full-width list with inset separators that start at the text column.
4. **Bottom floating bar**:
   - A **Search** glass capsule with a magnifier, "Search" placeholder, and a trailing mic.
   - A separate **Compose** glass circle (`square.and.pencil`) at the bottom right.
   - **New in iOS 26:** Compose moved from top-right to bottom-right, and search moved from the top of the list to the bottom [doc: "tap the Compose button at the bottom right"; "Tap the search field below the conversation list"].

### Row anatomy

| Element | Spec | Label |
|---|---|---|
| Row height | ≈ 88–90 pt. Fixed: single-line previews keep the same height as two-line ones | [meas] 98.5 px ÷ 1.107 = 89 pt (guide); 100 px ÷ 1.115 = 90 pt (device) |
| Avatar | ≈ 45 pt circle, leading inset ≈ 16 pt (room left for the unread dot) | [meas] 50 px ÷ 1.107 |
| Unread indicator | ≈ 10 pt systemBlue dot, centered in the leading gutter, vertically aligned to the avatar | [visual + est] |
| Name | Body/Headline 17 pt semibold, label color, 1 line | [est from HIG sizes] |
| Timestamp | Subheadline 15 pt, secondary; "8:42 AM" / "Yesterday" / "Sunday" / "15/09/2025" | [visual] |
| Disclosure chevron | Tertiary `chevron.right` after the timestamp (kept in iOS 26) | [visual] |
| Preview | Subheadline 15 pt secondary, **2 lines max**, truncating with "…". Tapback previews read "Ian loved 'Family dinner…'" | [visual] |
| Separator | Hairline, inset to the text column | [visual] |
| AI summary | With Apple Intelligence on, the preview slot shows a **summary of unread messages** instead of the raw text | [doc: Use Apple Intelligence in Messages] |
| Time-Sensitive tag | A gray capsule "Time Sensitive" can replace the timestamp for screened senders | [visual: `ios26-9to5-screening-spam.jpg`] |

### Pinned grid
- Avatar ≈ 90–96 pt [meas: 100 px ÷ 1.107; 108 px ÷ 1.115].
- Name in ≈ 13 pt secondary.
- Group pins show a cluster of 2–3 overlapping mini avatars inside the circle [visual].

### Swipe actions [doc + visual: `ios26-guide-list-unread-swipe.png`]
- **Swipe right** marks the conversation read or unread. A full swipe triggers it. A partial drag reveals a blue circular glass-style button. Pin is also on the leading side (iOS 18 behaviour; [est] that it carries over).
- **Swipe left** shows Hide Alerts (purple) and Delete (red) [est from iOS 18 plus AT&T guide "swipe left… Delete"].
- In iOS 26 the revealed actions are **circular buttons**, and the row itself becomes a rounded, lifted card while dragged (visible in the guide image: the row is inset with a ~20 pt radius gray card). This differs from iOS 18's full-height rectangular actions [visual].

### Long-press on a row
A context menu with a live preview of the transcript. Items: Pin / Unpin, Mark as Unread / Read, Hide Alerts, Delete [doc: AppleVis listing + Apple guide].

### Edit menu
Tapping "Edit" opens a menu: Select Messages, Edit Pins, Set Up Name & Photo [est]. In selection mode a bottom bar offers **Read All**, **Unread**, and **Delete** [doc: "tap Edit, tap Select Messages… Read All"].

---

## 4. iPhone: Filters, Screening, Spam (the most important part for Comms)

Reference images: `ios26-mr-filter-menu.jpg` (dark), `ios26-mr-filtering.jpg` (light, Transactions submenu chevron), `ios26-guide-list-filter-menu.png` ("1 New" subtitle), `ios26-mr-screening-settings.jpg`, `ios26-mr-unknown-mark-known.jpg`, `macos26-9to5-filter-menu-unread.jpg`.

### Filter menu
The menu is a glass popover anchored to the top-right Filter button. Its contents are **dynamic**:

- **Section 1 (folders, single-select, checkmark on the active one):**
  - ✓ **Messages** (`bubble.left.and.bubble.right`): the main inbox.
  - **Unknown Senders** (person with "?"): has a **subtitle "1 New"** when there are unseen items [visual].
  - **Transactions** (tag), with a **› submenu**. In the light image it opens sub-categories such as Finance, Orders, Reminders [visual chevron; sub-items est].
  - **Promotions** (megaphone).
  - **Spam** (`xmark.bin`).
  - **Recently Deleted** (trash).
  - Transactions and Promotions appear **only when Text Message Filter is on** [doc + visual: the menu without them appears in `ios26-mr-screening-settings.jpg`].
- **Section 2, "Filter By"** (Mac shows a header; iOS shows the item when relevant): **Unread** (`message.badge`). This is a toggle that stacks on top of the folder. The Filter icon turns blue when it's on [doc + visual Mac].
- **Footer:** **Manage Filtering**, which deep-links to Settings › Apps › Messages [doc].

### Settings, "Unknown Senders" section [visual + doc]
- **Screen Unknown Senders** toggle: "Hide notifications and move messages to the Unknown Senders list."
- **Allow Notifications ›** (categories such as Time Sensitive and verification codes). This sets which screened items may still alert you.
- **Text Message Filter ›** (None / third-party filtering extension).
- **Filter Spam** toggle: "Hide notifications and move messages to the Spam list." On by default [doc MacRumors].
- Filters never apply to a sender you've replied to **three or more times** [doc].

### Screening flow inside a conversation
- Unknown-sender transcripts end with a centered footnote: *"If you did not expect this message from an unknown sender, it may be spam."*
- Below it sit two equal-width capsule buttons: **Delete** (red text) and **Mark as Known** (blue text).
- The newsroom also describes "ask for more information" [doc].
- Until marked known, the sender stays silenced and links don't open [doc].

**Spam behaviour.** No notification, no badge. Recover with "Not Spam" [doc MacRumors].

### Mac keyboard shortcuts for filters [doc]
| Shortcut | View |
|---|---|
| ⌃⌘1 | All |
| ⌃⌘2 | Known |
| ⌃⌘3 | Unknown |
| ⌃⌘4 | Unread |
| ⌃⌘5 | Recently Deleted |

### How Comms should extend this natively (recommendation)
- Keep Apple's two-tier model:
  - **Folders (mutually exclusive):** Inbox, Unknown, Transactions, Promotions, Spam, Recently Deleted.
  - **"Filter By" toggles (stackable):** Unread, plus the new ones: **Urgency** (Urgent / Needs reply / FYI), **Network** (iMessage, WhatsApp, Signal, Telegram, Slack, Email… as a submenu with app glyphs, like the Transactions ›), and **Contact / Group** (a submenu of favourites, or "Choose…").
- Mirror Apple's affordances:
  - The Filter glass button gets a **blue tint whenever any Filter By toggle is on**.
  - Show a **numeric badge** for new items in non-inbox folders.
  - Show **"N New" subtitles** on rows.
  - When filtered, show a dismissible filter capsule above the list. Apple has no such capsule, so keep it subtle. Optionally, render active filters as **search tokens** (see Search), which is Apple-native.
- Mac: extend ⌃⌘1–5 with ⌃⌘6–9 for Urgent and per-network views.

---

## 5. iPhone: Conversation Transcript

Reference images: `ios26-newsroom-polls.jpg`, `ios26-guide-transcript-1to1-add-button.png`, `ios26-guide-reply-threads.png`, `ios26-guide-inline-reply-mention.png`, `ios26-guide-tapback-picker.png`, `ios26-guide-sms-transcript-audio-photo-tapback.png`, `ios26-guide-audio-transcription-photos.png`, `ios26-9to5-typing-indicator-group.jpg`, `ios26-mr-select-copy.jpg`, `ios26-guide-edit-message.png`, `ios26-newsroom-photo-background.jpg`, `ios26-newsroom-live-translation-transcript.jpg`.

### Header (new in iOS 26)
- No opaque navigation bar. The transcript scrolls under a soft edge effect.
- **Back:** 44 pt glass circle, top-left [meas ≈ 42–44 pt].
- **FaceTime:** a video glass circle, top-right.
- **Center:** a large avatar (≈ 56–60 pt [meas: 105 px ÷ 1.741 = 60 pt; 68 px ÷ 1.107 = 61 pt]) that *overlaps* a **glass name pill** below it. The pill shows the name or group name in 17 pt semibold plus a small `›` chevron. Tapping it opens Details.
- With a conversation background, the pill and circles take on a tint drawn from the background [visual].

### Bubbles

| Property | Value | Label |
|---|---|---|
| Body font | 17 pt Regular (Dynamic Type Body), line height 22 | [doc + meas: a 2-line bubble is 61 pt, a 1-line bubble is 40 pt, so each line adds 21–22] |
| Single-line bubble height | ≈ 38–40 pt | [meas] 70 px ÷ 1.741 = 40; 120 px ÷ 3.13 = 38 (device) |
| Vertical padding | ≈ 8–9 pt top and bottom | [meas-derived] |
| Horizontal padding | ≈ 13–14 pt leading and trailing | [meas] text inset 23–24 px ÷ 1.741 |
| Corner radius | ≈ 18–20 pt. Single-line bubbles read as near-capsules, multi-line as large-radius rects | [est] |
| Tail | Classic curled "comma" tail at the bottom-outer corner. It extends ≈ 5–6 pt outward and ≈ 4 pt below the baseline. Shown **only on the last bubble of a consecutive run** from the same sender | [visual: polls, where "I'm free…" has no tail and "Been a busy year" does] |
| Max bubble width | ≈ 70–75% of the transcript width. Observed widest: 251 pt (62%) incoming with avatar; 280 pt (70%) outgoing on a 402 pt screen | [meas] |
| Side margins | ≈ 16 pt from the screen edge to the outgoing bubble's right edge and to the incoming avatar's left edge | [meas] 28 px ÷ 1.741 |
| Gap, same-sender consecutive bubbles | ≈ 3–5 pt | [meas] 8–9 px ÷ 1.741 |
| Gap, sender change (1:1) | ≈ 10–14 pt | [est] |
| Gap, sender change (group) | ≈ 33 pt, including the sender-name label | [meas] 58 px ÷ 1.741 |
| Group sender name | Caption ≈ 12 pt secondary, above the first bubble of a run, aligned with the bubble's text inset | [visual] |
| Group avatar | ≈ 30 pt circle, bottom-aligned with the **last** bubble of the run; ≈ 8–9 pt gap to the bubble | [meas] 52 px ÷ 1.741 |
| Emoji-only messages | Up to ~3 emoji render "jumbo" (~48 pt+) with no bubble | [visual: 😂 in SMS image] |
| Links / rich previews | Rounded card in the bubble shape: image top, title (semibold) and domain below. Music and Freeform cards use a 56–60 pt thumbnail, title, subtitle, and a trailing action (play / collaborators) | [visual] |
| Photos | Rounded-rect media bubble (≈ 18 pt radius) with a tail. **Multiple photos stack as a fanned deck** with a "▦ 5 Photos" caption link above; tap to expand to a grid. A trailing glass **save (↓)** circle sits beside the media | [visual + doc] |
| Audio message | Bubble with a play circle, waveform, and duration "00:07". **Transcription text appears under the waveform inside the same bubble**. Under it: "Delivered · **Keep**" (audio expires) | [visual] |
| Polls | Outgoing poll: each choice is its own capsule row (≈ 44–48 pt tall). The leading choice is filled orange; others are 15% orange tint. Voter avatars stack at the trailing end with an empty radio circle. An "Add Choice" link (orange caption) sits below. Up to 12 choices, and anyone can add one | [visual + doc MacRumors] |

### Status and timestamps
- **Receipts** appear under the **last outgoing bubble only**, right-aligned, Caption ≈ 11–12 pt secondary: "Delivered", "Read", or "**Read** 3:06 PM" (bold word, regular time) [meas + doc]. "Edited" appears as a blue tappable link next to Delivered. "Not Delivered" shows a red `!` [est].
- **Centered time headers:** Caption secondary, with the day word **semibold** and the time regular. Examples: "**Today** 8:17 AM", "**Yesterday** 5:55 PM", "**Thursday** 8:24 PM", "**Fri, Jun 13** at 3:30 PM" (older items add "at") [visual].
  - **Grouping rule [est]:** a header is inserted when the gap since the previous message passes a threshold (observed ≈ 15 min to 1 h). The first message of a day always gets one.
  - Exact threshold undocumented. Recommend 60 min, tuned by eye.
- **System events** use the same centered caption style: "Olivia Rico added Po-Chun Yeh to the conversation.", "You changed the background.", "You unsent a message", "Melody Cheung named the conversation…" Actor names are semibold [visual].
- **Per-message timestamps:** "Drag the message bubble to the left to see timestamps for all messages." The whole transcript slides left and reveals right-aligned times [doc].

### Typing indicator
- A gray bubble ≈ 55 × 33 pt containing three ≈ 8 pt dots that pulse in sequence (opacity and scale wave, ~1.2 s loop [est]).
- The tail is a **thought-bubble pair of small circles** at the bottom-leading corner rather than the curled tail [meas + visual].
- **New in iOS 26:** typing indicators also appear **in group chats** [doc Newsroom/MacRumors]. In groups it sits with the typer's avatar [est].

### Tapbacks / reactions
- Shown as small circular badges (≈ 28–32 pt) at the **top-outer corner** of the bubble, with a thought-bubble tail (two tiny dots) pointing at it.
- Mine are **blue-filled**; others' are gray/glass.
- Several reactions **stack** horizontally and overlap [visual].
- iOS 18+ supports any emoji, Memoji, or sticker as a Tapback (classic set: ❤️ 👍 👎 HAHA ‼️ ❓) [doc].
- **Picker:** double-tap or touch-and-hold. The transcript dims and blurs. The bubble lifts. A **horizontal glass capsule bar** of reactions appears above the bubble, with a trailing emoji/plus button and swipe-for-more.
- **Attribution:** tapping a stack shows senders in a glass card at the top of the screen, as reaction bubbles with avatars below [visual: `ios26-guide-tapback-picker.png`; doc].
- **One Tapback per person per message.** Tap the same one again to remove it [doc].

### Long-press menu
Below the lifted bubble: **Reply, Copy, Translate, Select** (new in 26: partial text selection), **Undo Send / Edit** (own messages), and **More…**, which leads to multi-select delete/forward [doc + MacRumors]. A Pin option exists for links and collab items [doc].

### Replies / threads
- **Swipe right on a bubble** (or long-press › Reply) to start an inline reply [doc].
- **Focus mode:** the rest of the transcript blurs. The header shows a ✕ close glass circle. Only the thread is crisp [visual: `ios26-guide-inline-reply-mention.png`].
- **In the main transcript**, a thread is drawn as a **thin rounded "bracket" connector line** (light gray, ≈ 2 pt, rounded corners). It runs down the leading side from the parent to its replies. The parent shows a blue footnote "**N Replies**" link below it [visual: `ios26-guide-reply-threads.png`, `macos26-guide-reply-thread.png`].
- When the parent is far up, a quoted miniature parent appears as an **outline bubble** (hairline blue stroke, blue small text) above the reply [visual Mac].

### Mentions
- Typing a name turns it **bold** in the composer and in the delivered bubble ("**Danny** Your mention…") [doc + visual].

### Edit / Unsend [doc]
- **Unsend** is allowed within 2 minutes. Both sides see "You unsent a message".
- **Edit** is allowed up to 5 times within 15 minutes, and adds an "Edited" link.
- **Edit UI:** the rest of the transcript dims to ~40%. The bubble becomes an editable white field with an ✕ glass circle on the left and a **blue checkmark circle** on the right [visual].

### Send-later
- Scheduled bubbles render with a **dashed blue outline** and no fill.
- A centered caption reads "Send Later · Thu, Apr 10 at 7:00 AM **Edit**".
- The composer shows a dashed capsule chip "🕘 Thu, Apr 10 at 7:00 AM ›" with ✕, and a **wheel date picker** in a glass sheet [visual + doc].

### Other bits
- **Catch-up button:** a "jump to first unread" arrow when opening an unread conversation [doc].
- **Translation:** each bubble shows the original in small secondary text, a hairline divider, then the translation in body. A blue **"Translating Spanish ⌃⌄"** glass chip sits centered above the composer [visual: live-translation].

---

## 6. iPhone: Composer and `+` menu

Reference images: `ios26-9to5-typing-indicator-group.jpg`, `ios26-guide-plus-menu.png`, `ios26-mr-poll-suggestions.jpg`, `ios26-guide-send-later.png`, `ios26-newsroom-live-translation-transcript.jpg`.

### Layout
- Floating, with no bar background.
- **`+` glass circle** (≈ 38–40 pt) on the left, ≈ 10–12 pt gap, then the **message capsule** (≈ 38–40 pt tall, full radius) [meas: 118–120 px ÷ 3.13].
- Placeholder shows the transport: "iMessage", "Text Message • SMS", or "Add comment or Send" when a poll or attachment is staged [visual].
- The trailing glyph is a **mic** when empty and becomes a **blue ↑ send circle** (≈ 30 pt, inside the capsule) once text exists [visual].
- **Mac** keeps a separate trailing **emoji** glass circle outside the capsule [visual].
- The composer grows vertically up to ~5 lines, then scrolls [est].
- The keyboard is the iOS 26 glass keyboard with a rounded top. The QuickType bar holds predictions **and Apple Intelligence suggestions** [visual].

### `+` menu
- A tall glass panel morphs up from the `+` button, covering the lower-left two-thirds.
- **Rows:** a 36 pt colored app-icon circle plus a 20 pt label.
- **Order on iOS (guide):** Camera, Photos, Stickers, Cash, Audio, Store, #images, Check In, Digital Touch, Location, Memoji, Polls, Send Later, Genmoji, Image Playground… with "More" scrolling [visual + doc].
- **Order on Mac:** Photos, Stickers, Send Later, Genmoji, Image Playground, #images, Message Effects, Polls [visual `macos26-9to5-plus-menu-polls-composer.jpg`].
- Users can reorder by dragging [est from iOS 17+].

### Formatting
- Selecting text shows **B / I / U / S** plus text effects (Big, Small, Shake, Nod, Explode, Ripple, Bloom, Jitter) in a keyboard-replacement panel [doc].

### Apple Intelligence surfaces in the composer [doc]
- **Smart Reply:** "Tap the text field, then tap a suggested reply above the keyboard. Apple Intelligence drafts the reply in the text field." Writing Tools can refine it.
- **Suggested poll:** rendered in the **QuickType bar** as a gradient-colored "≡ Create Poll / Accommodation Ideas" pill (Apple Intelligence rainbow-gradient text) [visual: `ios26-mr-poll-suggestions.jpg`].

---

## 7. iPhone: Search

Reference images: `ios26-guide-search-suggestions.png`, `ios26-guide-search-results-token.png`.

### Entry
- The bottom search capsule expands. The Compose circle turns into a **✕ close glass circle**. The keyboard rises with the field docked above it [visual + HIG "animates into a search field above the keyboard"].

### Suggestions (before submitting)
- **Conversations** section (Title3 bold header, blue "See All") with a horizontal row of ≈ 70 pt avatars.
- Below it, rows of **scope suggestions**: "👤 Messages with: Dawn Ramirez" / "👥 Messages in: Foodie Friends" [visual + doc].

### Results
- **Sections:** Conversations, Messages, Photos, Links, Locations…
- **Message hits** render as *real bubbles*: conversation name in bold caption, sender in secondary, time at trailing, and a chevron. The matched term is highlighted.
- **Photos:** a 2-column grid with sender avatar overlays.

### Tokens
- Choosing "Messages with" or typing "Photo"/"Link"/"Wallet" converts the term into a **search token chip** inside the field (gray chip with person or photo glyph) [doc + visual].
- On Mac, tokens and a **scope segmented control** (All / Photos / Screenshots) appear [visual `macos26-guide-search-results.png`].
- HIG: "Tokens can… focus a search to a specific set of attributes, like filtering by photos in Messages" [doc].

### Natural-language search
- Apple Intelligence devices support conversational queries [doc 9to5Mac/MacRumors].
- **Comms:** this is the native slot for network, urgency, and contact tokens (e.g. `[WhatsApp] [Urgent] invoice`).

---

## 8. iPhone: Conversation Details, Backgrounds, New Message

### Details
- Reached by tapping the avatar/name pill. Opens as a full sheet over a **blurred** transcript [visual: `ios26-guide-group-details.png`].
- **Layout:**
  - ‹ back circle and **Edit** capsule.
  - Large ≈ 90 pt avatar and Title1-bold name.
  - Three 60 pt glass circles: call, video, mail.
  - A **segmented glass tab strip: Info · Backgrounds · Photos.** iOS 18 had a long scroll with Photos/Links sections; iOS 26 tabs these [visual].
- **Info tab:**
  - Member avatar grid (3 columns, ≈ 90 pt) with "+ Add".
  - Grouped inset glass/material cards: Hide Alerts toggle, Show in Shared with You toggle.
  - Destructive "Leave this Conversation".
  - "Turn On Contact Key Verification".
  - Share My Location (Mac) [visual].
  - Automatically Translate lives here too [doc MacRumors].
- **Backgrounds tab:** circular swatches (None, Photo, Color, Sky, Water, Aurora, Playground) and a **Suggestions** grid of portrait tiles [visual: `macos26-guide-background.png`].
  - Backgrounds sync to all participants (iMessage only). Users can disable others' backgrounds in Settings.
  - Bubble colors don't change [doc MacRumors].
  - **With a background:** incoming bubbles become **translucent tinted material** sampled from the background (e.g. dark-amber over a sunset, dark-slate over night photos, teal-gray over sky). Outgoing stays blue. Sender names and timestamps switch to white [visual].

### New Message
- Compose button. Morphs into a sheet with a "To:" token field (+ contact button) and the conversation composer below [doc].
- Recipients become blue/green tokens depending on reachability (classic behaviour [est]).

---

## 9. macOS Tahoe: Window, Sidebar, Transcript, Inspector

Reference images: `macos26-newsroom-window-pinned-background.jpg`, `macos26-guide-window-sidebar-transcript.png`, `macos26-guide-reply-thread.png`, `macos26-guide-group-info-view.png`, `macos26-guide-background.png`, `macos26-guide-search-results.png`, `macos26-guide-text-effects-menu.png`, `macos26-9to5-filter-menu-unread.jpg`, `macos26-9to5-plus-menu-polls-composer.jpg`.

### Window
- No visible title bar. Traffic lights sit *inside* the floating sidebar's top-left.
- The window has large concentric corners [visual].
- The transcript extends under the sidebar edge. The sidebar is an **inset, floating Liquid Glass panel** (≈ 8 pt inset from the window edges) with its own rounded corners [doc WWDC25: "Sidebars are now inset and built with Liquid Glass"; visual].

### Sidebar (estimated in pt, from a guide image that is roughly 1×)
| Element | Value |
|---|---|
| Width | ≈ 260–320 pt, user-resizable |
| Top row | Traffic lights, then the **Filter** button (`line.3.horizontal.decrease`, plain, top-right of the sidebar) |
| Search field | Full-width rounded field "Search", ≈ 28–32 pt tall |
| Pinned grid | 3 columns, ≈ 58–60 pt avatars, names in 11 pt secondary, unread blue dots before names, last-message "bubble" popovers on avatars. **Selected pin = blue rounded-rect tile** behind the avatar |
| Rows | ≈ 64 pt tall; 40 pt avatar; name 13 pt bold; time 11 pt secondary right-aligned; 2-line 11–12 pt preview |
| Selected row | **Filled accent-blue rounded rect** (#0088FF, ≈ 10 pt radius) inset inside the sidebar, with white text [meas color] |
| Unread | Blue dot in the leading gutter |

### Transcript toolbar
- **Compose** (`square.and.pencil`) glass circle at the transcript's top-left.
- Centered avatar plus name pill (same as iOS).
- **FaceTime** video glass circle at the top-right.
- When the sidebar is collapsed, **Filter and Compose move into the transcript toolbar** next to the traffic lights [visual: `macos26-guide-background.png`].
- Toolbar circles ≈ 30–32 pt [est].

### Bubbles on Mac
- Same shapes and tails.
- Body ≈ 13 pt (scalable with ⌘+/−).
- Single-line bubble ≈ 26–28 pt tall.
- Group avatars ≈ 24–28 pt.
- Max width is wider, ≈ 60–65% of the transcript, giving long single lines [visual].

### Composer on Mac
- `+` glass circle, capsule field ("iMessage", trailing dictation waveform glyph), and a **separate trailing emoji glass circle**.
- Return sends; ⌥/⇧-Return adds a newline [doc].

### Inspector (Details)
- ⌥⌘I or click the name pill.
- A **right-side glass inspector panel** slides in over a narrowed transcript. Its header has ✕ and **Edit**.
- Content matches iOS: avatar, name, call/video/mail circles, Info · Backgrounds · Photos tabs [visual: `macos26-guide-group-info-view.png`, `macos26-guide-background.png`].
- SwiftUI equivalent: `.inspector(isPresented:)` [doc WWDC25 323].

### Menus
- Context menus are standard macOS 26 menus with **leading icons on every item**, which is new for Mac in 26 [doc WWDC25 323].
- The message-field context menu has a top **B I U S** row, a "Text Effects ›" submenu, Look Up / Translate / Search, Cut / Copy / Paste, Share…, and Spelling / Substitutions / Transformations / Speech, AutoFill, Services [visual].
- The Filter menu uses the same items as iOS, plus a "**Filter By** › Unread" header section [visual].

### Menu bar
Messages · File · Edit · View · Conversation · Format · Window · Help [visual newsroom].

### Keyboard shortcuts [doc, full list]
| Shortcut | Action |
|---|---|
| ⌘N | New message |
| ⌘F | Search |
| ⌘1–9 | Go to pinned conversation |
| ⌥⌘1 | First unpinned conversation |
| ⌃Tab / ⌃⇧Tab | Next / previous conversation |
| ⌘R | Reply to last or selected incoming message |
| ⌘T then 1–6 | Tapback |
| ⌘E | Edit last sent message |
| ⌥⌘I | Info |
| ⌥⌘M | Hide alerts |
| ⇧⌘U | Mark read / unread |
| ⌥⌘B | Contact card |
| ⌘+ / ⌘− | Text size |
| ⌃⌘1–5 | Filters |
| Space | Quick Look |
| Delete | Delete selected message |
| ⌃⌘F | Full screen |
| ⌃⌘Space | Emoji |

---

## 10. Animations and Gestures Summary

| Interaction | Behaviour | Label |
|---|---|---|
| Send | New bubble rises from the composer and lands at the bottom of the transcript. The composer text appears to "fly" into it; the list scrolls to the bottom. Spring ≈ 0.35–0.4 s, slight overshoot | [est, classic iMessage] |
| Receive | Bubble fades and scales in from the bottom; typing indicator is replaced in place | [est] |
| Tapback | Bubble lifts with a scale ~1.03 and shadow. Background blurs and dims. Reaction bar morphs out (glass). The chosen emoji pops onto the bubble corner with a bounce | [visual + est] |
| Menus and sheets | Glass morph out of the source control (zoom transition) | [doc] |
| Toolbar glass | Interactive glass scales, bounces, and shimmers on touch | [doc WWDC25 323 `.interactive()`] |
| Scroll-to-bottom | When scrolled up, a round glass ↓ button appears above the composer. The catch-up button jumps to the first unread | [doc catch-up; est for ↓] |
| Swipe bubble left | Reveals per-message timestamps; springs back on release | [doc] |
| Swipe bubble right | Inline reply | [doc] |
| Swipe row right / left | Read-Unread (and Pin) / Hide Alerts and Delete | [doc + est] |
| Long-press row | Context menu with a live transcript preview | [doc] |
| Pinned reorder | Drag pins; drag a pin down to unpin | [doc] |
| Expressive effects | Bubble effects (Slam, Loud, Gentle, Invisible Ink), screen effects, and per-word text effects (Big, Shake, Nod, Explode, Ripple, Bloom, Jitter) | [doc] |

---

## 11. Where an "Omni" tag-in assistant fits natively

Apple already has five native AI insertion points. Comms should use the same slots rather than invent chrome.

1. **QuickType / suggestion bar above the keyboard** (iOS):
   - Smart Reply drafts and "Create Poll" already live here, styled as rainbow-gradient Apple Intelligence text [doc + visual].
   - **Omni slot:** "✦ Draft with Omni" plus 1–2 one-tap draft chips.
   - Tapping inserts the draft *into the composer* for editing, which matches Apple's "drafts the reply in the text field" behaviour.
   - Never auto-send. This also matches the owner's approval-gated send rule.
2. **`+` menu row:**
   - Add **"Omni"** as a first-class row (a colored glyph circle like Genmoji / Image Playground). It opens a compact glass panel: "Draft reply", "Summarize thread", "Find a time", "Translate tone".
   - On Mac, the same row goes in the `+` popover. Bind **⌘⇧O** (unused by Messages).
3. **@-mention in the composer:**
   - Apple's mention model bolds a participant's name.
   - Typing **"@Omni"** should produce the same bold mention token, styled in the AI gradient. The intent is "tag-in". Omni's response appears as a **draft bubble** with the Send-Later-style **dashed outline** (Apple's existing "not yet sent" visual language), plus Send / Edit / Discard.
4. **List preview summaries:**
   - Apple Intelligence replaces the preview with a summary of unread messages [doc].
   - Comms can add an urgency glyph (e.g. a red `exclamationmark.circle` or "Needs reply" capsule) in the same trailing area Apple uses for the "Time Sensitive" capsule [visual]. This is the native precedent for an inline status tag on a row.
5. **Inline transcript affordances:**
   - The Translation chip above the composer ("Translating Spanish ⌃⌄") is a precedent for a persistent, centered glass status chip.
   - Use it for "Omni is drafting…" / "Omni watching this thread".
   - The centered system-event caption style ("You changed the background.") suits Omni activity logs ("Omni drafted a reply").

Visual identity for Omni:
- Reuse Apple's AI convention (multicolor gradient text or glyph) only if it won't be confused with Apple Intelligence.
- Otherwise use a single tinted glass (`.glassEffect(.regular.tint(...))`). HIG reserves tint for meaning, so keep it to Omni-originated elements.

---

## 12. Changes in iOS 26 vs iOS 18 (Messages)

| Area | iOS 18 | iOS 26 |
|---|---|---|
| List title | Large title | Inline title |
| Compose button | Top-right | Bottom-right glass circle |
| Search | Pull-down search at the top | Floating bottom search capsule |
| Filters | Menu at top-left ("Filters" text) | Top-right Filter glass button with badge |
| Filter folders | — | Unknown Senders split from Spam; Transactions / Promotions folders; "N New" subtitles |
| Unknown-sender screening | — | Silenced folder, Mark as Known / Delete, Allow Notifications categories |
| Transcript header | Opaque nav bar | Floating glass circles plus overlapping avatar and name pill; content scrolls under it |
| Composer | Inside a bar | Floating `+` circle and capsule; mic replaces audio glyph; Mac adds an emoji circle |
| Backgrounds | — | Per-conversation, synced to participants: color, photo, presets, Image Playground |
| Polls | — | Polls, plus AI poll suggestions |
| Group chats | — | Typing indicators, Apple Cash, one-tap "add to contacts" for unknown members |
| Text selection | — | Select part of a message (long-press › Select) |
| Translation | — | Live Translation (Apple Intelligence) |
| Search | — | Natural-language search (Apple Intelligence) |
| Details | Long scroll | Info / Backgrounds / Photos tabs |
| Mac | — | Inset glass sidebar; inspector panel; menu icons |

Sources: [Apple Newsroom iOS 26](https://www.apple.com/newsroom/2025/06/apple-elevates-the-iphone-experience-with-ios-26/), [MacRumors guide](https://www.macrumors.com/guide/ios-26-messages-app/), [9to5Mac](https://9to5mac.com/2025/09/17/heres-everything-new-in-the-messages-app-with-ios-26/), [MacRumors screening how-to](https://www.macrumors.com/how-to/ios-screen-unknown-senders-messages/), plus visual comparison.

---

## 13. Measurement Table

| # | Item | Value | Label |
|---|---|---|---|
| 1 | iOS list row height | 88–90 pt | meas |
| 2 | iOS list avatar | ~45 pt | meas |
| 3 | iOS pinned avatar | 90–96 pt | meas |
| 4 | iOS unread dot | ~10 pt | est |
| 5 | iOS bottom search capsule height | ~48 pt | meas (53 px ÷ 1.107; 55 ÷ 1.115) |
| 6 | iOS compose / filter / back circles | 44–48 pt | meas |
| 7 | iOS header avatar (transcript) | 56–60 pt | meas |
| 8 | Single-line bubble height (iOS) | 38–40 pt | meas |
| 9 | Additional line height | 21–22 pt | meas/doc (Body 17/22) |
| 10 | Bubble padding H / V | 13–14 / 8–9 pt | meas-derived |
| 11 | Bubble corner radius | 18–20 pt | est |
| 12 | Bubble max width | 70–75% of transcript width | meas (observed 62–70%) |
| 13 | Screen-edge margin | ~16 pt | meas |
| 14 | Same-sender bubble gap | 3–5 pt | meas |
| 15 | Group sender-change gap (incl. name) | ~33 pt | meas |
| 16 | Group avatar | ~30 pt | meas |
| 17 | Typing bubble | ~55 × 33 pt; dots ~8 pt | meas |
| 18 | Composer capsule / `+` circle | 38–40 pt | meas |
| 19 | Tapback badge | 28–32 pt | est |
| 20 | Poll choice row | 44–48 pt | est |
| 21 | Body / subhead / footnote / caption (iOS) | 17 / 15 / 13 / 12 pt | doc |
| 22 | Mac body / headline / subhead / caption | 13 / 13 bold / 11 / 10 pt | doc |
| 23 | Mac sidebar width | 260–320 pt (resizable) | est |
| 24 | Mac row height / avatar | ~64 / ~40 pt | est (guide ~1×) |
| 25 | Mac pinned avatar | 58–60 pt | est |
| 26 | Mac single-line bubble | 26–28 pt | est |
| 27 | Mac toolbar circles | 30–32 pt | est |
| 28 | Split-view divider | 1 pt thin | doc (HIG Split views) |
| 29 | Incoming bubble color | #E9E9EB / dark ≈ #262628 | meas |
| 30 | Outgoing iMessage blue | ≈ #37AAFC → #2AA0FD screen-position gradient (iOS); ≈ #1896FE (Mac) | meas |
| 31 | Accent / selection blue | #0088FF | meas (matches HIG 26) |
| 32 | Max pins | 9 | doc |
| 33 | Unsend / edit windows | 2 min / 15 min, max 5 edits | doc |
| 34 | Poll choices | up to 12 | doc (MacRumors) |
| 35 | Clear-glass dimming layer | 35% black | doc |
| 36 | Timestamp-header gap threshold | ~15–60 min | est |

---

## 14. Image Files

All files are in `refs/`.

| File | Shows |
|---|---|
| ios26-guide-conversation-list-compose-unread.png | iOS 26 list (Apple guide): Edit / inline title / Filter, unread blue dot, rows with chevrons, bottom Search + Compose |
| ios26-guide-list-unread-swipe.png | Swipe-right action: blue circular Mark Unread button, row lifted into a rounded card |
| ios26-guide-list-filter-menu.png | Filter menu over pinned grid: Messages ✓, Unknown Senders "1 New", Spam, Recently Deleted, Manage Filtering; badge on filter button |
| ios26-9to5-screening-spam.jpg | Light list header: Edit, "Messages", filter button with "2" badge, pinned avatars, unknown row with "Time Sensitive" capsule |
| ios26-mr-filter-menu.jpg | Dark filter menu with Transactions and Promotions |
| ios26-mr-filtering.jpg | Light filter menu; Transactions has a › submenu |
| ios26-mr-screening-settings.jpg | Three device shots: dark list, minimal filter menu, Settings › Unknown Senders (Screen Unknown Senders, Allow Notifications, Text Message Filter, Filter Spam) |
| ios26-mr-unknown-mark-known.jpg | Unknown-sender transcript footer: spam warning + Delete / Mark as Known buttons (dark) |
| macos26-9to5-filter-menu-unread.jpg | Mac filter menu with "Filter By › Unread" section, sidebar search, pinned avatars |
| ios26-guide-transcript-1to1-add-button.png | 1:1 transcript: glass back circle, avatar+name pill, tapbacks, "Today 8:17 AM" header, fanned "5 Photos" stack, save button, "Text Message • SMS" composer |
| ios26-newsroom-polls.jpg | Group transcript: sender names, 30 pt avatars, tail-on-last-bubble grouping, poll bubbles, Add Choice, `+` / capsule composer |
| ios26-guide-reply-threads.png | Thread connector brackets and "N Replies" links in a group transcript |
| ios26-guide-inline-reply-mention.png | Inline-reply focus mode (blurred background, ✕), bold @mention, stacked tapbacks, "Read" receipt |
| ios26-guide-tapback-picker.png | Tapback glass bar, attribution card at top, dimmed transcript |
| ios26-guide-sms-transcript-audio-photo-tapback.png | Gray audio bubble ("Raise to talk"), photo bubble with tail, emoji tapback, jumbo emoji, "Text Message • SMS" timestamp caption |
| ios26-guide-audio-transcription-photos.png | Outgoing audio bubble with inline transcription, "Delivered · Keep", stacked photos |
| ios26-9to5-typing-indicator-group.jpg | Real-device typing indicator, "Read 3:06 PM", composer, keyboard |
| ios26-mr-select-copy.jpg | Partial-text Select on a bubble, centered system captions ("You unsent a message", "You changed the background."), "Delivered", dark-aurora background |
| ios26-guide-edit-message.png | Edit mode: dimmed transcript, ✕ and blue ✓ circles, "Delivered • Edited" |
| ios26-guide-send-later.png | Dashed scheduled bubbles, Send Later caption, composer time chip, wheel picker |
| ios26-guide-plus-menu.png | `+` app menu glass panel (Audio, Store, #images, Check In, Digital Touch, Location, Memoji) |
| ios26-mr-poll-suggestions.jpg | Apple Intelligence "Create Poll" suggestion in the QuickType bar |
| ios26-newsroom-live-translation-transcript.jpg | Translated bubbles (original + translation) and the "Translating Spanish" chip |
| ios26-newsroom-custom-background.jpg | Sky background, tinted incoming bubbles, Apple Music card, image card, tapback, Delivered |
| ios26-newsroom-photo-background.jpg | Dark photo background, voice message bubble, day/time headers, jumbo emoji |
| ios26-guide-search-suggestions.png | Search: Conversations avatars row, "Messages with / in" scope suggestions, message hits as bubbles, bottom field + ✕ |
| ios26-guide-search-results-token.png | Search with a person token, Messages + Photos grid sections |
| ios26-guide-group-details.png | Details: avatar, name, call / video / mail, Info · Backgrounds · Photos tabs, member grid, toggles |
| macos26-newsroom-window-pinned-background.jpg | Tahoe Messages window: menu bar, inset glass sidebar, pinned row, selected row, transcript with background |
| macos26-guide-window-sidebar-transcript.png | Mac window (light): sidebar with 3×3 pinned grid, selected pin tile, rows, compose / video circles, composer with emoji circle |
| macos26-guide-reply-thread.png | Mac thread connectors, outline quoted-parent bubble, N Replies |
| macos26-guide-group-info-view.png | Mac inspector header: ✕, Edit, avatar, actions, Info / Backgrounds / Photos |
| macos26-guide-background.png | Mac with sidebar collapsed (filter + compose in toolbar), background inspector with swatches and suggestions |
| macos26-guide-search-results.png | Mac sidebar search with "Photo" token and All / Photos / Screenshots scope |
| macos26-guide-text-effects-menu.png | Mac context menu on composer text: B I U S row, Text Effects submenu, leading icons |
| macos26-9to5-plus-menu-polls-composer.jpg | Mac `+` popover (Photos … Polls) and poll composer card ("Add comment or Send") |

Removed during review as irrelevant or duplicate: Phone call-screening render, two app-icon images, a settings crop, the Liquid Glass device hero, duplicate background composites, the Apple Cash sheet, and a duplicate Mac send-later image.

---

## 15. Sources

- Apple Newsroom: [iOS 26](https://www.apple.com/newsroom/2025/06/apple-elevates-the-iphone-experience-with-ios-26/), [macOS Tahoe 26](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/), [New software design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/).
- iPhone User Guide (iOS 26), Messages chapters:
  - [Send and reply](https://support.apple.com/guide/iphone/iph82fb73ba3/26/ios/26)
  - [Keep track](https://support.apple.com/guide/iphone/iphe9b48b89e/26/ios/26)
  - [Tapbacks](https://support.apple.com/guide/iphone/iph018d3c336/26/ios/26)
  - [Unsend/edit](https://support.apple.com/guide/iphone/iphe67195653/26/ios/26)
  - [Screen and filter](https://support.apple.com/guide/iphone/iph203ab0be4/26/ios/26)
  - [Search](https://support.apple.com/guide/iphone/iph17c111fb6/26/ios/26)
  - [Apple Intelligence in Messages](https://support.apple.com/guide/iphone/iph64709c5c3/26/ios/26)
  - [Group conversations](https://support.apple.com/guide/iphone/iphb10c80fc5/26/ios/26)
  - [Send later](https://support.apple.com/guide/iphone/iph5ae9a7be6/26/ios/26)
  - [Audio](https://support.apple.com/guide/iphone/iph2e42d3117/26/ios/26)
  - [View conversations from unknown senders (125068)](https://support.apple.com/125068)
- Messages User Guide for Mac (26):
  - [Keyboard shortcuts](https://support.apple.com/guide/messages/ichtc78b3bff/mac)
  - [Send messages](https://support.apple.com/guide/messages/icht35827/26.0/mac/26)
  - [Search](https://support.apple.com/guide/messages/icht6d66aae3/26.0/mac/26)
  - [Manage group](https://support.apple.com/guide/messages/icht3268ad23/26.0/mac/26)
  - [Backgrounds](https://support.apple.com/guide/messages/icht80a80b42/26.0/mac/26)
  - [Format](https://support.apple.com/guide/messages/icht7316c157/26.0/mac/26)
- Apple HIG (fetched as JSON):
  - [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
  - [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
  - [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)
  - [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
  - [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
  - [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
  - [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
  - [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- WWDC25: [Get to know the new design system (356)](https://developer.apple.com/videos/play/wwdc2025/356/), [Build a SwiftUI app with the new design (323)](https://developer.apple.com/videos/play/wwdc2025/323/). "Meet Liquid Glass" (219) was not fetched separately; its key points are covered by HIG Materials.
- Press:
  - [MacRumors iOS 26 Messages guide](https://www.macrumors.com/guide/ios-26-messages-app/)
  - [MacRumors screening how-to](https://www.macrumors.com/how-to/ios-screen-unknown-senders-messages/)
  - [9to5Mac iOS 26 Messages](https://9to5mac.com/2025/09/17/heres-everything-new-in-the-messages-app-with-ios-26/)
  - [9to5Mac macOS Tahoe Messages](https://9to5mac.com/2025/07/13/macos-tahoe-26-all-the-new-features-in-messages/)
  - [9to5Mac group chat features](https://9to5mac.com/2026/01/12/ios-26s-messages-app-adds-five-great-new-group-chat-features/)
  - The MacStories review's Messages section could not be extracted (paginated, JS-heavy).
- Not obtained: the Apple Design Resources iOS 26 / macOS 26 Figma/Sketch UI kits (behind a download, not image-scrapable). **Recommended next step:** download the iOS 26 and macOS 26 kits from developer.apple.com/design/resources to replace the [est] values with exact component specs, and take device screenshots with Accessibility Inspector / Xcode view debugger to calibrate bubble radius, tail path, and spacing.
