# Comms — Decisions

Each entry records the choice, who made it, the alternatives considered, and why.

## D1 · Thin native client over a new Prism "comms" module (owner, 2026-11-21)
**Approaches considered:**
1. **Thin client over a new Prism Conversations layer.** Chosen.
2. **Comms as a section of the Omni app.** It would ship first and reuse Omni's sign-in, push and approvals. Rejected: it mixes two products (Omni's spec says "not a chat app"), with one icon, one notification stream and one release train.
3. **App speaks Matrix directly via matrix-rust-sdk (Element X).** Ruled out:
   - Synapse is loopback-only on the Mini.
   - An in-app Matrix token is an ungated send path.
   - Email and iMessage aren't on Matrix.
   - The Swift package only declares iOS.

**Why 1:** it fixes the root causes the owner named (formatting, reactions, avatars, names) once, server-side, for both Comms and Prism. It also keeps one gateway for every send. The owner added: carry the insights and UX improvements back into Prism (ARCHITECTURE §10).

## D2 · No Matrix SDK in the client (v1) (builder's call, from research)
A `ChatBackend` protocol leaves room for a read-only Rust SDK backend later, if offline-first or on-device E2EE ever matters.

## D3 · Email and multi-network merging: "merge when confident" (owner, 2026-11-21)
**Rule:** chats and email from one person merge into one conversation only when Prism's strong-key identity matching is confident. Otherwise they stay separate. Email conversations are titled with the sender's name, with the subject as the preview.

**Rejected:**
- Always merge per person: one wrong match merges two people.
- Never merge (Beeper-style per channel): a busier list.

## D4 · All bubbles blue and grey (owner, 2026-11-21; amended same day)
**Amended:** the owner wants outgoing bubbles in a **different shade of blue per platform**, keeping Apple's clean colours. Incoming stays grey and there is still no green. The palette lives in `design/tokens.json` `color.outgoingByNetwork`. The rule below is superseded where it says one blue everywhere.

**Rule:** outgoing is iMessage blue and incoming is grey, on every network, including SMS (Apple would use green; the owner wants no green).

The network is signaled by:
- the avatar badge;
- the composer placeholder;
- the timestamp caption.

## D5 · BlueBubbles connects directly to Prism, not via a Matrix bridge (owner, 2026-11-21)
**Why not a Matrix bridge:**
- mautrix-imessage is legacy, and its BlueBubbles connector is untouched since 2024-06.
- Beeper's `bbctl` needs Beeper's own server.

**How it works instead:** Prism gets a `BlueBubblesSource` alongside Matrix, plus a gated `actions/imessage.ts`. BlueBubbles is adopted for Omni and Prism too: iMessage threads flow into the vault through the same ingest owner.

## D6 · BlueBubbles on the Mini with SIP on; basic features first (owner, 2026-11-21)
**What works in v1:**
- Send and receive text and attachments.
- See incoming tapbacks, edits and unsends.

**What doesn't:**
- Sending tapbacks, typing or read receipts. These need the Private API, which means SIP off and is buggy on 26/27.

**Revisit:** a dedicated SIP-off Mac later, if sending tapbacks matters.

**Reopened (owner, 2026-11-21):** "tapback might be a reason I do or do not use this". Sending iMessage tapbacks is now treated as adoption-critical. The decision on a dedicated SIP-off Mac for the BlueBubbles Private API is to be made before Phase 3 planning. The production Mini stays SIP-on either way. SIP off on the production Mini was rejected: one compromise would expose every bridge session, the vault and the agent secrets.

## D7 · Reuse Omni's attention model (builder's call)
"Needs you" in Comms reads `/api/omni/cards`, and approvals use `/api/omni/approvals`. There is no parallel card or nudge system.

## D8 · Repo and platform (builder's call)
- **Repo:** `~/dev/comms`, laid out like Minutes (`Apps/` XcodeGen, `CommsKit/` SwiftPM, `docs/`). Server code lives in `~/dev/prism`.
- **Platform:** deployment target macOS 26 / iOS 26, built with the Xcode 27 SDK.
- **Bundle ID:** `com.example.comms`.
- **Sign-in client:** `comms-native` (`comms://auth/callback`) with a restricted grant.

## D9 · Omni never speaks in the chat (owner hard line, applied)
- `@Omni` is a private instruction.
- Drafts come back as dashed bubbles.
- Sending needs Approve & Send of the exact text (digest-bound, biometric), or the owner editing it and sending it as their own message.

## D10 · Read receipts and typing are a toggle (owner, 2026-11-21)
- The owner wants to turn read receipts on and off.
- Implemented as a global toggle with optional per-network overrides. Typing follows the same setting.
- Default off. An explicit Mark Read always sends a receipt where supported.

## D11 · New conversations: email + iMessage/SMS only in v1 (owner, 2026-11-21)
Bridged chat networks are reply-only in v1. Starting a new chat on them needs bridge-specific provisioning, so it comes later.

## D12 · Search: text across all history, media recent (owner, 2026-11-21)
- Text search reaches all history through the vault.
- The Photos and Links tabs cover about 90 days at first.

## D13 · iMessage into the vault, Omni may draft iMessage (owner, 2026-11-21)
- About 90 days of history is backfilled.
- One-time codes and short-code senders are excluded.
- Omni drafts need approval of the exact text, as on every channel.

## D14 · Builder calls from the review (builder)
See ARCHITECTURE §11a:
- urgency at arrival comes from deterministic rules, refined by the model later;
- "favourites" means pins plus `priority_weight ≥ 0.7`;
- laptop staging, then flag-gated production canaries;
- audit records `origin: owner-typed | omni-approved`.

## D15 · Audio messages are in scope (owner, 2026-11-21)
Recording and sending voice messages is a Phase 2 requirement: hold-to-record, waveform, preview, and send as a voice message where the network supports it. Playback and transcripts for received audio are Phase 1/2.

## D16 · Avatars for everyone, including groups (owner, 2026-11-21)
Every conversation and every group sender shows an avatar. Precedence is per PRD §5.9. Groups without a photo get a member cluster. This is an explicit acceptance check in Phases 1 and 2.

## D17 · Using Comms cleans up contacts in the vault (owner, 2026-11-21)
**Owner:** "Using it should help make the parachute vault more accurate." Comms becomes the everyday front end for contact cleanup, focused on the people the owner talks to most.

**Signals Comms surfaces:**
- **Unlinked frequent senders.** A DM counterpart with no person note, ranked by message volume and recency, gets a gentle "Who is this?" prompt in the Details inspector, plus a "People to tidy" list in the sidebar. Choices: link to an existing person, create a new person, or ignore.
- **Probable duplicates.** Prism's existing `identity_candidates` review queue (`/api/admin/people/*`, `people-merge.ts`) is shown as "Same person?" cards with evidence (shared phone, email or handle). Choices: merge, keep separate, or decide later.
- **Missing channels on a known person.** When a person is linked, Comms offers to add the WhatsApp, Telegram, iMessage or email handle seen in the thread to their note (`channels.*`, `matrixId`, phone in E.164).

**Rules:**
- **Nothing is written to the vault without an explicit owner confirmation.** There are no automatic merges on names (same rule as D3).
- Every write goes through Prism's existing identity and person-merge services, with their audit trail. There is no parallel contact store.
- Every confirmed link immediately improves the merged person threads (D3), names and avatars (PRD §5.9), triage and owed-reply evidence for Omni, and the routines that read person notes.
- Undo is available. Unlink restores the previous person-note fields, which are kept in the audit trail.

**Phasing:** Details-inspector "Who is this?" plus link/unlink with channel write-back in **Phase 2**; "Same person?" merge cards and the "People to tidy" list in **Phase 2**; email-identity linking with Phase 5.

## D18 · Comms becomes the one place that notifies (owner, 2026-11-22)
"Eventually, I will want to turn on notifications for this app and turn off notifications for all the other messaging apps. I'd like to be able to easily filter for the different tags and only have notifications on for messages that are deemed important. Merging all my comms also merges all of the spam messages together."
- Notifications come from Comms (Prism APNs / push relay), driven by Prism's triage status. By default only important threads notify (Needs attention = urgent + action-required). Strangers, low priority, social and spam never notify.
- The triage filters (Phase 2a) are the base for this. Per-status notification toggles live in Settings.
- Open design point: the classifier runs hourly, which is too slow for notifications. Phase 2b needs a fast path that classifies on arrival, or a rule that DMs from known people notify at once and everything else waits for the verdict.
- Spam handling is part of the same work: stronger strangers/spam routing, and one-tap "Mark as spam/low" that writes back to the vault tags.
- Update (owner, 2026-11-22): "we need full previews on notifications and we should be able to change notifications based on tag type or folder." Full previews stay the default. Every triage tag (Urgent, Action Required, Informational, Low Priority, Social, Reviewed, Handled, Not Yet Sorted) is now a switch; only Needs attention is on by default. Each owner folder has Default / All Messages / None. Precedence: thread Mute > folder None > folder All Messages > tag and network switches. Unknown senders notify only through an All Messages folder; spam never notifies.

## D19 · Backfill Comms into Prism Client: Prism's look, Comms' behaviour (owner, 2026-11-22)
"i think we can safely integrate best practices and design patterns from Comms back into the Prism Client app so that we have the best of all worlds." The owner chose **Prism's look, Comms' behaviour**:
- Prism's Messages screens keep Prism's design system.
- They adopt Comms' data and behaviour: they read from `/api/comms`, and get grouping/tails/timestamps, avatars, media, reactions, triage multi-filters, contact pages with shared chats, and sending through the comms gate.
- Sending works only on the signed-in Prism Client desktop app (device token). The browser/PWA stays read-only, with "Open in Comms".
- Staged after phase 2b ships: (1) list and threads on /api/comms; (2) filters, contact pages and the grouping rules; (3) composer, attachments and reactions; (4) Omni draft bubbles. See ARCHITECTURE §10.
