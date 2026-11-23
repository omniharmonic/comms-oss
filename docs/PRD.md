# Comms — Product Requirements

Status: approved by owner · 2026-11-21
Companion docs: [ARCHITECTURE.md](ARCHITECTURE.md) · [DECISIONS.md](DECISIONS.md) · research in [research/](research/)

## 1. What this is

Comms is the owner's personal messaging app for macOS and iOS. It looks and behaves like Apple Messages (iOS 26 / macOS 26 Tahoe, Liquid Glass), and it gathers **every** channel the owner talks on into one list:

- WhatsApp, Telegram, Discord, Messenger and X through the existing Matrix bridges
- iMessage and SMS through BlueBubbles
- email (Proton, later personal Gmail)

The owner can filter by urgency, network and contact, and can tag in **Omni** to draft a reply or handle a task the conversation creates.

Comms is part of the Prism / Omni ecosystem, the way Minutes is for transcription. It is a thin native client of the Prism server. All message logic lives in Prism, so the same improvements carry back into Prism's own messages UI (see ARCHITECTURE §10).

## 2. Why

In the owner's words, the current Prism messages view:

- "is messy with bad formatting"
- doesn't let them respond with emojis (no reactions)
- is missing their friends' profile pictures
- shows weird channel names, especially for email and sometimes WhatsApp

So the owner still opens WhatsApp, Signal, iMessage and Mail separately. The functionality exists in Prism and Omni, but it doesn't reach them in a usable form; this is the same "usability over utility" gap recorded for Omni in October.

Comms should make one beautiful, quiet app the place where all communication happens, with Omni one tap away.

### What success looks like
- The owner reaches for Comms instead of the native apps for WhatsApp, Telegram, iMessage and routine email.
- Put Comms next to Apple Messages on the same device and it reads as "the same design family". There are no uncanny differences in spacing, bubbles, glass or motion.
- Every conversation shows the right name and picture.
- Reactions, media and link previews work wherever the network supports them.
- Omni-drafted replies go out only after the owner approves the exact text, and it takes one tap plus Face ID / Touch ID.

## 3. Goals, non-goals, anti-goals

### Goals
1. Look like Apple Messages, close to pixel-perfect, on Mac and iPhone (iPad follows the iPhone/Mac adaptive layout).
2. One unified inbox across Matrix bridges, BlueBubbles and email, with correct names, avatars and previews.
3. A modern messaging feature set, wherever the source network supports it: media, reactions, replies, edits and unsends, link previews, typing indicators, read receipts, delivery states, and search.
4. Apple-native filtering, extended with Urgency, Network and Contact.
5. Omni tag-in: private instructions, a draft bubble back, and approve-exact-text to send. "Handle this" turns a conversation into tasks, calendar items or follow-ups through Omni's existing proposal kinds.
6. Fix the root causes in Prism, not only in this app, so Prism's UI can adopt the same API and design.

### Non-goals (v1)
- Voice and video calls, FaceTime.
- Creating polls, backgrounds, message effects, stickers, Genmoji, Image Playground.
- Sending iMessage tapbacks, typing or read receipts (needs the BlueBubbles Private API; see DECISIONS D6). Incoming tapbacks are shown.
- Being a Matrix client for arbitrary Matrix rooms or other users. It is owner-only and single-user.
- Android, web, Windows. Prism's web UI gets the improvements through the backfill (ARCHITECTURE §10).
- Offline-first sync with full local history. Comms caches, but Prism is the source.
- New bridges beyond BlueBubbles (Signal, Slack and LinkedIn are future candidates).

### Anti-goals (failure even if it "works")
- **Anything reaches another person without the owner's explicit action.** That means the owner typing and pressing Send, or the owner approving the exact text Omni drafted. No timer, model or notification action sends on its own.
- Omni posting into a chat where others can see it (Beeper's `@ChatGPT` pattern).
- Looking *almost* like Messages, with glass on bubbles, wrong radii, colored per-network bubbles or web-ish spacing.
- Losing or mangling message content: dropped lines, wrong sender, wrong time zone, swapped history.
- Merging two different people into one conversation.
- A second message store that drifts from Prism and the vault.

## 4. Users and context

One user: the owner. They run Prism on an always-on Mac Mini (Tailscale + `prism.example.com`), use a MacBook and an iPhone (and an iPad), and live with Omni (the agent) as an executive assistant. Their hard line is that nothing goes out on their behalf unless they approved that exact message.

## 5. Experience

The reference for every screen is [research/apple-messages-ux-spec.md](research/apple-messages-ux-spec.md) and its 36 screenshots in [research/refs/](research/refs/). Where this PRD says "as Messages", that spec is binding. Values marked `[est]` there must be calibrated (§9).

### 5.1 Visual language
- **Glass only on controls:** toolbars, the composer, menus, the Mac sidebar and inspector, floating buttons. Message bubbles are opaque.
- **Bubble colors (owner decision D4, amended 2026-11-21):**
  - **Outgoing bubbles use a shade of blue specific to each platform.** iMessage keeps Apple's blue with the screen-position gradient (≈ #37AAFC at the top to #2AA0FD at the bottom on iOS; ≈ #1896FE on Mac). WhatsApp, Telegram, Messenger, X, Discord, SMS and email each get their own distinct blue, all with the same gradient behaviour.
  - Every shade stays a bright, clean Apple-style blue: same lightness band as iMessage blue, high chroma, hue roughly 195–235°, white text at least as legible as on Apple's own iMessage blue (≥ 2.5:1). Neighbours are subtly but visibly distinct (ΔE ≥ 5). No navy, slate or grey-blue.
  - Incoming is Apple's grey #E9E9EB (dark ≈ #262628) on every network.
  - **No green bubbles, even for SMS.**
- **The network is shown by:** a small network badge at the bottom-right of the avatar in the list and on group sender avatars, the composer placeholder ("WhatsApp", "iMessage", "Text Message • SMS", "Email · you@…"), and the transcript timestamp caption ("WhatsApp · Today 9:31 AM").
- **Typography:** SF Pro with Dynamic Type on iOS (Body 17/22), and Mac sizes (Body 13, scalable with ⌘+/⌘−).
- **Omni identity:** a single tinted glass and a sparkle glyph, used only on Omni-originated elements. It must not imitate Apple Intelligence's rainbow gradient.

### 5.2 Conversation list (iPhone) / sidebar (Mac)
As Messages:
- inline title, Edit capsule and Filter circle at the top;
- pinned grid (up to 9, typing and last-message bubbles on pins);
- ≈ 89 pt rows with 45 pt avatars and a 2-line preview;
- unread blue dot;
- bottom floating Search capsule and Compose circle (iPhone);
- inset floating glass sidebar with an accent-blue selected row (Mac).

Comms additions:
- **Network badge** on each avatar. A merged person conversation shows the badge of the most recent message.
- **Urgency marker** in the trailing slot where Messages shows "Time Sensitive": a small capsule ("Urgent", "Needs reply") from Prism triage. FYI and low items show nothing.
- **Correct titles**, never slugs or raw IDs (§5.9).
- **Previews** render formatting stripped to plain text, with tapback previews ("Sam loved 'Dinner…'") and attachment labels ("📷 Photo", "Voice message 0:07").

Swipe actions and long-press menus follow Messages: read/unread and pin on the leading side, hide alerts and delete on the trailing side. Delete in Comms means **Archive** (hides the conversation locally and in Prism); it never deletes on the source network in v1.

### 5.3 Filters
Apple's two-tier menu, morphing out of the Filter button:
- **Folders (pick one):** Inbox · Unknown · Low priority · Spam · Archived.
  - "Unknown" means senders not linked to a person note and not replied to, the same model as Apple's Unknown Senders.
  - "Low priority" means items triaged `low` or labelled BULK/PROMOTIONS/AUTOMATED.
- **Filter By (stackable):**
  - Unread.
  - **Urgency ›** (Urgent · Needs reply · FYI).
  - **Network ›** (iMessage, SMS, WhatsApp, Telegram, Discord, Messenger, X, Email).
  - **Contact ›** (favourites, "Choose…").
- The Filter button tints blue when any Filter By toggle is on, and shows a numeric badge for new items in non-Inbox folders.
- Active filters also appear as search tokens.
- Mac shortcuts: ⌃⌘1–5 for the folders, ⌃⌘6 for Urgent, ⌃⌘7 for Needs reply.

### 5.4 Transcript
As Messages:
- **Header:** glass back circle, overlapping avatar plus name pill (tap for Details).
- **Bubbles:** tails only on the last bubble of a run, same-sender gap ≈ 3–5 pt, sender names and 30 pt avatars in groups.
- **Timestamps and status:** centered day/time headers (rule: new day, or a gap over 60 min), receipts under the last outgoing bubble only, swipe left to reveal per-message times.
- **Indicators:** typing indicator, jumbo emoji (≤3 emoji, no bubble), scroll-to-bottom glass button, and a catch-up arrow to the first unread.

Content types, each with a Messages-style rendering:

| Type | Rendering |
|---|---|
| Text | Rich text: bold, italic, strike, monospace, links, mentions in bold, blockquote. Never raw markup |
| Photo / video | Rounded media bubble with a tail. Several photos make a fanned stack ("5 Photos") that expands to a grid. Full-screen viewer, save button |
| Voice message | Play circle, waveform and duration. Transcript under the waveform when Prism has one |
| File | Document card: icon, name, size. Quick Look on tap |
| Link | Preview card: image, title, domain. From the bridge's preview, else Prism's (never fetched from the device) |
| Location / contact card / sticker | Simple cards. Stickers render as images without a bubble |
| Reply | Thread connector bracket plus "N Replies" (Messages style). For networks with quote-replies, the outline quoted-parent bubble |
| Edited / unsent | "Edited" link (tap shows history if available) and a centered "Sam unsent a message" |
| System events | Centered caption (joins, renames, bridge notices) |
| Email | See §5.8 |
| Omni draft | Dashed-outline outgoing bubble (the Send-Later visual) with an Omni sparkle. See §5.7 |

**Reactions:**
- Any emoji on networks that allow it. Classic six-plus-picker bar on long-press or double-tap.
- Badges sit at the top-outer corner; mine are blue-filled, stacked, with an attribution card on tap. One reaction per person per message where the network enforces it.
- Unsupported actions are hidden or disabled per conversation capabilities (e.g. sending a tapback on iMessage in v1, editing on networks without edits).

**Read receipts and typing (owner decision D10):**
- A **Settings toggle** decides whether opening a conversation sends read receipts to the other person. Optional per-network overrides sit under it, e.g. on for Telegram and off for WhatsApp.
- Typing indicators follow the same setting.
- When it's off, opening a chat marks it read only inside Comms, and an explicit "Mark Read" (swipe or menu) sends the receipt.
- **Default: off**, so nothing reaches anyone until the owner opts in.

**Avatars everywhere:** every conversation has an avatar in the list. Group chats use their own photo, or a cluster of member photos when they have none. Every incoming sender in a group transcript shows their avatar on the last bubble of their run (PRD §5.9 precedence).

**Delivery states:** Sending… · Sent · Delivered · Read · Not delivered (red `!` with Retry, which only retries after showing the owner the reason; never silently).

### 5.5 Composer
As Messages:
- floating `+` glass circle and capsule field with the transport placeholder;
- mic when empty, morphing into the blue send arrow;
- emoji circle on Mac;
- grows to ~5 lines;
- Return sends on Mac (⇧/⌥-Return for a newline).

**New conversations (D11):**
- Compose can start new **email** and **iMessage/SMS** threads (address or phone number, with recipient tokens from people notes).
- On the bridged chat networks, v1 is **reply-only**. Compose offers matching existing conversations instead.

**Audio messages (owner requirement):** hold the mic in the composer to record (slide to cancel, lock for hands-free on iOS; click-to-record on Mac). It shows a live waveform and duration, with a preview before sending. Recordings are sent as a voice message on every network that supports one, and as an audio attachment elsewhere. Received voice messages play inline, with a transcript when available.

**`+` menu:** Photos, Camera (iOS), File, **Omni**, Location (later).

**Channel picker:**
- In a merged person conversation, the placeholder is tappable ("WhatsApp ⌄") and switches the outgoing channel.
- The default is the channel of the most recent inbound message.
- Email replies show To/Cc and the subject in a compact header above the field.

**Mentions:**
- `@Name` in group chats where the network supports mentions.
- `@Omni` is special (§5.7).

### 5.6 Search
As Messages:
- bottom capsule on iPhone, sidebar field on Mac;
- suggestions (conversations row, "Messages with / in");
- results as real bubbles with highlighted terms;
- Photos and Links sections;
- tokens.

Comms adds tokens for Network, Urgency and Person. Search runs on Prism, with results grouped by conversation.

**Search depth (D12):**
- **Message text:** all history, from vault transcripts plus the projection.
- **Photos and Links tabs, and media search:** about the last 90 days to start, growing as structured history is indexed later.

### 5.7 Omni tag-in
**Entry points:**
1. ✦ Omni row in the `+` menu (Mac shortcut ⌘⇧O).
2. Typing `@Omni` in the composer. This turns the composer into an instruction field with an Omni tint and placeholder "Ask Omni…". The send arrow becomes ✦ and the field visibly says the text goes to Omni, not to the chat.
3. Long-press a message › "Ask Omni about this" (selected messages become context).
4. "Draft with Omni" chips in the suggestion slot above the keyboard (iOS) or above the composer (Mac), when Omni has pre-drafted replies for owed conversations.

**What Omni can do from a conversation:**
- **Draft a reply.** The result appears in the transcript as a dashed-outline draft bubble with actions **Approve & Send** (exact text, Face ID / Touch ID, digest-bound), **Edit** (moves the text into the composer, where the owner sends it themselves), **Refine…** (follow-up instruction) and **Discard**. A centered caption logs "Omni drafted a reply". A status chip ("Omni is drafting…") floats above the composer, styled like Messages' translation chip.
- **Handle a task.** Omni proposes tasks, calendar invites or RSVPs, an email to a third party, or a follow-up reminder, using its existing proposal kinds. They show as Omni cards in a **Needs you** section of the sidebar (Mac) or a glass accessory above the list (iPhone: "3 for you"). Approving works exactly as in the Omni app.
- **Summarize / catch me up** for long unread runs. The answer shows as a private Omni card at the top of the unread run, never in the chat.

Omni's chat responses never enter the transcript as messages from the owner. Drafts that are not approved within the session stay as drafts and appear in Needs you.

### 5.8 Email in a Messages world
- **Merging:** Email joins a person's conversation only when Prism's strong-key identity matching is confident (DECISIONS D3). Otherwise it is its own conversation titled with the sender's name. The list preview shows the subject in semibold, then the snippet.
- **Each email renders as a bubble:**
  - **Header line:** subject in bold, plus a "to you, Cc 2" caption.
  - **Body:** plain text with quoted history and signature collapsed ("…" expander).
  - **Long or HTML emails:** a "View full email" sheet with sanitized HTML.
  - Attachments render as file cards.
- **Replies** keep threading. The composer shows To/Cc/Subject compactly and sends from the correct account. There is never a hard-coded fallback account.
- **Newsletters, automated mail and promotions** go to Low priority by default.

### 5.9 Names and pictures (fixes the "weird names" and "missing PFPs" complaints)
**Title precedence:**
1. Linked person's name.
2. The network's room or group name.
3. The network contact name (bridge ghost display name, BlueBubbles contact).
4. Email display name from the From header.
5. A formatted phone number or handle.

Never a vault slug, room ID, `whatsapp_123…` ghost ID or raw email address when a better name exists.

**Avatar precedence:**
1. Person note photo.
2. The network's group or contact avatar (bridge ghost avatar, BlueBubbles contact photo).
3. An Apple-style monogram on a gray gradient.

Group avatars without a picture use Messages' cluster of member mini-avatars.

### 5.10 Notifications
- One notification per message, grouped by conversation, showing the sender name, avatar (communication-notification style), network and text preview.
- **Interruption level follows urgency:** Urgent is time-sensitive; FYI and low are passive or silent; Unknown and Spam are silent. This honors Omni's quiet hours (21:00–07:00 Denver) except for Urgent from favourites.
- **Actions:** Reply (inline, an owner-typed send), Mark Read, ✦ Ask Omni. There is no "send Omni's draft" action without opening the app.

### 5.11 Details / inspector
As Messages (sheet on iOS, inspector panel on Mac, ⌥⌘I):
- avatar, name, member grid;
- **Info:**
  - linked person: open the person note in Prism, link or unlink a channel;
  - channels in this conversation, network and account;
  - Hide alerts, pin.
- **Photos · Links:** media and links shared in the conversation.

There is no Backgrounds tab in v1.

### 5.11a Contact cleanup (D17)
Using Comms should make the Parachute vault more accurate, especially for people the owner talks to often.

**"Who is this?"**
- For a DM whose sender isn't linked to a person, the Details inspector offers: link to an existing person (search people), create a new person, or ignore.
- The thread header shows a subtle dot until it's resolved.

**People to tidy:** a sidebar section (Mac) or Filter folder (iOS) listing unlinked or duplicate contacts, ranked by how often the owner talks with them.

**"Same person?" cards** come from Prism's identity review queue. Each shows the evidence: shared phone, email or handle. Choices: Merge · Keep separate · Later.

**Add channel:** when a known person messages from a new handle, offer "Add this WhatsApp number to Sam" in one tap.

**Rules:**
- Every change is owner-confirmed, audited and undoable.
- Changes write through Prism's identity services into the person notes, so names, avatars, merged threads, triage and Omni all improve.
- Never auto-merge on name alone.

### 5.12 Mac specifics
- Menu bar: Comms · File · Edit · View · Conversation · Format · Window · Help.
- Keyboard shortcuts as listed in the UX spec §9: ⌘N, ⌘F, ⌘1–9, ⌃Tab, ⌘R, ⌘T 1–6, ⌘E, ⌥⌘I, ⇧⌘U, ⌘+/−, and the filter shortcuts above.
- ⌘K jumps to any conversation.

## 6. Channels at launch

| Channel | Source | Read | Send | Reactions | Edits/unsend | Typing / receipts | Media |
|---|---|---|---|---|---|---|---|
| WhatsApp, Telegram, Discord, Messenger, X | Matrix bridges (Mini) | ✓ | ✓ | ✓ (per network) | ✓ (per network) | ✓ where bridged | ✓ |
| iMessage / SMS | BlueBubbles (Mini, SIP on) | ✓ | ✓ text + attachments + audio | see incoming; **sending tapbacks under review (D6 reopened)** | see incoming | ✗ (v1) | ✓ |
| Email (Proton) | Prism Proton ingest + SMTP | ✓ | ✓ reply / new | ✗ | ✗ | ✗ | ✓ attachments |
| Email (personal Gmail) | later | — | — | — | — | — | — |

Per-conversation capabilities come from the server. The UI never offers what the channel can't do.

## 7. Safety requirements (non-negotiable)

1. **Comms talks only to Prism.** It never talks to Synapse, the bridges, BlueBubbles or SMTP directly.
2. **Owner-typed sends:**
   - Use the owner's Comms device credential with human origin, an idempotency key and an audit row.
   - The credential is issued through device sign-in with one-door approval from an existing device.
3. **Omni-drafted content** can reach a person only through a Prism approval bound to the SHA-256 digest of the exact payload, decided on a device with biometric confirmation.
   - Editing a draft makes it owner-typed: it moves into the composer and the owner presses Send.
4. Notification actions can send only owner-typed text.
5. Message bodies are untrusted input to Omni. Comms-originated Omni runs use the same restrictions as Omni card threads: bounded context, no browser egress, propose-only tools.
6. **The BlueBubbles rollout must close the agent-guard gap in the same release.** Block agent traffic to the BlueBubbles port, treat its config and password as secrets, and block app control.
7. **Email to third parties follows the existing Proton rules.** Owner-typed email replies are allowed through the new route; Omni-drafted ones need approval.

## 8. Phasing (detail in the implementation plan)

| Phase | Outcome the owner can feel |
|---|---|
| 0 · Spikes | Transcript scroll (iOS 26/27, Mac), Mac composer glass, bubble calibration against Apple's design kits |
| 1 · Read | Mac app shows every Matrix conversation with correct names, avatars, formatting, media, reactions and link previews, live-updating |
| 2 · Reply | Owner-typed sends, reactions, replies, read state. iPhone app. Push notifications |
| 3 · iMessage | BlueBubbles on the Mini with the guard fix. iMessage/SMS conversations in Comms |
| 4 · Omni | `@Omni` tag-in, draft bubbles, approve-exact, Needs you, urgency filters and markers |
| 5 · Email | Email conversations, confident per-person merging, email replies |
| 6 · Backfill | Prism's web and desktop messages UI switches to the Comms API and design tokens. Legacy transcript parsing retired |

## 9. Pixel-perfect acceptance

- Download Apple's iOS 26/27 and macOS 26/27 design kits. Replace every `[est]` in the UX spec with kit values, or with on-device measurements (Xcode view debugger or Accessibility Inspector on the owner's own Messages, measuring geometry only and never capturing content).
- Keep a **reference-pair gallery**: for each screen in the spec, a Comms screenshot with synthetic data next to the matching Apple screenshot, at the same device, scale and appearance. Light, dark, Clear and Tinted glass, and the largest Dynamic Type.
- A snapshot test suite guards bubble geometry, spacing and colors against regressions.
- Owner sign-off per screen.

## 10. Open questions

1. ~~Apple ID / SMS~~ **Resolved:** the owner's personal Apple ID is signed in on the Mini, and SMS forwarding to it is believed on. Verify with a test SMS at the start of Phase 3.
2. ~~iMessage history and Omni~~ **Resolved (D13):** iMessage flows into the vault, with about 90 days of history backfilled and one-time codes and short codes excluded. Omni may draft iMessage replies, which still need approval of the exact text.
3. Is FileVault on the Mini, and is auto-login acceptable so BlueBubbles survives a reboot? Can Mini macOS updates wait until tested on the laptop?
4. ~~Turning on live sends~~ **Resolved 2026-11-21:** checked on the Mini (`prism-v2026.11.13`): `ACTIONS_MATRIX_ENABLED=true`, `ACTIONS_EMAIL_ENABLED=true`, and `OMNI_EXECUTOR_KINDS` includes `message` and `email-reply`. Matrix send paths are already live. New flags are needed only for iMessage and owner-typed email replies.
5. **Name:** "Comms" is the working name. The bundle ID is reserved as `com.example.comms`.
