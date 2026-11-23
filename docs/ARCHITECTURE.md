# Comms — Technical Architecture

Status: approved by owner · 2026-11-21
Companion docs: [PRD.md](PRD.md) · [DECISIONS.md](DECISIONS.md)

Research this builds on (read these first):
- [research/prism-inventory.md](research/prism-inventory.md): what Prism already does for messages, with file paths
- [research/agent-inventory.md](research/agent-inventory.md): Matrix stack, bridges, triage and Omni guard in the agent repo
- [research/native-tech-options.md](research/native-tech-options.md): Liquid Glass APIs, transcript engineering, Matrix SDK comparison, mautrix event shapes
- [research/bluebubbles.md](research/bluebubbles.md): BlueBubbles capabilities, host choice, integration path
- [research/apple-messages-ux-spec.md](research/apple-messages-ux-spec.md): the visual spec

## 1. Shape of the system

```
 ┌──────────── Comms.app (macOS 26+/iOS 26+) ───────────┐
 │ CommsUI (SwiftUI + UIKit/AppKit transcript hosts)     │
 │ CommsCore (models, stores, outbox, ChatBackend)       │
 │ PrismKit (auth, transport, SSE, approval digests)  ◄──┼── reused from ~/dev/prism/swift/PrismKit
 └───────────────▲───────────────────────────────────────┘
                 │ HTTPS (pd_ device token, client comms-native)
                 │ REST /api/comms/* · SSE /api/comms/stream · APNs
 ┌───────────────┴──────── Prism server (Mini) ──────────────────────────┐
 │ apps/server/src/comms/  (NEW)                                         │
 │   api routes ─ normalizer ─ projection store (SQLite, rebuildable)    │
 │   sources:  MatrixSource │ BlueBubblesSource (NEW) │ EmailSource       │
 │   sends:    actions/matrix.ts │ actions/imessage.ts (NEW) │ email exec │
 │   omni:     /api/omni/* approvals, cards, hooks (existing)            │
 │ existing:  worker/matrix.ts ingest → vault message-thread notes       │
 │            worker/proton.ts → vault email notes · triage skill        │
 └───────▲────────────────────▲─────────────────────▲────────────────────┘
         │ C-S API (loopback)  │ REST + webhooks     │ IMAP/SMTP (loopback)
   Synapse + 5 mautrix   BlueBubbles server     Proton Bridge
   bridges (Docker)      (Mini, SIP on)
```

**Rule 1:** Comms talks only to Prism. Prism is the single gateway for reads, sends, media and Omni (DECISIONS D1, D2).

**Rule 2:** Prism's vault notes stay the canonical record for the agent. The Comms layer is a **rebuildable projection**, plus live reads from the sources. That follows the `docs/roadmap/workspace-experience/MESSAGES.md` contract: "Server indexes are rebuildable projections, not another source of truth", with a single ingest owner.

## 2. Repositories and where code lives

| Repo | What changes |
|---|---|
| `~/dev/comms` (new) | Swift apps, CommsKit package, docs. Same layout as Minutes (`~/dev/no_Saas/minutes`): `Apps/` (XcodeGen `project.yml`, `generate-project.sh`), `CommsKit/` (SwiftPM), `docs/` |
| `~/dev/prism` | `apps/server/src/comms/` (new module), BlueBubbles source and `actions/imessage.ts`, `comms-native` client registration, APNs topic, push. Later: `packages/core` adopts the API (backfill) |
| `~/dev/prism/swift/PrismKit` | Adds `CommsClient` + models (as `OmniClient` exists), so Omni can show conversations later too |
| `the agent repo` | Guard-table rules for BlueBubbles. Triage window fix (select by last activity). Person resolution by mxid / phone. `message` executor kind enablement runbook |

CommsKit depends on PrismKit by **local path during development** (`../prism/swift/PrismKit`) and by **git tag for releases** (Minutes pattern).

## 3. Prism server: the `comms` module

### 3.1 Sources

Each source implements one interface:

```ts
interface CommsSource {
  network: Network | Network[];          // 'whatsapp'|'telegram'|'discord'|'messenger'|'x'|'imessage'|'sms'|'email'|'matrix'
  listConversations(cursor?): Page<SourceConversation>;
  readTimeline(ref, {before?, after?, limit}): Page<SourceEvent>;
  subscribe(onEvent): Unsubscribe;        // live events (message, edit, redaction, reaction, receipt, typing, room state)
  capabilities(ref): Capabilities;        // per-conversation: react, edit, unsend, reply, typing, receipts, attachments, maxBody
  media(ref, mediaId, {thumb?}): Stream;  // bytes for proxying
  send(ref, OutboundMessage, idem): SendResult;   // called only by the actions layer
  react / unreact / markRead / setTyping (where supported)
}
```

**MatrixSource** wraps the existing `MatrixClient` (`apps/server/src/worker/matrix.ts:53-302`) and extends it with:
- **Room metadata:**
  - `m.bridge` / `uk.half-shot.bridge` state → `protocol.id` (network), `channel.displayname` / `avatar_url`.
  - `com.beeper.room_type` (DM or group).
  - `com.beeper.room_features` (capabilities).
  - `m.room.name` / `m.room.avatar`.
  - Member display names and avatars (`joinedMembers` already exists).
  - **This replaces ghost-prefix guessing** (`detectPlatform`, `:405`), which stays as a fallback.
- **Events:**
  - All `m.room.message` msgtypes: text, notice, emote, image, video, audio and voice (MSC3245), file, location, sticker.
  - `m.reaction`, edits (`m.replace`), replies (`m.in_reply_to`), threads (`m.thread`), redactions.
  - `com.beeper.message_send_status`, `com.beeper.linkpreviews`, `m.receipt`, `m.typing`.
- **Live:** the ingest worker today polls `/sync` every 60 s. Switch it to **long-poll `/sync` (timeout 30 s)** inside the single existing ingest owner. One loop feeds both the vault writer (unchanged behaviour) and an in-process event bus that the comms projection consumes. **Do not run a second sync loop** (single-ingest-owner rule).
- **Read markers:** `POST /rooms/{id}/receipt/m.read/{eventId}` and `m.fully_read` (the bridges relay these as remote read receipts where the network supports it).

**BlueBubblesSource** (new, `apps/server/src/comms/sources/bluebubbles.ts`), designed in research/bluebubbles.md §4:
- REST to BlueBubbles on the Mini (bound to loopback). Password in Prism's encrypted secrets (`bluebubbles` secret, like `matrix`).
- Webhooks into `POST /api/comms/hooks/bluebubbles`. These are treated only as hints: Prism re-fetches each message by GUID before trusting it. There is also a catch-up poll every 60 s and a stale-database watchdog.
- **Conversation key:** chat GUID. 1:1 chats on iMessage and SMS for the same handle are merged into one conversation (macOS keeps them separate), and the outbound service is chosen per message.
- **Capabilities (SIP on):**
  - Send text and attachments.
  - Read incoming tapbacks, edits and unsends.
  - No outbound react, typing or receipts.
  - `capabilities()` reports exactly this.

**EmailSource**:
- **List and summaries:** read from the vault `email` notes written by `worker/proton.ts`. Group them into threads by `threadId`.
- **Bodies:** fetch on demand over IMAP by Message-ID. Proton Bridge on loopback, read-only `BODY.PEEK`, so reading in Comms never marks mail read on the server unless the owner chooses Mark Read.
- **Body processing:** quote and signature trimming, then HTML sanitizing into the rich-text model (§3.3).
- **Sends:** go through the existing Proton executor path (§5).

### 3.2 Projection store (rebuildable)

SQLite in Prism's existing DB (`apps/server/src/db.ts`). Tables, prefixed `comms_`:

| Table | Purpose |
|---|---|
| `comms_conversations` | One row per *source conversation* (room / chat GUID / email thread). Columns: network, source ref, kind, title + title_source, avatar ref, last_event_at, last_preview, unread_count, unread_trusted, folder, pinned, muted, archived, triage, capabilities JSON, vault_note_id |
| `comms_threads` | One row per **display conversation** (what the list shows). Either 1 source conversation, or a merged person conversation (D3) with `person_id` |
| `comms_thread_members` | thread ↔ source conversations |
| `comms_messages` | A **recent window cache** (last N=200 per conversation plus anything viewed in the past 7 days) of normalized messages, keyed by `(network, source_event_id)` |
| `comms_reactions`, `comms_receipts` | Aggregation helpers |
| `comms_identity_links` | Cached merge decisions with their evidence (strong key used) and owner overrides (link/unlink) |
| `comms_events` | Monotonic event log for SSE `Last-Event-ID` resume (7-day retention) |

Everything here can be rebuilt from the sources, the vault and owner overrides. Owner overrides (pins, archive, manual link/unlink, mute) are the one thing that isn't derivable. They are also written to the conversation's vault note metadata, so a rebuild keeps them.

### 3.3 Normalized model (wire format)

```ts
type Thread = {
  id: string;                    // stable, opaque
  title: string; titleSource: 'person'|'room'|'contact'|'email'|'handle';
  avatar: AvatarRef | null;      // media token or {monogram, members[]}
  kind: 'dm'|'group';
  networks: Network[];           // >1 only for merged person threads
  personId?: string;
  lastMessage?: MessagePreview;  // plain text, tapback/attachment phrasing pre-rendered
  lastActivityAt: string;        // ISO UTC
  unread: { count: number; trusted: boolean };
  folder: 'inbox'|'unknown'|'low'|'spam'|'archived';
  urgency: 'urgent'|'needs-reply'|'fyi'|'low'|null;   // from triage tags + owed-reply evidence
  pinned: boolean; muted: boolean;
  channels: ChannelRef[];        // send targets with network, account label, capabilities
};

type Message = {
  id: string; threadId: string; channel: ChannelRef;
  source: { network: Network; eventId: string; ref: string };
  sender: { id: string; name: string; avatar: AvatarRef|null; isSelf: boolean; isOmni: boolean; personId?: string };
  sentAt: string; editedAt?: string;
  body: RichText | null;         // portable spans: text, bold, italic, strike, code, pre, link, mention, quote, listItem
  email?: { subject; from; to[]; cc[]; quotedCollapsed: boolean; hasHtml: boolean };
  attachments: Attachment[];     // {kind, mediaToken, thumbToken, mime, size, w, h, durationMs, waveform?, name, transcript?}
  linkPreviews: LinkPreview[];   // {url, title, description, siteName, imageToken}
  replyTo?: { messageId; snippet; senderName };
  threadRoot?: string; replyCount?: number;
  reactions: { key: string; count: number; mine: boolean; senders: {id,name}[] }[];
  delivery: 'pending'|'sent'|'delivered'|'read'|'failed'|null;
  deliveryError?: string;
  redacted: boolean;
  system?: { kind: string; text: string };   // joins, renames, bridge notices
};
```

**Owned by the server, so clients and the Prism web UI never reimplement them:**
- **Formatting:** Matrix `formatted_body` HTML goes through an allowlist sanitizer into `RichText`. WhatsApp and Telegram markdown already arrive as `formatted_body` from the bridges, with a plain `body` fallback through a small markdown-lite parser. Email goes through text/plain plus quote trimming, or sanitized HTML.
- **Aggregation:** reactions, edits (latest content wins; history kept), redactions and replies are folded in.
- **Naming and avatars:** apply PRD §5.9 precedence. Person data comes from `PeopleIndex` / `IdentityIndex` (`worker/people.ts`, `src/identity.ts`), using strong keys only.
- **Preview phrasing:** "Sam loved 'Dinner…'", "📷 Photo", "Voice message 0:07".
- **`isSelf`:** decided from event fields only (owner mxid, `@omni-agent` puppet logins, the BlueBubbles `isFromMe` flag, or email From matching an owner address). Never from display names. The ingest code's `lastMessageEvidence` already follows this rule.

### 3.4 Identity merging (D3: merge when confident)

- A display thread merges source conversations only when **every** member conversation is a DM whose counterpart resolves, via a strong key (`IdentityIndex`: email, mxid, E.164 phone, Telegram id, bridge handle), to the **same** person note.
- Groups never merge.
- Name-only matches never merge. They can be offered in Details as "Link to Sam?", and the owner confirms.
- An owner link or unlink overrides and is stored with its evidence.
- Unmerge is always available.

### 3.5 API (`/api/comms/*`)

All routes:
- are owner-only;
- accept the `comms-native` device token and the owner's session (the session is for the Prism web backfill);
- are rate-limited;
- require `Idempotency-Key` on mutations.

| Route | Purpose |
|---|---|
| `GET /api/integrations/comms/capabilities` | Capability declaration (Minutes pattern). The client fails closed without it |
| `GET /threads?folder&unread&urgency&network&person&q&cursor` | Paged thread list (summary projection; replaces the 500-note client slice, MSG12) |
| `GET /threads/:id` | Thread detail, channels, capabilities, members |
| `GET /threads/:id/messages?before=&after=&around=&limit=` | Timeline page. Cache-first, falling through to the source for older history. Cursors are opaque |
| `POST /threads/:id/messages` | Owner-typed send `{channelId, body, attachments[], replyTo?}` → 202 `{clientId, messageId, delivery:'pending'}` |
| `POST /threads/:id/messages/:mid/reactions` / `DELETE …/:key` | React / unreact (capability-checked) |
| `POST /threads/:id/messages/:mid/edit`, `…/unsend` | Where supported (later phase) |
| `POST /threads/:id/read` | Mark read up to a message. Sends source receipts **only if** `{sendReceipt:true}` and the owner's receipt setting (global or network override) allows it (D10). Otherwise the read state stays local to Comms and Prism |
| `POST /threads/:id/typing` | Typing on/off. Honoured only when the receipts/typing setting allows it |
| `GET/PUT /settings` | Owner settings: receipts/typing global + per-network overrides, notification policy |
| `POST /threads` | New conversation: email or iMessage/SMS only in v1 (D11). `{channel:{network, to[]}, body}` → owner-typed send gates |
| `PATCH /threads/:id` | Pin, mute, archive, folder override |
| `POST /threads/:id/link` / `unlink` | Owner identity overrides |
| `POST /uploads` | Media upload (multipart, size-capped) → upload token used in a send |
| `GET /media/:token` | Media and avatar proxy. Short-lived signed tokens, range requests, thumbnails, `Cache-Control: private` |
| `GET /search?q&tokens` | Message search across the vault and the cache |
| `POST /threads/:id/assist` | Omni tag-in (§6) |
| `GET /stream` | SSE with `Last-Event-ID`. Events: `thread.updated`, `message.created\|updated\|deleted`, `reaction.changed`, `receipt`, `typing`, `assist.updated`, `approval.changed` |
| `POST /hooks/bluebubbles` | BlueBubbles webhook (loopback/Tailscale-only, shared secret) |
| `POST /push/apns` | Register the Comms APNs token (`topic com.example.comms`) |

Media tokens are bound to the device credential, so URLs can't be replayed from logs. The `/api/events` SSE stays as is; `/api/comms/stream` is separate because it carries message content, which `/api/events` deliberately never does.

## 4. Auth and client identity

- New client `comms-native`, redirect `comms://auth/callback`, registered alongside `prism-native` and `omni-native` in `apps/server/src/auth/device.ts`. PKCE S256 device sign-in. One-door: a new Comms device needs approval from an existing device.
- **Restricted grant**, as Minutes does. The token may call only:
  - `/api/comms/*`
  - `/api/omni/approvals*` and `/api/omni/cards*` (for drafts and Needs you)
  - `/api/integrations/comms/capabilities`
  - push registration

  Central enforcement denies everything else: vault passthrough, MCP, admin. This is a security-review item, as Omni's client was.
- PrismKit: add `DeviceAuthConfiguration.commsNative` next to `.prismNative` / `.omniNative` (`swift/PrismKit/.../PKCE.swift:25-28`). Keychain store per origin. App lock with Face ID / Touch ID on launch is optional (owner setting).

## 5. Sending

### 5.1 Owner-typed (the owner's own action)

```
Composer → POST /api/comms/threads/:id/messages (device token, Idempotency-Key)
  → comms router resolves channel → actions/{matrix|imessage|email}.ts
     (existing live-action gates: owner, family flag, rate limit, human origin = device token,
      joined-room / known-chat check, idempotency ledger, action_audit row)
  → source.send() → event id → SSE message.updated delivery=sent → bridge status → delivered/read
```

- Reuses `POST /api/actions/matrix/send` internals (`routes/actions.ts:747-768`, txnId from the idempotency key).
- Adds:
  - `actions/imessage.ts` with the same gate shape.
  - An **owner-typed email reply** action that calls the existing Proton sender with human origin. Today email sends flow only through Omni approvals. This is new and gated the same way as `matrix/send`.
- **Production switches:** `ACTIONS_MATRIX_ENABLED` is already `true` on the Mini (checked 2026-11-21). New: `ACTIONS_IMESSAGE_ENABLED` and `ACTIONS_EMAIL_REPLY_ENABLED`, both off by default.
- **Origin in the audit:** owner-typed and Omni-approved sends both leave through the `@omni-agent` puppet logins. The `action_audit` row records `origin: owner-typed | omni-approved` plus the approval ID. Ingest's `lastMessageIsAgent` must treat events matched to an owner-typed audit row as self, so owed-reply logic counts the owner's own replies.
- **Failure handling:** never auto-resend. A `failed` state with a reason, plus Retry that reuses the same idempotency key. The UI never offers Retry when delivery is unknown; it shows "Checking delivery" (MESSAGES.md sending rules).

### 5.2 Omni-drafted (needs approval of the exact text)

```
Omni → omni_propose(kind:'message', payload:{channel:{network,conversationRef,accountId}, body, replyTo?})
  → Prism approvals (digest = sha256(canonical {kind,payload}))
  → SSE approval.changed → Comms shows dashed draft bubble
  → owner taps Approve & Send → Face ID → POST /api/omni/approvals/:id/decision {digest, Idempotency-Key}
  → executor prism-live-actions:{matrix|imessage|email} with the owner's credential → same gates as 5.1
```

- **Payload change:** the `message` approval payload today is `{roomId, body}` (`omni/approvals.ts:117`). Version it to `{v:2, channel, body, replyTo?}` and keep accepting v1. The digest changes with the version (canonical JSON includes `v`). `PrismModels.ApprovalDigest` and Omni's `ApprovalContent` are updated together. Omni's approval views keep working for v2.
- **Executors:**
  - Add the `imessage` executor.
  - `message` is already in `OMNI_EXECUTOR_KINDS` in production (checked 2026-11-21).
- **Edit makes the draft owner-typed:** "Edit" moves the draft into the composer and marks the approval `revised`/discarded. What the owner then sends is their own action through 5.1. This is intentional and consistent with the hard line, because the owner sees and sends exact text.

## 6. Omni tag-in

`POST /api/comms/threads/:id/assist` with `{instruction, contextMessageIds?, mode:'draft'|'handle'|'summarize'}`:
1. Prism builds a **bounded context packet**:
   - the last K messages (default 40) plus any selected ones;
   - the participants' person-note summaries (Omni's existing `active_packet` approach);
   - channel capabilities.

   Message bodies are wrapped as untrusted content.
2. Prism opens an **Omni thread** through the existing gateway (`/api/omni/*` → Hermes `api_server`), with a Comms-specific policy:
   - propose-only tools (`omni_propose`, `omni_card`);
   - read-only vault;
   - **no browser or network egress** (same as `CARD_EGRESS_BLOCK`);
   - no `send.*`.
3. Omni returns proposals (drafts) and/or cards. Comms receives them as `assist.updated` and `approval.changed`.
4. The assist thread ID is stored on the Comms thread, so "Refine…" continues the same Omni thread.

**Where things render:**
- Drafts render inline as dashed bubbles.
- Task, calendar, email and other cards go to **Needs you**, via `/api/omni/cards` (no new attention model; DECISIONS D7).
- Summaries render as a private card at the top of the unread run.

**"Draft with Omni" chips:** a server job pre-drafts for threads with urgency `needs-reply` (owed-reply evidence from the existing sweep logic) and exposes them on `GET /threads/:id` as `suggestedDrafts`. Opt-in, with a budget like proactive cards.

## 7. Push notifications

- APNs topic `com.example.comms`, **direct APNs** (`apps/server/src/apns.ts`, `.p8` key), not the relay. The relay must never carry message text (`docs/push.md`).
- **Payload:** rendered title (sender), subtitle (network or group), body (preview), `thread-id` = thread id, communication-notification intent data (sender name and avatar URL token), `interruption-level` from urgency and folder, `relevance-score`.
- **No Notification Service Extension in v1:**
  - Prism renders the text.
  - **Avatars in communication notifications** need an NSE (INSendMessageIntent donation with an INImage). Add a tiny NSE in Phase 2 that downloads the avatar via a media token, with a hard 5 s and low-memory budget.
- **Inline Reply** → `POST /threads/:id/messages` from the app process, an owner-typed send.
- **Policy:**
  - Quiet hours reuse Omni's nudge policy (`omni/nudge-policy.ts`).
  - Unknown and Spam never push.
  - Muted threads never push.
  - A thread open on any device suppresses pushes (presence via the SSE connection).

## 8. Swift client

### 8.1 Packages and targets

```
CommsKit/ (SwiftPM, Swift 6.2, macOS 26 / iOS 26, built with the Xcode 27 SDK)
  CommsCore  — models (Codable mirrors of §3.3), ThreadListStore, TimelineStore, Outbox,
               ChatBackend protocol + PrismChatBackend, StreamClient (PrismSSE), MediaCache,
               FilterState, Search. No SwiftUI. Heavy unit tests (Omni's OmniCore pattern).
  CommsUI    — SwiftUI screens and components; UIKit/AppKit transcript hosts; design tokens.
  CommsTestSupport — fixtures, fake backend, snapshot helpers.
Apps/ (XcodeGen) — CommsMac, CommsiOS (iPhone + iPad), CommsNSE (Phase 2)
```

`ChatBackend` is the seam. `PrismChatBackend` is the only implementation in v1. A `FixtureBackend` drives previews, snapshots and the design gallery. The protocol leaves room for a future read-only `RustSDKBackend` if offline-first ever matters (DECISIONS D2).

### 8.2 Key UI engineering choices

- **Layout:** `NavigationSplitView` (floating glass sidebar on Tahoe, a stack on iPhone), `.searchable` on the split view, `.inspector` for Details on Mac.
- **Transcript** (highest risk, so spike first):
  - **iOS:** `UIViewControllerRepresentable` around a **flipped `UICollectionView`/`UITableView` with `UIHostingConfiguration` cells**, using Element X's `TimelineTableViewController` pattern. Prefetch about 2 screens. Defer inserts while dragging. Fix the VoiceOver order.
  - **macOS:** `NSTableView` with `NSHostingView` cells and manual offset correction on prepend.
  - Bubbles stay pure SwiftUI and are shared across platforms.
  - Avoid `ScrollView`+`LazyVStack` prepend (open bugs FB20979569 on iOS 26 and FB24968838 on iOS 27).
- **Bubble shape:** a custom `Shape` drawing body and tail as one path, plus `UnevenRoundedRectangle` for grouped bubbles without tails. Calibrated against Apple's kits.
- **Outgoing blue gradient:** a single screen-space gradient layer masked by outgoing bubble shapes. The colour depends on on-screen y, not per bubble. Implement it in the cell via a shared gradient sampled at the cell's window-space frame (cheap). Do not use per-bubble gradients.
- **Composer:**
  - `.safeAreaBar(edge: .bottom)` with one `GlassEffectContainer`: `+` circle, interactive glass capsule, `.glassProminent` send button morphing in via `glassEffectID`.
  - Set `.scrollEdgeEffectStyle(.soft, for: .bottom)` explicitly, because the 27 SDK defaults to hard.
  - The text field is a `UITextView`/`NSTextView` wrapper from day one. It's needed for Return-to-send, paste images, `@Omni` and mention tokens (`NSTextAttachment`), and the channel-picker placeholder.
- **Glass discipline:** glass only in the navigation layer, grouped in containers. Never on bubbles. Test Clear and Tinted glass, Reduce Transparency and Increase Contrast.
- **Design tokens:** `CommsUI/Tokens.swift` is generated from `design/tokens.json` (colors, radii, spacing, type). The same JSON is consumed by Prism's CSS in the backfill, so both UIs share one source of truth.

### 8.3 State and caching

- `ThreadListStore` and `TimelineStore` are `@Observable` `@MainActor` view models fed by REST pages plus SSE deltas. Reconciliation is by server ID; pending sends are matched by `clientId`.
- **Local cache:** an on-disk SQLite cache (GRDB is a reasonable choice; the builder decides) holding thread summaries and the last ~200 messages per opened thread, so launch is instant and the app is readable offline. It is cache only and can be wiped any time.
- **Outbox:** owner-typed sends persist until acknowledged. Retry is explicit, with the same idempotency key.
- **Media:** a disk LRU for thumbnails, avatars and recently viewed full media. Full-size media is fetched on demand with range support for video.

## 9. BlueBubbles rollout (Phase 3)

1. **Install** BlueBubbles Server ≥ v1.9.12 on the Mini.
   - SIP stays on. Messages is already signed in.
   - Bind the API to loopback.
   - Grant Full Disk Access and Accessibility. Tahoe 27.2 moved the Accessibility pane; see research §1.
2. **Agent guard, same change** (agent repo `hermes/plugins/omni-bridge/guard_table.py`):
   - block agent network access to the BlueBubbles port;
   - treat the BlueBubbles config dir and password as secrets;
   - block launching or scripting the app.

   Add tests next to the existing guard tests.
3. **Prism:**
   - the `bluebubbles` secret;
   - `BlueBubblesSource`;
   - `actions/imessage.ts` behind `ACTIONS_IMESSAGE_ENABLED`;
   - `detectPlatform`/network `imessage` + `sms`.
4. **Vault ingest:** BlueBubbles conversations write `message-thread` notes through the same single ingest owner (platform `imessage`). That way triage, the owed-reply sweep and Omni see iMessage like any other channel. Short-code and one-time-code senders are excluded (PRD Q2).
5. **Health:** add BlueBubbles to `source_health.py` and the watchdog, and alert on a stale `chat.db` write time.

## 10. Backfilling into Prism (owner requirement)

Because the logic lives in Prism, the backfill is mostly a client swap plus shared tokens:

| Prism piece today | After |
|---|---|
| `VaultMessagesDashboard.tsx` lists vault notes (500-note slice, slug titles) | Lists `/api/comms/threads` with the same filters (folders, urgency, network, person). Fixes MSG12, MSG13 |
| `MessageRenderer.tsx` Saved/Live swap and `legacyThread.ts` parsing | Renders `/api/comms/threads/:id/messages`. Legacy parsing remains only for archived ranges the projection can't cover. Fixes MSG01–08, MSG14 |
| `MessageThread.tsx` grouping by sender | Grouping by sender + direction + day + 60-min gap. Tails and timestamps from the shared spec. Fixes MSG04 |
| `MessageComposer.tsx` | Uses `POST /threads/:id/messages`, delivery states, outbox semantics. Fixes MSG09, MSG10 |
| `AgentReplyDraft.tsx` | Uses `/threads/:id/assist` and draft bubbles. Same flow as Comms |
| No reactions, avatars or media | Reaction bar, avatars and media via `/api/comms/media` |
| CSS ad hoc | `design/tokens.json` → CSS variables (bubble colors, radii, spacing) |
| Vault note titles from slugs (agent sees bad names) | The ingest owner writes a `title` field using the §3.3 naming precedence. Omni and routines see correct names too |
| Omni app `UserBubble` and message approvals | Omni renders `message` approvals as a Comms-style bubble preview. CommsUI's bubble view can be extracted into PrismKit's UI layer later if both apps want it |

`docs/roadmap/workspace-experience/MESSAGES.md` F06–F08 become "delivered via the comms module". Update that doc and `docs/live-actions.md` when Phase 6 lands.

## 11. Testing and verification

- **Server:**
  - unit tests for the normalizer: formatting, aggregation, naming precedence, isSelf;
  - source contract tests against recorded fixtures: synthetic Matrix events including `m.bridge` / `com.beeper.*`, BlueBubbles payloads, emails;
  - identity merge property tests (never merge on name only, never merge groups);
  - gate tests for every send path (device token required, idempotency, agent origin refused);
  - an SSE resume test.
- **Swift:**
  - CommsCore unit tests (stores, reconciliation, outbox);
  - snapshot tests of bubbles, rows and composer in light/dark, Dynamic Type and glass modes;
  - a transcript scroll test (prepend 500 variable-height messages without visible jumps) on iOS 26.x, iOS 27 and macOS.
- **Design gallery:** a debug-only screen with Comms and Apple reference screenshots side by side (PRD §9).
- **No real conversations in tests or commits.** Fixtures are synthetic (MESSAGES.md rule).
- **End-to-end on staging:**
  - a Matrix room on a test bridge account, or a plain Matrix test room;
  - one owner-typed send and one Omni-approved send, each verified on the receiving network;
  - one BlueBubbles round trip to the owner's own second Apple ID or test number.

## 11a. Builder calls settled during review

- **Urgency at arrival:**
  - Model triage runs hourly and can't stay loaded on the Mini. Push-time urgency therefore comes from cheap deterministic rules: the sender is linked to a person with `priority_weight ≥ 0.7`, an owed-reply exists, the thread is pinned, or there's a direct mention.
  - The model's tags refine list markers and filters when they land, and `thread.updated` re-renders.
  - The triage window bug (selecting by `createdAt`) is fixed in the agent repo so chats get classified at all.
- **"Favourites"** (quiet-hours bypass, Contact filter defaults) means pinned conversations plus people with `priority_weight ≥ 0.7`. No new field.
- **Staging:**
  - Read-only phases ship to production behind `COMMS_ENABLED`.
  - Anything touching the ingest loop (long-poll `/sync`), send paths or BlueBubbles is first exercised on a **laptop staging stack**: Prism server plus a throwaway Synapse in Docker, with plain Matrix test rooms and no bridges, with fixtures for bridge events.
  - Production then gets flag-gated canaries: `COMMS_SYNC_LONGPOLL`, `ACTIONS_IMESSAGE_ENABLED`.
  - BlueBubbles' first live round trip is to the owner's own second handle.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Transcript scroll/prepend bugs on iOS 26/27 | Phase 0 spike. UIKit/AppKit hosts. Element X pattern |
| Mac composer glass doesn't frost like Messages (forum 827251) | Phase 0 spike. Rely on scroll edge effect; fallback is a regular-material capsule |
| Mini memory (16 GB, LM Studio guards) | The comms module is lightweight (SQLite, streams). BlueBubbles adds ~300–500 MB. Watch with lms-guard |
| Postgres / Synapse corruption history | No new Matrix storage. Comms projection rebuildable |
| Bridge breakage (WhatsApp, Messenger) | Per-network health surfaced in Comms (a subtle banner in affected threads) |
| A new client ID widens the attack surface | Restricted grant, central enforcement, security review as for Omni |
| Long-poll `/sync` change in the ingest owner | Behind a flag. Vault writer behaviour unchanged. Compare note output before and after on staging |
| Approval payload v2 breaks existing Omni approvals | Accept v1 and v2. Golden digest tests in TS and Swift |
| Pixel drift from Apple's updates (27.x) | Tokens in one JSON. Gallery re-checked each major OS |
