# BlueBubbles as an iMessage/SMS channel for Prism, Omni and Comms

Research date: 2026-11-21. This was read-only: nothing was installed or changed, and no message content was read.

## TL;DR recommendation

1. **Run BlueBubbles Server v1.9.12 on the Mac Mini with SIP left on (no Private API).** Messages is already signed in and syncing there: `~/Library/Messages/chat.db` is 337 MB and was last written today at 18:35. Bind it to localhost/Tailscale only, and don't use a cloud proxy or Firebase.
2. **Integrate it directly into Prism as a second message source (option b).** Add a `worker/bluebubbles.ts` (webhook plus a catch-up poll) and an `imessage.send` live action behind the existing approval gate. Don't adopt mautrix-imessage. It's a legacy (pre-bridgev2) bridge, its BlueBubbles connector hasn't been touched since June 2024, it needs an extra wsproxy component, and Beeper's tooling for it only works against Beeper's own homeserver.
3. **Make the agent guard changes part of the same change.** The current guard doesn't recognise BlueBubbles' HTTP API at all, so a raw `curl` to it would be an ungated send from the owner's Apple ID.
4. **Defer the Private API** (tapback sending, typing, read receipts, replies, edit/unsend). If the owner wants it later, it belongs on a separate, disposable Mac (a used M1 mini) with SIP off, not on the production Mini. Even with the helper on macOS 26/27 there are open bugs: the edit path crashes Messages (#898), and the helper can report "connected" while sends silently fail (#890).

## 1. BlueBubbles server today

### Version and maintenance
- **Latest is v1.9.12**, published 2026-10-27, the same day as v1.9.11 and the pulled v1.9.10. Before that came v1.9.9 (2025-05-16) and v1.9.8 (2024-11-20). Sources: GitHub releases API, https://github.com/BlueBubblesApp/bluebubbles-server/releases.
- What v1.9.10–12 changed:
  - Builds are notarized again, and in-app auto-update is back.
  - Chat identifiers "resolved correctly on Tahoe and newer".
  - "Chat not found" errors with cached identifiers are fixed.
  - Minimum macOS is 10.15.
- The project went quiet from May 2025 to Oct 2026. It's active again now: issues and PRs were merged through 2026-11-15 (#901 multipart text runs, #896 iCloud Messages sync endpoint, #893 richLink).
- Private API helper repo: https://github.com/BlueBubblesApp/bluebubbles-helper was rewritten on 2026-05-06, and the repo was last pushed on 2026-07-11.
- A Homebrew cask mirror marks the cask as disabled from 2026-09-01 because it failed Gatekeeper. This predates the 2026-10-27 re-notarization, so install from the GitHub release rather than brew.

### macOS 26 Tahoe / 27 compatibility (open issues, Nov 2026)
- **#902 (2026-11-18):** On macOS **27.2.1 (26B131)**, exactly the laptop's build, the setup wizard's Accessibility instructions are wrong. The setting moved to "Device Control and Data Access". The workaround is `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.
- **#899 (2026-11-10):** On macOS 27.0.1 (the Mini's version) with SIP off, the helper connects and the Private API works, but Find My friends come back empty. Core messaging is not reported broken on 27.
- **#898 (2026-11-08):** On macOS 26.6.2, the bundled `BlueBubblesHelper.dylib` aborts Messages when the API edits a message. A helper built from `development` doesn't crash. Typing, private-api send and tapback all returned 200.
- **#890 (2026-10-27):** On Tahoe, Apple's `dasd` can deadlock and starve `imagent`. The helper keeps reporting `helper_connected: true` while sends fail with "Message not found in database after 60 seconds" and inbound messages never reach chat.db. The fix is `sudo launchctl kickstart -k system/com.apple.dasd`. The reporter saw this on multi-account Mac minis (4 times across ~20 Macs in 6 weeks) and never on Sequoia. **This argues for a staleness watchdog whatever path is chosen** (see also #897, a feature request to alert when chat.db is more than 24 h stale).
- **#895 (2026-10-29):** Messages crashes when sending a URL. It's open with no detail.

Overall: plain send/receive works on 26/27. The Private API on 26/27 works but is fragile.

### Requirements
- **A Mac running Messages.app, signed into the Apple ID, in a logged-in GUI session.** BlueBubbles is an Electron app that reads `chat.db` and drives Messages.
- **Full Disk Access**, to read `~/Library/Messages/chat.db`.
- **Accessibility** ("Device Control and Data Access" on 27), plus Automation of Messages, for the AppleScript send path.
- **SMS/MMS needs Text Message Forwarding** from the owner's iPhone to that Mac. Otherwise only iMessage (blue bubbles) works.
- For the Private API only:
  - SIP must be **fully disabled** with `csrutil disable` from Recovery. The docs describe no partial configuration.
  - Library validation must also be turned off: `sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true`.
  - Source: https://docs.bluebubbles.app/private-api/installation, retrieved 2026-11-21. The docs say "Disable SIP at your own risk", compare it to jailbreaking, and note that it disables iOS apps on Apple Silicon.

### API surface
Authentication is a password passed as a query parameter (`?guid=`, `?password=` or `?token=`). Source: https://docs.bluebubbles.app/server/developer-guides/rest-api-and-webhooks.

The route list below comes from `packages/server/src/server/api/http/api/v1/httpRoutes.ts` on master, read 2026-11-21. Routes are tagged **PAPI** where the source attaches `PrivateApiMiddleware`, or where the router uses the private-api method internally.

| Area | Endpoints | Private API? |
|---|---|---|
| Chat list / metadata | `POST /chat/query`, `GET /chat/:guid`, `GET /chat/:guid/message`, `GET /chat/count`, `GET /chat/:guid/icon` | No |
| Message query | `POST /message/query`, `GET /message/:guid`, counts | No. Full-text search on Ventura+ uses PAPI when it's enabled. |
| Send text | `POST /message/text` with `method: apple-script \| private-api` | No (AppleScript). Effects, subject, and reply via `selectedMessageGuid` need PAPI. |
| Send attachment | `POST /message/attachment`; `POST /message/multipart` | Attachment: no (AppleScript). Multipart: effectively PAPI. |
| Download attachment | `GET /attachment/:guid/download`, `/blurhash`, `/live` | No. `/download/force` is PAPI. |
| Tapbacks (send) | `POST /message/react` | **PAPI** |
| Tapbacks/edits/unsends (receive) | arrive as message / updated-message events from chat.db | No (read from DB). The mautrix roadmap notes edits/unsends need server ≥ 1.9.6. |
| Edit / unsend | `POST /message/:guid/edit`, `/unsend` | **PAPI**, macOS 13+ |
| Typing | `POST`/`DELETE /chat/:guid/typing`; inbound typing events | **PAPI** |
| Read receipts | `POST /chat/:guid/read`, `/unread`; inbound "chat read status changed" | Marking read: **PAPI**. Delivered/read status of your own messages arrives in updated-message events. |
| Group admin | participant add/remove, leave, rename (`PUT /chat/:guid`), set icon | **PAPI** |
| New chat | `POST /chat/new` | Works with AppleScript but flaky. PAPI is recommended. |
| Handles / contacts | `GET /handle/query`, `/handle/:guid`, `GET /contact`, `POST /contact/query` (macOS Contacts, optionally with avatars) | No. `/handle/availability/imessage` is PAPI. |
| Server | `/server/info`, `/ping`, logs, restart, `/icloud/*` | Mostly no |

**Webhooks** (server ≥ 1.0): new message, message updated (delivered/read/edited), message error, group name change, participant added/removed/left, chat read status changed, typing indicator, server update, URL change. A socket.io stream carries the same events.

I found no webhook signing or HMAC in the docs. Treat inbound webhooks as unauthenticated hints: give the receiver a secret path token, and have Prism re-fetch the message from the API by GUID before trusting it.

### Security implications of SIP off on an always-on server Mac
- **SIP off removes the kernel-enforced protection** of system files, `/System`, Apple-signed processes against debugger/injection attaches, and TCC databases. It's the protection that stops a compromised user-level process from becoming persistent and invisible.
- **Turning off library validation globally** lets unsigned dylibs load into any process that would otherwise reject them. The helper needs this to inject into Messages, but so would malware.
- **The Mini also runs** prism-server, the cloudflared tunnels (prism-tunnel, minutes-prism-tunnel), Docker/Colima with Synapse and five bridges holding live WhatsApp/Telegram/Discord/Meta/X sessions, buzz-prod, and the Omni agent with its secrets. A single compromise on a SIP-off Mini reaches every bridge session and the owner's Apple ID. That's too much blast radius.
- **Recovery needs physical access.** On Apple Silicon, `csrutil` changes need Recovery (hold the power button, and on newer releases hold Left Shift at Continue). The Mini is headless, so every macOS major update means someone at the machine to re-verify or redo SIP and library-validation state.
- **SIP off is a common reason updates break the helper.** Running SIP-off also means deferring macOS security updates until the helper catches up.

## 2. Integration paths compared

### (a) mautrix-imessage with the BlueBubbles connector → Matrix rooms
Status as of 2026-11-21:
- **mautrix/imessage is on the legacy (non-bridgev2) architecture.** Commits: 2026-05-14 "Update mautrix-go", 2025-07-15 CI and room v11, 2025-05-29 wsproxy docs, 2024-11-27 deps.
- **The `imessage/bluebubbles` connector's last commit was 2024-06-01** (#209, tapback backfill). Source: GitHub API.
- **The ROADMAP shows the BlueBubbles connector is the most complete.** It supports replies, reactions, edits, unsends, read receipts and typing in both directions, but backfilling tapbacks isn't supported. The roadmap also notes that Barcelona (mac-nosip) "is no longer maintained". Source: https://github.com/mautrix/imessage/blob/master/ROADMAP.md.
- **The README says "A websocket proxy is required to receive appservice events from the homeserver"**, so mautrix-wsproxy would be a sixth bridge component plus a proxy.
- **Beeper's options don't help.**
  - bbctl lists `imessage` (mautrix-imessage) and `imessagego` (beeper-imessage) but "can not be used with any other Matrix homeserver, like self-hosted Synapse". Source: https://github.com/beeper/bridge-manager, pushed 2026-11-20.
  - beeper/imessage is archived (last push 2024-04-05).
  - Beeper's current consumer iMessage is on-device inside Beeper Desktop on a Mac, and it isn't a bridge you can point at Synapse (Beeper help center).
  - docs.mau.fi doesn't mention bridgev2 for iMessage. No bridgev2 iMessage successor exists for self-hosters.

Pros:
- Prism's Matrix ingest, people linking, the `/matrix/send` executor, Comms and the guard (`send.chat-api` already blocks `/_matrix/client/.../send`) all work unchanged.
- The only code change would be adding `[/^@imessage_/i, "imessage"]` to `detectPlatform` (worker/matrix.ts:406) and to `shortSender`.
- With the Private API the feature set is rich.

Cons:
- It's a stale codebase with one maintainer and a legacy architecture.
- It adds a wsproxy plus a Go bridge (about 40–80 MB) to the memory-constrained box.
- It still needs BlueBubbles underneath anyway.
- It adds latency: iMessage → chat.db → BB → bridge → Synapse → Prism sync.
- Room/portal mapping bugs (chat merging, SMS vs iMessage GUID splits) are hard to fix in someone else's Go.
- Identity mapping is lossy: you get ghost users rather than phone/email handles.

### (b) Prism ↔ BlueBubbles REST/webhooks directly
Pros:
- It uses the actively maintained surface (Oct–Nov 2026 releases and fixes).
- There's one fewer hop, so sub-second ingest via webhook.
- It exposes first-class data: chat GUID, service (iMessage/SMS/RCS), handle addresses, delivered/read, attachments, and macOS Contacts names and avatars.
- There's no extra container. Only the BB Electron app is added (roughly 250–400 MB RSS, estimated, no measurement here).
- Prism already has a pluggable worker pattern (gmail, proton, fireflies and others), and its approval gate is generic.

Cons:
- It's new code: worker, send route, executor mapping, Comms features, guard rules.
- Comms gets iMessage through Prism's API, not via Matrix.
- Reactions, typing and read features have to be modelled per platform.

### (c) Other
- **OpenBubbles** (https://github.com/OpenBubbles/openbubbles-app, pushed 2026-07-06) is a client ecosystem built around Apple's protocol (rustpush) with a hosted registration relay. It isn't a server API for Prism, and it carries account-ban risk similar to Beeper Mini. Not suitable.
- **Beeper Mini-style direct protocol** (pypush, rustpush) needs Mac/iPhone registration data. Apple shut down Beeper Mini (Dec 2023–Jan 2024) and banned linked Macs. The risk to the owner's real Apple ID is unacceptable.
- **AirMessage** is a similar Mac-server model with a less open API. There's no advantage over BB.
- **Reading chat.db directly** (or the `imsg` CLI, v0.7.3, which noted and fixed a Tahoe regression) is a good read-only path, but it's receive-only. Sending would need AppleScript, which the guard rightly blocks, and the schema (attributedBody blobs) changes between OS versions. BB already does this work.

### Comparison

| | (a) mautrix-imessage + BB | (b) Prism ↔ BB direct | chat.db direct |
|---|---|---|---|
| Inbound text/media | yes | yes | yes |
| Inbound tapbacks/edits/unsends | yes | yes | yes (parsing) |
| Send text/attachment | yes | yes (AppleScript, no SIP change) | no |
| Send tapback/typing/read/edit | PAPI | PAPI | no |
| Avatars/names | ghost profiles | Contacts API with avatars, plus Prism people | Contacts DB |
| Latency | +1–2 hops | webhook, ~1 s | polling |
| Extra RAM on Mini | BB + bridge + wsproxy | BB only | none |
| Maintenance | stale upstream | owned code, active upstream | own parser |
| Prism code change | tiny | moderate | moderate |
| Guard change | none needed beyond BB API | BB API block needed | n/a |

In every option, **outbound messages appear as the owner**, from their Apple ID (phone number or email) and in their own Messages history on all their devices. That raises the stakes of the approval gate: there's no "bot" identity on iMessage.

## 3. Host choice

### Read-only checks (run 2026-11-21 ~19:10)

| | Mini (`home-server`) | Laptop (local) |
|---|---|---|
| macOS | 27.0.1 (26A434) | 27.2.1 (26B131) |
| SIP | enabled | enabled |
| BlueBubbles installed | no | not checked |
| Messages.app | /System/Applications | n/a |

More on the Mini:
- **Messages data:** `~/Library/Messages` exists. `chat.db` is 337 MB with a 4 MB WAL, modified 2026-11-21 18:35. Attachments directory present. **Messages is signed in and actively syncing.** Which Apple ID it is wasn't checked, by design. The `MobileMeAccounts` count read 0, which is probably a key-format change on 27 and not conclusive.
- **RAM:** 16 GB, with 69% free per `memory_pressure`. It's been up 8 days, has 2 GUI users logged in, and load is about 2.2.
- **Docker:** synapse 314 MB, matrix-db 334 MB, the 5 bridges 18–70 MB each, buzz-prod about 160 MB. The Colima VM limit is 2.83 GiB.
- **pm2:** bridge-watchdog, minutes-prism-staging, minutes-prism-tunnel, prism-server, prism-tunnel, studiolink-host online; minutes-public-site stopped.
- Over SSH the `~/Library/Messages` listing succeeded, which suggests the SSH session has Full Disk Access. That's worth knowing for the guard.

### Options
- **Mini, SIP on (recommended for phase 1).**
  - It's always on, already signed into Messages, on Tailscale, and has memory headroom for one Electron app.
  - No security posture change is needed.
  - Needs: FDA plus Accessibility for BlueBubbles, auto-login or a persistent GUI session, and "Prevent sleep".
  - Risk: it puts the owner's iMessage identity next to the agent, which the guard must handle (section 5).
- **Laptop.** Its availability isn't guaranteed (sleep, travel, lid closed), so it's a poor fit for an always-on channel. It's fine for development and testing of the adapter.
- **Dedicated cheap Mac (phase 2, only if the Private API is wanted).**
  - A used M1 Mac mini (8 GB is enough), signed into the same Apple ID, with SIP off and nothing else on it, reachable only over Tailscale ACL from the Mini.
  - The isolation is the point: a compromise exposes the Apple ID session, not the bridges or the vault.
- **macOS VM.**
  - Apple's Virtualization framework supports Apple Account sign-in only when host and guest are both macOS 15+ on Apple Silicon and the VM was built from a 15+ IPSW (eclecticlight.co, 2024-07-12 and 2024-09-18; Parallels docs).
  - iMessage in VMs is mixed: a Parallels forum report of "unknown error" fixed by disabling the host firewall, and a 2026 Jamf thread where a Managed Apple ID failed in a VM but a personal one worked.
  - BB issue #898 shows someone running BB with SIP off in a macOS 26.6.2 guest, so it can work.
  - On the 16 GB Mini a VM would cost 4–8 GB, which isn't affordable. It's also riskier for the account, since the VM gets a new hardware identity if it's moved.
  - It's a plausible test bed on the laptop, not production.

## 4. How BlueBubbles fits Prism's model

### Platform and thread mapping
- **Platform id:** `imessage`. Add `sms` (and `rcs` if BB reports it) as a `service` metadata field rather than a separate platform, because the same contact can flip between services.
- **Thread key:** the BB **chat GUID**, e.g. `iMessage;-;+15551234567`, `SMS;-;+1555…` or `iMessage;+;chat123456789` for groups.
  - Store it as `metadata.imessageChatGuid`, alongside the existing `platform` and `lastMessageAt`.
  - Path: `vault/messages/imessage/<sanitized display name>`, mirroring `vault/messages/<platform>/<room>` (worker/matrix.ts:10, 1244).
  - Because macOS keeps separate chats per service for the same person, an optional "merge by handle" rule should write one thread note per person for 1:1 chats, with the GUID list in metadata. mautrix calls this "chat merging", and it's the most common source of duplicate threads.
- **Group chats:** the `;+;` GUID, `displayName` if set, otherwise participant names. Participants come from chat `participants[].address`.
- **Line format:** reuse `formatStamp` and the existing appendToThread line format, so the desktop `message_sync` readers and Omni treat it the same. Tapbacks can be rendered as compact lines (`[..] Alice ❤️ "…"`) and edits/unsends as annotations, as Matrix reactions already are.

### Ingestion
1. **Webhook first.** BB posts `new-message` / `updated-message` to `http://127.0.0.1:<prism>/api/ingest/bluebubbles/<secret>`. Prism treats the payload as a hint and re-fetches `GET /message/:guid?with=chat,handle,attachment` before writing.
2. **Catch-up poll.** A scheduler job calls `POST /message/query` with `after: <cursor>` every few minutes and on startup, so a missed webhook or restart never loses messages. The cursor lives in sync-store, like the Matrix next_batch.
3. **Staleness watchdog** (the #890 failure mode). If BB `/server/info` is healthy but no message has been seen in N hours while the Mini is up, or a send returns "Message not found in database after 60 seconds", alert the owner and mark the source degraded. The existing bridge-watchdog pm2 process is the natural home for this.
4. **Backfill.** chat.db is 337 MB, so backfill per chat with a date floor (for example 90 days) rather than everything. Respect the existing sync-visibility and pass-skip rules.
5. **Attachments.** Download via `/attachment/:guid/download`. HEIC needs converting for Comms/web, and BB offers conversion options. Store them with the same attachment conventions as Matrix media.

### Contacts and avatars
- **BB `GET /contact` / `POST /contact/query`** returns names, phones, emails and optional avatars from the Mini's macOS Contacts. That is only as good as the Mini's Contacts, which syncs via iCloud if the same Apple ID is signed in there.
- **Prism people notes stay canonical.** Call `findOrCreate(vault, name, { imessageHandle: "+1555…", platform: "imessage" })` (compare worker/matrix.ts:729 with `matrixId`), matching on normalised E.164 phone or lowercased email. Use the BB contact name only as a creation hint, behind the same review/`MAX_MEMBERS_FOR_PERSON_CREATION` rules.
- Cache avatars on the person note, not per thread.

### Sends through the approval executor
- **New route:** `POST /api/actions/imessage/send`, with `action: "imessage.send"`, `family: "imessage"`, `requireKey: true`, and its own rate limit. In `prepare`, keep the same `origin === "human" && via !== "device"` refusal as `/matrix/send` (routes/actions.ts:757).
- **Validation:** check the `chatGuid` against a known thread note. Don't allow free-form new recipients in phase 1, because `/chat/new` by AppleScript is flaky and is the riskiest path.
- **Run:** call BB `POST /message/text { chatGuid, message, method: "apple-script", tempGuid }`. Use `tempGuid` as an idempotency key, then confirm by querying for the resulting message. The existing `ExecOutcome` `not_sent` semantics fit: the send is "not sent" only if BB rejected it before handing it to Messages.
- **Approvals:**
  - In `omni/approvals.ts`, extend kind `message` with a `platform` or target discriminator. Alternatively add kind `imessage` mapping to `{ name: "prism-live-actions:imessage", enabled: config.actionsImessageEnabled }`.
  - `liveActionRequest` then returns `{ path: "/api/actions/imessage/send", body: { chatGuid, body } }`.
  - The approval card must show **"iMessage, from your Apple ID, to <handle/name>"** and the exact text.
- **Owner-typed sends from Comms** go through the same route with `via: device`, so they're the owner's own action, as with Matrix today.
- **Reactions** (phase 2, PAPI only) would add `/api/actions/imessage/react`, mirroring `/matrix/react`.

### Comms (SwiftUI thin client)
- No iMessage-specific transport is needed. Comms reads Prism threads and calls Prism actions.
- It needs per-platform capability flags from Prism, so it can hide typing, read, tapback and edit controls when the source lacks the Private API. `GET /server/info` gives `private_api` / `helper_connected` to drive this.

### Omni guard table changes
`hermes/plugins/omni-bridge/guard_table.py` and `paths.py`. Today the guard blocks AppleScript to Messages (`send.applescript`, line 148), Matrix and other chat APIs (`send.chat-api`, line 193), and treats `~/Library/Messages` as secret (paths.py:97). **None of these catch BlueBubbles.**

Add:
1. **`send.bluebubbles` (BLOCK, propose="message")** for any HTTP call to the BB host/port, or text matching `/api/v1/(message/(text|attachment|multipart|react|[^/\s]+/(edit|unsend|notify))|chat/(new|[^/\s]+/(typing|read|unread|leave|participant|icon))|facetime|icloud)`. Simplest and safest is to block *all* `/api/v1/` traffic to the BB port from the agent. The agent reads iMessage only through the vault and Prism, like Matrix (`read.matrix`).
2. **A secrets rule** for BB's config and password: `~/Library/Application Support/bluebubbles-server/` (config DB with the server password) and any Prism secret-store entry of kind `bluebubbles`. Add these to paths.py next to `~/Library/Messages`.
3. **A rule against launching or controlling the BlueBubbles app** (`open -a BlueBubbles`, killing or restarting it, `defaults write` on its domain), as APPROVE or BLOCK.
4. **Updates to the `send.chat-api` and `omni_propose` guidance text,** so the agent knows iMessage drafts are `omni_propose(kind=message, platform=imessage, chatGuid=…)`.
5. **Network-level defense:** bind BB to `127.0.0.1` (or the Tailscale IP with a Tailscale ACL allowing only prism-server), and give the BB password only to prism-server's secret store, not to any env the agent can read. The guard is a second line of defense, not the only one.

## 5. Risks
- **Identity:** every send is the owner, from their real number, mirrored to their iPhone. A gate bypass is maximally embarrassing and irreversible. Unsend isn't available without the Private API.
- **Silent failure on Tahoe/27** (#890): a send looks accepted but is never delivered. The watchdog and confirm-after-send are required.
- **Apple account risk:** low for BB on a real Mac signed in normally. It's high for VMs or third-party registration (Beeper Mini, OpenBubbles).
- **GUI-session dependency:** if the Mini reboots to the login window (FileVault, updates), BB and Messages are down until someone logs in. Check whether FileVault is on and auto-login is possible.
- **macOS updates:** the Mini is at 27.0.1 and the laptop at 27.2.1. The 27.2 Accessibility relocation (#902) affects setup, and any update can break AppleScript send. Pin updates on the Mini until they're tested on the laptop.
- **Privacy:** iMessage history flows into the vault, and through it to Omni. That's a larger set of personal data than the existing bridges, including 2FA codes and bank texts by SMS. Filters are needed (for example, drop short-code senders and OTP patterns before vault write).
- **Upstream maintenance gap:** BB had a 17-month quiet period (May 2025 → Oct 2026), and could again.
- **Memory:** roughly +300–500 MB for BB plus Messages (estimated). That's acceptable at today's 69% free but should be watched alongside Synapse.

## 6. Open questions for the owner
1. Which Apple ID is signed into Messages on the Mini: your personal one, or a separate one? Does the Mini receive SMS (Text Message Forwarding from your iPhone)?
2. Is basic send/receive enough, or do you want tapbacks, typing and read receipts badly enough to buy or run a separate SIP-off Mac?
3. Should iMessage history be backfilled into the vault? How far back, and should Omni see all of it or only threads with people who have person notes?
4. Should Omni be allowed to *propose* iMessage replies at all, or should iMessage be owner-typed-only from Comms at first? The latter is the lowest risk.
5. Is FileVault on for the Mini, and is auto-login acceptable, so BB survives reboots?
6. Is it OK to pause macOS updates on the Mini (currently 27.0.1) until each one is tested on the laptop?
7. Should OTP and short-code SMS be filtered out of the vault?

## Sources (accessed 2026-11-21)
- BlueBubbles Server releases (v1.9.12, 2026-10-27; v1.9.9, 2025-05-16; v1.9.8, 2024-11-20): https://github.com/BlueBubblesApp/bluebubbles-server/releases
- BlueBubbles issues #890 (2026-10-27), #895 (2026-10-29), #897 (2026-11-03), #898 (2026-11-08), #899 (2026-11-10), #902 (2026-11-18): https://github.com/BlueBubblesApp/bluebubbles-server/issues
- BlueBubbles route table (master): https://github.com/BlueBubblesApp/bluebubbles-server/blob/master/packages/server/src/server/api/http/api/v1/httpRoutes.ts
- BlueBubbles Private API docs and installation: https://docs.bluebubbles.app/private-api/ and https://docs.bluebubbles.app/private-api/installation
- BlueBubbles REST and webhooks: https://docs.bluebubbles.app/server/developer-guides/rest-api-and-webhooks
- BlueBubbles helper (rewrite 2026-05-06): https://github.com/BlueBubblesApp/bluebubbles-helper
- Tailscale blog on BlueBubbles (2026-01-22): https://tailscale.com/blog/bluebubbles-tailscale-imessage-android-pc-no-port-forwarding
- mautrix-imessage (last commit 2026-05-14; BB connector last 2024-06-01): https://github.com/mautrix/imessage, ROADMAP.md
- mautrix docs: https://docs.mau.fi/bridges/go/imessage/index.html
- Beeper bridge-manager (bbctl, Beeper-server-only, pushed 2026-11-20): https://github.com/beeper/bridge-manager
- beeper/imessage (archived, 2024-04-05): https://github.com/beeper/imessage
- Beeper on-device iMessage guide: https://beeper.helpjuice.com/en_US/chat-networks/new-imessage-on-macos-getting-started-guide
- Beeper drops iMessage after Apple bans linked Macs (Jan 2024): https://www.androidcentral.com/apps-software/beeper-drops-imessage-integration-after-apple-bans-linked-macs
- OpenBubbles: https://github.com/OpenBubbles/openbubbles-app
- macOS VM Apple ID: https://eclecticlight.co/2024/07/12/sequoia-virtualisation-and-apple-id/ ; https://eclecticlight.co/2024/09/18/build-a-vm-with-icloud-access-in-sequoia-on-apple-silicon/ ; https://forum.parallels.com/threads/imessage-sign-in-fails-on-sequoia.365289/ ; https://community.jamf.com/general-discussions-2/managed-apple-id-works-for-imessage-on-bare-metal-but-fails-in-macos-vm-same-hardware-58672
- Local code: prism/apps/server/src/worker/matrix.ts (detectPlatform :406, findOrCreate :729, thread path :1244), routes/actions.ts (/matrix/send :748), omni/approvals.ts (executor and liveActionRequest :383–399); agent/hermes/plugins/omni-bridge/guard_table.py (:148, :193), paths.py (:97).
