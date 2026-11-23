# Bubble calibration and tokens — v0 (provisional, owner to confirm)

`design/tokens.json` is the single source of truth for bubble geometry, spacing, list metrics and colours. Every value below is **v0: provisional, owner to confirm** (ruling R4). Date: 2026-11-21.

## Sources

- **kit**: Apple Design Resources Sketch files, downloaded headlessly from the public Sketch share links on developer.apple.com/design/resources. No login was needed. Parsed as JSON; nothing was executed.
  - **"Messages" template** (iMessage apps and stickers, iOS 26/27 Liquid Glass look). Its `Symbols` page holds real Messages bubble symbols: `Chat / Light / Message Bubble / Text - Friend|You`, `_Bubble`, `Chat List / Light`, `Avatar/Person`, `Sender Name`, `Time Stamp`. The `Examples` page has full 402 pt transcripts.
  - **iOS 27 UI Kit**: has no Messages components apart from a `Messages Transcript` layout guide (16 pt margins compact, 20 pt regular).
  - **macOS 27 UI Kit**: has no Messages components.
  - These kits are iOS/macOS **27**. The 26 kits are no longer offered. Bubble geometry matches the iOS 26 reference screenshots; see the tail overlay.
- **ref-measured**: pixel measurement (Pillow) on `docs/research/refs/`, then converted to pt with the scale shown. Scales were checked by inner screen width and SF Pro cap height:
  - Newsroom iPhone renders: **1.746 px/pt** (702 px ÷ 402 pt).
  - 9to5Mac device crop: **≈ 3.1 px/pt** (screen 1260 px; cap height 37 px for 17 pt). Device not identified, so this source is used for **shape and ratios** only.
  - Apple Support iPhone guides: **1.107 px/pt**.
  - Mac guide PNG `macos26-guide-window-sidebar-transcript.png`: **≈ 1.0 px/pt**. Checked against the newsroom Mac render at 1.156 px/pt (1748 px ÷ 1512 pt), where row and avatar values agree within 1 pt.
- **HIG-doc**: documented Apple values.
- **estimated**: a judgement call with no direct measurement.

Tools live in `design/tools/`:
- `sketch_find.py` and `sketch_dump.py` read the kit.
- `bubble_geom.py` and `measure_refs.py` do the pixel measurement.
- `tail_path.py` converts the kit tail.
- `render_tail_overlay.py` and `render_palette.py` render the images.
- `palette_lib.py`, `palette_fit.py` and `palette_search.py` search the palette.

Image tools need Pillow; run them with a venv python and `-I`. `check-palette.py` uses only the standard library.

## Values

### color

| Key | Value | Source |
|---|---|---|
| outgoingTop / outgoingBottom | `#37AAFC` / `#2AA0FD` | ref-measured (UX spec §2: guide PNG and device JPEG). **The kit disagrees**: flat `#0088FF` in light mode, and `#4EBAFF→#0088FF` per bubble in dark mode. Kept the measured values because the template uses systemBlue as a placeholder, while real renders and devices show the lighter screen-position gradient. Screenshot value used; verify on device. |
| outgoingMac | `#1896FE` | ref-measured (Mac guide (24,150,254); re-measured (22,149,253)) |
| outgoingByNetwork | table below | iMessage = Apple's exact values above. The other eight were retuned under ruling R15 (bright, clean Apple-like blues) so every check-palette rule passes. See Palette. |
| incomingLight / incomingDark | `#E9E9EB` / `#262629` | ref-measured. The kit agrees within 1 unit (`#E9E9EA` / `#262629`). Phase B: the owner's iOS 27 device (dark) measures `#262629` exactly, so dark now uses it. |
| secondaryLabel | `#8D8D8F` | ref-measured (spec §2) |
| accent | `#0088FF` | ref-measured. Matches the HIG 26 systemBlue and the kit's `_Bubble` fill. |

### bubble (pt)

| Key | Value | Source |
|---|---|---|
| radius | **20** | kit (`Rectangle fixedRadius 20` on every text bubble, including 60–88 pt tall ones). ref-measured fits: 19.8 (9to5, 3.1 px/pt) and 20.2–21.8 (newsroom). A single-line bubble (40 pt) is therefore a capsule. |
| padH | **14** | kit (text x = 14 in a 97 pt bubble). ref: 9to5 text inset 43 px ≈ 13.7 pt. |
| padV | **9** | kit (text y = 9, h = 22, bubble 40). Body 17/22, so a single line is 40 pt and each extra line adds 22. ref: newsroom single-line body 70 px = 40.1 pt. |
| maxWidthRatio | **0.71** of transcript width (≈ 285 pt on 402) | ref-measured bracket. Widest bubble seen is 279 pt, so the ratio is ≥ 0.694. Word-wrap points ("…hours of / 8am", "…I missed / the", "…cousin, / he") put the max below ≈ 289 pt (0.72). The kit `Examples` widest text bubble is 281 pt; the voice bubble is 299 pt (fixed width). |
| gapSameSender | **4** | ref-measured. Newsroom polls: "I'm free…" → "Been a busy year": 8 px with anti-aliased edges excluded, so ≈ 7 px ≈ 4.0–4.6 pt. **The kit `Examples` show 8–10 pt**, but that is a hand-laid template. Screenshot value used; verify on device. |
| gapSenderChange | **10** | kit (`Examples` stack spacing 10) + ref-measured (translation transcript: incoming body bottom → outgoing top 18 px = 10.3 pt) |
| gapGroupSenderChange | **33** | ref-measured (polls: body bottom → next body top = 57 px = 32.6 pt, including the sender-name label; kit `Sender Name` symbol is 17 pt tall) |
| tail.width | **25** | kit (`Tail` shapePath frame width). The path spans x = 7…32 from the outer edge. |
| tail.drop | **7** | kit (the tip is 6.94 pt below the bubble bottom). ref: 9to5 ≈ 20 px ≈ 6.4–6.8 pt. |
| tail.path | see below | kit, exact (`Chat / Light / Message Bubble / Text - Friend` → `Tail`), cross-checked by overlay |

**tail.path convention**:
- Coordinates are bubble-local pt. The origin is the **bottom-outer corner** of the bubble's bounding rect: bottom-left for incoming, bottom-right for outgoing.
- **+x points inward** (toward the bubble's centre). **Mirror x for outgoing.** **+y points down.**
- Commands are `["M",x,y]`, `["L",x,y]`, `["C",c1x,c1y,c2x,c2y,x,y]` and `["Z"]`.
- Fill the tail as a union with the radius-20 rounded rect. The first segments and the closing `L` lie on or inside the body.
- The visible part leaves the bottom edge at x ≈ 22.3, hooks down to the tip at (9.46, 6.94), and rejoins the corner arc at (7, −4.8).
- Unlike older iOS, it does **not** stick out sideways past the bubble edge. Both the reference and the kit confirm this.

Draw it only on the last bubble of a same-sender run (spec §5).

`design/refs/tail-overlay.png` renders the path at 3× next to two reference crops, each normalised so the body is 40 pt:
- 9to5 device: outgoing, mirrored. The outline sits on the reference within about 1 px at 3×.
- Newsroom polls: incoming.

### list (pt)

| Key | Value | Source |
|---|---|---|
| rowHeightIOS | **86.67** | **Phase B: real iOS 27 Messages (iPhone 17 sim, `design/fidelity/apple-ios/list-light.ax.txt`): Cell 402 × 86.7 pt (260 px @3x); the real app wins.** Earlier: ref-measured: guide 98.5 px ÷ 1.107 = 89; filter-menu guide 100 px ÷ 1.107 = 90; MacRumors device ≈ 90. **The kit `Chat List / Light` row is 79 pt** (name 17/22 at y 8, two-line preview 15/20 at y 30). Both references show more vertical padding than the template. Screenshot value used; verify on device. |
| avatarIOS | **45** | kit (`Avatar/Person` 45 × 45) + ref-measured (50 px ÷ 1.107) |
| rowHeightMac | **64** | ref-measured (Mac guide row pitch 64 px at ≈1×; newsroom Mac 74.75 px ÷ 1.156 = 64.7) |
| avatarMac | **40** | ref-measured (guide 41 px; newsroom 46 px ÷ 1.156 = 39.8) |
| pinnedAvatarIOS | **90** | ref-measured (guide 100 px ÷ 1.107 = 90). A device shot suggests ≈ 96, but its scale cannot be pinned down (dark screen against a black bezel). Range 90–96. |
| pinnedAvatarMac | **58** | ref-measured (Mac guide 58 px at ≈1×, sidebar ≈ 262 pt). In the newsroom Mac render the sidebar is 318 pt and pins are 73 pt, so pins scale with sidebar width, at ≈ 0.67 of a column. |
| badge | **10** | kit (`Unread Indicator` 10 × 10, #0088FF). Interpreted as the unread dot. |

### transcript

| Key | Value | Source |
|---|---|---|
| timeHeaderGapMinutes | 60 | estimated (pre-filled in the brief; spec §5) |
| groupAvatar | **30** | ref-measured (polls avatars 53 px ÷ 1.746 = 30.4). The bottom of the avatar lines up with the tail tip of the run's last bubble. |
| jumboEmojiMax | 3 | estimated (pre-filled; spec §5) |
| tapbackBadge | **34** | ref-measured (custom-background render, 🙏 badge 59 px ÷ 1.746 = 33.8). Its centre is ≈ 2 pt inside the trailing edge and ≈ 11 pt above the top of the target bubble. There is a two-dot thought tail toward the bubble. Spec estimate was 28–32. |

### Measured, but no tokens key yet (brief schema is fixed)

- **Typing bubble:** body ≈ 172 × 106 px in the 9to5 crop. Normalised to a 40 pt text bubble in the same image, that is ≈ 58 × 36 pt; at 3.13 px/pt it is ≈ 55 × 34 pt.
  - Dots: 3 × ≈ 8 pt, colour #808080 active and #ABABAD resting.
  - Tail: two circles at the bottom-leading corner.
  - Source: ref-measured.
- **Mac single-line bubble:** **28.5 pt** tall, radius ≈ 14.25 (a capsule). Source: ref-measured, newsroom Mac render at a checked 1.156 px/pt.
  - **Correction (Task 15 fix round 1, ruling R19).** An earlier draft read the Mac guide PNG as ≈ 1 px/pt and gave 26 pt. That PNG is actually **≈ 0.81 px/pt**: its single-line bubble is 23 px.
  - The evidence is Apple's own proportions. Text width ÷ bubble height is 69/23 = 3.00 in the guide, and bubble width ÷ height is 6.96. A 13 pt body in a 28.5 pt bubble reproduces both ratios; 26 pt gives 3.31 and 7.69.
  - The 28.5 pt value agrees with the newsroom render. Guide-derived Mac values are therefore scaled by 28.5/23 (= 1/0.807). In `BubbleMetrics.mac`, that gives padH 12, badge 27, rise 9, group avatar 27, avatar gap 7, sender-change gap 10, and media up to 368 × 483.
  - Apple's padH ÷ height ratio, 0.43, is kept.
- **Side margins:** iOS 16 pt (kit layout guide and `Examples`; ref outgoing right edge 16.6 pt). Regular width 20 pt (kit).

## Palette (ruling R15)

**Rules.** These are the plan's Global Constraints as amended by R15. `design/check-palette.py` checks every shade (top, bottom and mac) of every network, iMessage included, with **no exemptions**:
- HSL hue between 195° and 235°.
- CIELAB L\* within ±12 of the iMessage shade's L\*, comparing like with like (top with top, bottom with bottom, mac with mac).
- CIELAB chroma C\* ≥ 40.
- White-text contrast ≥ 2.5:1 (WCAG). Apple's own blue measures 2.52 at the top and 2.78 at the bottom, so it passes.
- CIEDE2000 ΔE ≥ 5 against the same shade of every other network.

**iMessage** stays exactly Apple's blue: `#37AAFC` → `#2AA0FD`, Mac `#1896FE`.

**How the others were picked.**
- `tools/palette_fit.py` (STEP=3, margin 5.4) searched an sRGB grid of valid candidates.
- It started from hand-chosen anchors: Telegram cerulean `#00A0F0`, X sky `#1E90DE`, Messenger azure `#2478F3`, SMS cobalt-bright `#3F7CF5`, Discord blurple `#5A6FF6`, Matrix cornflower `#4E8CF0`, Email steel-azure `#3A8FD8`. WhatsApp's anchor was `#0098E8`.
- It then moved each anchor the smallest ΔE needed to satisfy every rule.

**Result.**
- Most networks stayed within ΔE ≤ 5 of their anchors.
- WhatsApp is the exception. The cyan side of the band is very narrow: hue ≥ 195° with C\* ≥ 40 at iMessage lightness leaves room for only one colour, and Telegram has it. WhatsApp therefore landed on a bright cornflower, `#7596F3`.
- Each network's **top** and **mac** shades are derived from its bottom shade using iMessage's own Lab offsets (`tools/palette_lib.py`, clipped to sRGB). Every network gets the same gradient behaviour.
- Tightest margins:
  - Messenger and Discord sit at the dark edge of the L\* window, at −11.8 and −11.9.
  - The smallest ΔE is 5.4 (Telegram mac against iMessage mac; X and Email).

Output of `python3 -I design/check-palette.py`:

| Network | Shade | Hex | Hue ° (195–235) | L* | ΔL* vs iMessage (±12) | C* (≥ 40) | White contrast (≥ 2.5) | Min ΔE2000 (≥ 5) | Nearest | Pass |
|---|---|---|---|---|---|---|---|---|---|---|
| imessage | top | `#37AAFC` | 205.0 | 67.0 | +0.0 | 49.8 | 2.52 | 5.5 | x | yes |
| imessage | bottom | `#2AA0FD` | 206.4 | 63.9 | +0.0 | 55.0 | 2.78 | 5.7 | x | yes |
| imessage | mac | `#1896FE` | 207.1 | 60.9 | +0.0 | 60.6 | 3.07 | 5.4 | telegram | yes |
| sms | top | `#6B8BEF` | 225.5 | 59.7 | -7.2 | 56.6 | 3.20 | 5.7 | discord | yes |
| sms | bottom | `#6381F0` | 227.2 | 56.7 | -7.2 | 63.2 | 3.54 | 5.8 | discord | yes |
| sms | mac | `#5B77F1` | 228.8 | 53.8 | -7.1 | 70.0 | 3.92 | 5.8 | discord | yes |
| whatsapp | top | `#7BA0F2` | 221.3 | 66.3 | -0.6 | 46.0 | 2.58 | 5.7 | matrix | yes |
| whatsapp | bottom | `#7596F3` | 224.3 | 63.4 | -0.5 | 52.2 | 2.83 | 5.8 | matrix | yes |
| whatsapp | mac | `#6F8CF4` | 226.9 | 60.5 | -0.4 | 58.6 | 3.12 | 5.9 | matrix | yes |
| telegram | top | `#23AFE3` | 196.2 | 66.9 | -0.0 | 40.1 | 2.53 | 7.8 | imessage | yes |
| telegram | bottom | `#15A5E4` | 198.3 | 63.9 | -0.0 | 43.3 | 2.79 | 6.5 | imessage | yes |
| telegram | mac | `#009BE5` | 199.4 | 60.9 | -0.1 | 47.3 | 3.08 | 5.4 | imessage | yes |
| messenger | top | `#3582F2` | 215.6 | 55.2 | -11.8 | 64.8 | 3.73 | 6.1 | email | yes |
| messenger | bottom | `#2478F3` | 215.7 | 52.1 | -11.8 | 71.4 | 4.15 | 5.7 | email | yes |
| messenger | mac | `#006EF4` | 213.0 | 49.1 | -11.8 | 78.3 | 4.63 | 5.4 | email | yes |
| x | top | `#2B9ADD` | 202.6 | 60.6 | -6.3 | 43.2 | 3.10 | 5.4 | email | yes |
| x | bottom | `#1E90DE` | 204.4 | 57.6 | -6.4 | 48.1 | 3.44 | 5.5 | email | yes |
| x | mac | `#0786DF` | 204.7 | 54.5 | -6.5 | 53.6 | 3.83 | 5.6 | email | yes |
| discord | top | `#6379F5` | 231.0 | 55.0 | -12.0 | 70.8 | 3.76 | 5.7 | sms | yes |
| discord | bottom | `#5A6FF6` | 231.9 | 52.1 | -11.9 | 77.7 | 4.17 | 5.8 | sms | yes |
| discord | mac | `#5065F7` | 232.5 | 49.2 | -11.8 | 84.6 | 4.62 | 5.8 | sms | yes |
| email | top | `#2A8BD7` | 206.4 | 55.9 | -11.0 | 46.7 | 3.64 | 5.4 | x | yes |
| email | bottom | `#1B81D8` | 207.6 | 52.8 | -11.1 | 52.4 | 4.06 | 5.5 | x | yes |
| email | mac | `#0077D9` | 207.1 | 49.7 | -11.2 | 58.5 | 4.53 | 5.4 | messenger | yes |
| matrix | top | `#5697EF` | 214.5 | 61.9 | -5.0 | 50.8 | 2.97 | 5.7 | whatsapp | yes |
| matrix | bottom | `#4E8DF0` | 216.7 | 58.9 | -5.0 | 56.9 | 3.29 | 5.8 | whatsapp | yes |
| matrix | mac | `#4583F1` | 218.4 | 55.9 | -5.0 | 63.3 | 3.64 | 5.9 | whatsapp | yes |

ALL PASS

**Signal and Slack (2026-11-22): PROVISIONAL, owner to confirm.** With the nine shades above fixed, R15's rules leave free room only in a small slate-to-periwinkle pocket (hue 224–235°, C\* 41–56; a Lab sweep at 1-unit steps found 35 valid bottoms, all at ΔE 5.0–6 from SMS/WhatsApp). The pair that sits closest to Signal's ultramarine and is most distinct from each other (ΔE 7.9) was taken:
- signal `#5F83CD` → `#5879CE`, Mac `#516FCF` (a deeper ultramarine, at the dark edge of the L\* window like Messenger/Discord);
- slack `#8395DF` → `#7D8BE0`, Mac `#7881E1` (a soft periwinkle).

**Instagram and LinkedIn (2026-11-22): PROVISIONAL, owner to confirm.** A search over the same rules (3-unit sRGB grid, each shade checked against all eleven) found room for exactly ONE more network: 18 valid triples, no two of them ΔE ≥ 5 apart. LinkedIn takes the most separated one, `#7982C8` → `#727BC3`, Mac `#6B74C4` (slate periwinkle; nearest Signal/WhatsApp at ΔE 5.2–5.8; far from LinkedIn's own `#0A66C2`). Instagram reuses Messenger's shade (its DMs come through Meta's bridge; no twelfth shade fits). Giving Instagram its own shade needs a palette re-fit (D4, owner's call).

`check-palette.py` passes with all twelve. A brighter Signal blue (≈ `#3A76F0`) or a Slack cyan would need the other networks re-fitted (palette_fit with 11 anchors), which is the owner's call (D4).

`design/refs/palette.png` shows one outgoing bubble per network, with white text, on light and dark backgrounds, plus a Mac swatch. The bubbles there use a per-bubble gradient for illustration only. The app uses a screen-position gradient (spec §2).

The round-0 palette (navy, slate, periwinkle) was superseded by R15. It satisfied the old rules (ΔE ≥ 10, contrast ≥ 3, iMessage exempt) and is kept in git history (461e05b).

## Kit vs screenshot disagreements: screenshot value used; verify on device

| Item | Kit (Messages template) | Screenshots | Used |
|---|---|---|---|
| Outgoing iMessage blue | flat `#0088FF` (light); `#4EBAFF→#0088FF` per bubble (dark) | `#37AAFC→#2AA0FD` screen-position gradient; Mac `#1896FE` | **screenshot value used; verify on device** |
| iOS list row height | 79 pt | 89–90 pt (two guides + one device shot) | **86.67, measured on the real iOS 27 app (Phase B)** |
| Same-sender bubble gap | 8–10 pt (hand-laid `Examples` page) | ≈ 4 pt (newsroom polls, 1.746 px/pt) | **4, screenshot value used; verify on device** |
| Incoming grey | `#E9E9EA` / `#262629` | `#E9E9EB` / `#262628` | screenshot value (within 1 unit) |
