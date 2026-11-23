# CommsUI snapshot references

PNG references for `BubbleSnapshotTests` (and `List/` for the list views), named
`<test>-light.png` / `<test>-dark.png`.

- Rendered with SwiftUI `ImageRenderer` on **macOS at scale 2**, at Mac bubble sizes
  (`BubbleMetrics.mac`, body 13 pt), on a 420 pt transcript column.
- A test passes when at most **1 %** of pixels differ (a pixel differs when any channel
  differs by more than 8/255, so anti-aliasing noise is ignored).
- Text uses the **system font (SF)** and Apple Color Emoji, so references are
  **machine-specific**: a different macOS / Xcode / font version can shift glyphs. If every
  snapshot fails at once after an OS update, inspect the diffs (written to
  `$TMPDIR/CommsUISnapshotFailures/`) and re-record.
- Re-record: `RECORD_SNAPSHOTS=1 swift test --package-path CommsKit --filter BubbleSnapshotTests`
  (recorded on macOS 27.2, Xcode 27.2).
- Media in snapshots comes from `MediaLoader.placeholder` (synthetic art; no network).
- **macOS only.** On other platforms (the iOS Simulator run of `CommsKit-Package`) every
  snapshot test still renders its views (light and dark) and fails on an empty render, but
  the reference comparison is skipped and `RECORD_SNAPSHOTS` is ignored: iOS renders differ
  in fonts and metrics, and the bubbles are calibrated against the Mac. Per-platform iOS
  references come with the Phase 2 iOS transcript.
