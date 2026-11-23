#if os(macOS)
import AppKit
import CommsCore
import SwiftUI

/// The Mac transcript scroller, productionised from the Phase 0 spike
/// (spikes/TranscriptSpike/Mac/TranscriptTableVC.swift, FINDINGS.md):
///
/// - an unflipped-content `NSTableView` (row 0 = oldest, at the top) of `NSHostingView` cells;
/// - row heights measured up front with an `NSHostingController` at the column width and
///   cached by row id + content (NOT `usesAutomaticRowHeights`: that made 228 pt jumps);
/// - every change is applied as a diff (removals, insertions, in-place reloads) with no
///   animation, then the scroll position is restored: pinned to the bottom when it was at the
///   bottom, else the first visible row that survives keeps its on-screen offset. A prepend of
///   older history is just such a change, so it never moves what is on screen;
/// - a width change (window resize, sidebar or inspector toggling) re-measures and keeps the
///   same anchor; during a live resize only the rows near the viewport are re-measured, the
///   rest when the resize ends;
/// - when the viewport comes within two screens of the top, `onNeedsOlder` asks for the next
///   page (once per change of rows).
///
/// Accessibility: rows are exposed in index order (oldest first, newest last), which is the
/// visual top-to-bottom order.
@MainActor
final class TranscriptTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = TranscriptScrollView()
    let tableView = NSTableView()

    private(set) var rows: [TranscriptRow] = []
    private var contexts: [TranscriptRowContext] = []

    var isGroup = false
    var metrics: BubbleMetrics = .mac
    var mediaLoader: MediaLoader = .none
    var selfSenderIDs: Set<String> = []
    /// Try Again / Delete for undelivered bubbles.
    var sendActions: SendActions = .none
    /// Reply, tapbacks, reaction details.
    var interactions: MessageInteractions = .none
    /// Show the message overlay (right-click / Control-click / Force Touch, double-click, a
    /// click on the badges, VoiceOver "Show Menu"): the view lays it over the transcript.
    var onPresentOverlay: (MessageOverlayContext, MessageOverlayMode) -> Void = { _, _ in }
    /// The overlay is up (the view says so): no second one, and no menu events taken.
    var overlayShown = false
    /// Bubble frames by message id (and whole message views by `rowKey`), in each row's space.
    private(set) var bubbleFrames: [String: CGRect] = [:]
    private var eventMonitor: Any?
    /// A Force Touch already opened the menu for this press (stage 2 fires once per press).
    private var forceTouchFired = false
    var canLoadOlder = false
    var onNeedsOlder: () -> Void = {}
    /// Called with true when the viewport is more than a screen above the bottom.
    var onFarFromBottomChange: (Bool) -> Void = { _ in }
    /// Test hook for the negative control: when false, a change is applied without restoring
    /// the anchor (what the spike's `-nocompensate` did).
    var restoresAnchor = true

    private var heights: [String: (key: Int, width: CGFloat, height: CGFloat)] = [:]
    private lazy var sizer = NSHostingController(rootView: AnyView(EmptyView()))
    private var isApplying = false
    private var olderRequested = false
    private var farFromBottom = false
    /// Column width the cached heights are valid for.
    private var measuredWidth: CGFloat = 0

    /// Number of rows measured with the sizer (tests check the cache works).
    private(set) var measureCount = 0
    /// Above this many rows a width change re-measures only the rows near the viewport at once
    /// and the rest once the width settles (an inspector or sidebar animation changes the
    /// width every frame).
    static let bandOnlyAbove = 80
    /// How long the width must stay put before off-screen rows are re-measured.
    static let settleDelay: TimeInterval = 0.25
    private var pendingRemeasure: DispatchWorkItem?
    /// The store's `olderLoadCount` last seen (see `noteOlderLoads`).
    private var olderLoads = 0

    // MARK: View

    override func loadView() {
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Messages")
        tableView.setAccessibilityIdentifier("transcript")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onEndLiveResize = { [weak self] in self?.widthChanged(final: true) }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if contentWidth != measuredWidth { widthChanged(final: false) }
    }

    // MARK: Geometry

    private var clip: NSClipView { scrollView.contentView }
    var contentWidth: CGFloat { scrollView.contentSize.width }
    private var minOffset: CGFloat { -scrollView.contentInsets.top }
    private var contentHeight: CGFloat { rows.isEmpty ? 0 : tableView.rect(ofRow: rows.count - 1).maxY }
    private var maxOffset: CGFloat { max(minOffset, contentHeight + scrollView.contentInsets.bottom - clip.bounds.height) }
    var distanceFromBottom: CGFloat { maxOffset - clip.bounds.origin.y }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        let old = scrollView.contentInsets
        guard old.top != top || old.bottom != bottom else { return }
        let wasAtBottom = distanceFromBottom <= 2
        let anchors = captureAnchors()
        scrollView.contentInsets = insets
        scrollView.scrollerInsets = insets
        if wasAtBottom { scrollToBottom() } else { restore(anchors) }
    }

    func scroll(toY y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToBottom(animated: Bool = false) {
        tableView.layoutSubtreeIfNeeded()
        guard animated else { return scroll(toY: maxOffset) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: maxOffset))
        } completionHandler: { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.scrollView.reflectScrolledClipView(self.clip) }
        }
    }

    /// The on-screen y (from the top of the clip view) of the row with `id`, if loaded.
    func screenY(ofRowID id: String) -> CGFloat? {
        rows.firstIndex { $0.id == id }.map { tableView.rect(ofRow: $0).minY - clip.bounds.minY }
    }

    /// Ids and screen y of the rows intersecting the viewport.
    func visibleRows() -> [(id: String, y: CGFloat)] {
        let range = tableView.rows(in: clip.bounds)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { i in
            i < rows.count ? (rows[i].id, tableView.rect(ofRow: i).minY - clip.bounds.minY) : nil
        }
    }

    // MARK: Anchors

    struct Anchor { var id: String; var offset: CGFloat }

    /// Every visible row with its offset from the top of the viewport, top first: after a
    /// change the first one that still exists is put back where it was.
    private func captureAnchors() -> [Anchor] {
        let range = tableView.rows(in: clip.bounds)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { i in
            i < rows.count ? Anchor(id: rows[i].diffID, offset: tableView.rect(ofRow: i).minY - clip.bounds.minY) : nil
        }
    }

    private func restore(_ anchors: [Anchor]) {
        guard restoresAnchor, !anchors.isEmpty else { return }
        let index = Dictionary(rows.enumerated().map { ($1.diffID, $0) }, uniquingKeysWith: { a, _ in a })
        for a in anchors {
            if let i = index[a.id] {
                scroll(toY: tableView.rect(ofRow: i).minY - a.offset)
                return
            }
        }
    }

    // MARK: Applying rows

    /// Show `newRows`, keeping the viewport where it was (see the type's notes).
    func apply(_ newRows: [TranscriptRow]) {
        let newContexts = Self.contexts(for: newRows, isGroup: isGroup, metrics: metrics)
        guard newRows != rows || newContexts != contexts else { return }
        // The width may have changed in the same pass (before viewDidLayout saw it): every row
        // measured at the old width is stale, not just the inserted and changed ones.
        let widthMoved = measuredWidth != 0 && contentWidth != measuredWidth
        measuredWidth = contentWidth

        let first = rows.isEmpty
        let wasAtBottom = first || distanceFromBottom <= 2
        let anchors = captureAnchors()
        let oldRows = rows
        let oldContexts = contexts
        isApplying = true
        defer { isApplying = false }

        rows = newRows
        contexts = newContexts
        if first || oldRows.isEmpty {
            tableView.reloadData()
        } else {
            // By `diffID`: a pending bubble and its echo are one row (reloaded in place).
            let diff = newRows.map(\.diffID).difference(from: oldRows.map(\.diffID))
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            // Rows that stay but whose content or spacing changed.
            let oldByID = Dictionary(zip(oldRows, oldContexts).map { ($0.0.diffID, $0) }, uniquingKeysWith: { a, _ in a })
            var changed = IndexSet()
            for (i, row) in newRows.enumerated() where !inserted.contains(i) {
                if let old = oldByID[row.diffID], old.0 != row || old.1 != newContexts[i] { changed.insert(i) }
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                tableView.beginUpdates()
                if !removed.isEmpty { tableView.removeRows(at: removed, withAnimation: []) }
                if !inserted.isEmpty { tableView.insertRows(at: inserted, withAnimation: []) }
                tableView.endUpdates()
                if !changed.isEmpty {
                    tableView.noteHeightOfRows(withIndexesChanged: changed)
                    tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
                }
            }
            if widthMoved { remeasureStaleRows(bandOnly: rows.count > Self.bandOnlyAbove) }
        }
        tableView.layoutSubtreeIfNeeded()
        if wasAtBottom { scrollToBottom() } else { restore(anchors) }
        olderRequested = false
        viewportChanged()
    }

    static func contexts(for rows: [TranscriptRow], isGroup: Bool, metrics: BubbleMetrics) -> [TranscriptRowContext] {
        let receipt = Receipt.forLast(rows, isGroup: isGroup)
        return rows.indices.map { i in
            TranscriptRowContext(
                isGroup: isGroup,
                spacingAbove: TranscriptRowView.spacingAbove(rows[i], after: i > 0 ? rows[i - 1] : nil, metrics: metrics),
                receipt: receipt?.id == rows[i].id ? receipt?.receipt : nil
            )
        }
    }

    /// Re-lay out every row (the group flag, metrics or loader changed).
    func reloadAll() {
        let anchors = captureAnchors()
        let wasAtBottom = distanceFromBottom <= 2
        contexts = Self.contexts(for: rows, isGroup: isGroup, metrics: metrics)
        guard !rows.isEmpty else { return }
        heights.removeAll()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if wasAtBottom { scrollToBottom() } else { restore(anchors) }
    }

    /// Redraw the cells without touching their heights (an accessibility-only input changed).
    func reloadContents() {
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: [0])
    }

    /// Take new layout inputs: what changes heights re-lays out every row, what only changes
    /// what VoiceOver says redraws the cells and keeps the cached heights.
    func configure(isGroup: Bool, metrics: BubbleMetrics, selfSenderIDs: Set<String>) {
        let relayout = isGroup != self.isGroup || metrics != self.metrics
        let redraw = selfSenderIDs != self.selfSenderIDs
        self.isGroup = isGroup
        self.metrics = metrics
        self.selfSenderIDs = selfSenderIDs
        if relayout { reloadAll() } else if redraw { reloadContents() }
    }

    // MARK: Width changes

    /// Re-measure at the new width and keep the anchor. With many rows, or in a live resize,
    /// only the rows within a screen of the viewport are re-measured now; the rest follow when
    /// the width settles (`settleDelay`) or the live resize ends (`final`).
    private func widthChanged(final: Bool) {
        guard !rows.isEmpty, !isApplying else {
            measuredWidth = contentWidth
            return
        }
        let wasAtBottom = distanceFromBottom <= 2
        let anchors = captureAnchors()
        measuredWidth = contentWidth
        let bandOnly = !final && (scrollView.inLiveResize || rows.count > Self.bandOnlyAbove)
        guard remeasureStaleRows(bandOnly: bandOnly) else { return }
        tableView.layoutSubtreeIfNeeded()
        if wasAtBottom { scrollToBottom() } else { restore(anchors) }
        viewportChanged()
    }

    /// Note the heights of rows measured at another width (only those near the viewport when
    /// `bandOnly`, scheduling the rest). Returns whether any row was noted.
    @discardableResult
    private func remeasureStaleRows(bandOnly: Bool) -> Bool {
        var stale = IndexSet(rows.indices.filter { heights[rows[$0].id]?.width != measuredWidth })
        if bandOnly {
            let band = clip.bounds.insetBy(dx: 0, dy: -clip.bounds.height)
            let r = tableView.rows(in: band)
            let near = IndexSet(integersIn: r.location..<(r.location + r.length))
            if stale.subtracting(near).isEmpty == false { scheduleFullRemeasure() }
            stale.formIntersection(near)
        } else {
            pendingRemeasure?.cancel()
            pendingRemeasure = nil
        }
        guard !stale.isEmpty else { return false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            tableView.noteHeightOfRows(withIndexesChanged: stale)
        }
        // Cells on screen were built for the old width (their row view and bubble max width):
        // rebuild them, so bubbles reflow when the inspector or sidebar narrows the column —
        // outgoing keep their trailing margin, incoming their leading one — instead of the
        // old-width row being centred in the narrower cell and clipped at both edges.
        let r = tableView.rows(in: clip.bounds)
        let visible = IndexSet(integersIn: r.location..<(r.location + r.length)).intersection(stale)
        if !visible.isEmpty { tableView.reloadData(forRowIndexes: visible, columnIndexes: [0]) }
        return true
    }

    /// Coalesce: one full re-measure once the width has stayed put for `settleDelay` (a live
    /// resize does it when it ends instead).
    private func scheduleFullRemeasure() {
        pendingRemeasure?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.scrollView.inLiveResize else { return }
                self.pendingRemeasure = nil
                self.widthChanged(final: true)
            }
        }
        pendingRemeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Tests: run the pending settle re-measure now.
    func flushPendingRemeasure() {
        guard let work = pendingRemeasure else { return }
        work.cancel()
        pendingRemeasure = nil
        widthChanged(final: true)
    }

    // MARK: Message overlay (Mac Messages 26)

    /// Right-click, Control-click and Force Touch on a bubble open the message overlay, as Mac
    /// Messages does, instead of a plain context menu. A local event monitor sees them before
    /// the cell's hosting view does; anything not on a bubble passes through untouched.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .pressure]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { self?.consumes(e) ?? false }
            return consumed ? nil : event
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    /// Whether the event opened the overlay (and is swallowed).
    private func consumes(_ event: NSEvent) -> Bool {
        guard event.window === view.window, view.window != nil, !overlayShown else { return false }
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown:
            guard event.modifierFlags.contains(.control) else { return false }
        case .pressure:
            // Force Touch: the deep press (stage 2) opens the menu once per press.
            if event.stage < 2 { forceTouchFired = false; return false }
            guard !forceTouchFired else { return false }
        default:
            return false
        }
        guard let id = messageID(at: event) else { return false }
        if event.type == .pressure {
            forceTouchFired = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        presentOverlay(messageID: id, mode: .menu)
        // A pressure event is not a click: let it through (the press continues).
        return event.type != .pressure
    }

    /// The message whose bubbles are under the event (on the visible table, not under the
    /// header or composer drawn over it).
    private func messageID(at event: NSEvent) -> String? {
        guard let window = view.window, let hit = window.contentView?.hitTest(event.locationInWindow),
              hit.isDescendant(of: tableView) else { return nil }
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard row >= 0, row < rows.count, case .message(let m, _, _, _) = rows[row], !m.redacted, m.system == nil,
              let f = bubbleFrames[m.id] else { return nil }
        let cell = tableView.rect(ofRow: row)
        let bubble = CGRect(x: cell.minX + f.minX, y: cell.minY + f.minY, width: f.width, height: f.height)
        return bubble.insetBy(dx: -3, dy: -3).contains(point) ? m.id : nil
    }

    /// A view's frame in its window's content coordinates with a top-left origin (SwiftUI's
    /// `.global` on the Mac). Nil outside a window. Pure geometry, unit-tested.
    static func windowFrame(of view: NSView) -> CGRect? {
        guard let window = view.window, let content = window.contentView else { return nil }
        let r = content.convert(view.convert(view.bounds, to: nil), from: nil)
        let top = content.isFlipped ? r.minY : content.bounds.height - r.maxY
        return CGRect(x: r.minX, y: top, width: r.width, height: r.height)
    }

    /// A message's frame (bubbles, or with `rowKey` the whole view) in the scroll view's
    /// top-left coordinates (the overlay's).
    func overlayFrame(of key: String, row: Int) -> CGRect? {
        guard let f = bubbleFrames[key] else { return nil }
        let cell = tableView.convert(tableView.rect(ofRow: row), to: scrollView)
        let top = scrollView.isFlipped ? cell.minY : scrollView.bounds.height - cell.maxY
        return CGRect(x: cell.minX + f.minX, y: top + f.minY, width: f.width, height: f.height)
    }

    func presentOverlay(messageID: String, mode: MessageOverlayMode) {
        guard !overlayShown, let i = rows.firstIndex(where: { $0.id == messageID }),
              case .message(let m, let position, _, _) = rows[i] else { return }
        switch mode {
        case .menu:
            guard interactions.canReact(m) || !MessageMenuItem.groups(for: m, interactions: interactions, platformSelect: false,
                                                                    showReactions: !m.reactions.isEmpty).isEmpty else { return }
        case .tapbacks:
            guard interactions.canReact(m) else { return }
        case .details:
            guard !m.reactions.isEmpty else { return }
        }
        // Bring the bubble fully into view first (VoiceOver / ⌘T can name an off-screen one).
        if let content = overlayFrame(of: messageID, row: i),
           !CGRect(x: 0, y: scrollView.contentInsets.top, width: scrollView.bounds.width,
                   height: scrollView.bounds.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom).contains(content) {
            tableView.scrollRowToVisible(i)
            tableView.layoutSubtreeIfNeeded()
        }
        guard let content = overlayFrame(of: messageID, row: i),
              let row = overlayFrame(of: MessageInteractionModifier.rowKey(messageID), row: i) else { return }
        let width = measuredWidth > 0 ? measuredWidth : contentWidth
        let ctx = MessageOverlayContext(
            message: m, position: position, isGroup: isGroup, rowFrame: row, contentFrame: content,
            // The composer floats over the bottom inset: the menu stays above it.
            screen: scrollView.bounds.size, safeTop: scrollView.contentInsets.top, safeBottom: max(8, scrollView.contentInsets.bottom),
            metrics: metrics, maxWidth: max(0, (width - 2 * TranscriptRowView.sideMargin) * metrics.maxWidthRatio),
            mediaLoader: mediaLoader, avatarLoader: nil, selfSenderIDs: selfSenderIDs,
            gradientHeight: view.window?.screen?.frame.height ?? 900,
            // Hosted in the scroll view itself (`showOverlay`): its space IS the pane.
            paneInWindow: nil)
        overlayShown = true
        onPresentOverlay(ctx, mode)
    }

    // MARK: Overlay host (round 3)

    /// The message overlay's own AppKit host, laid exactly over the scroll view. Round 3 (owner,
    /// 0.3.3 still broken): hosted as a SwiftUI `.overlay` of the transcript, the overlay's
    /// children were laid out from the detail column's origin under the sidebar (the column runs
    /// under the floating sidebar and `.ignoresSafeArea()` extended the region by its 144 pt safe
    /// area) while the frames are the scroll view's — the dim slab over the left of the pane,
    /// the bubble clipped, the tapback bar off-pane. Here (0, 0) is the pane's top-left by
    /// construction: no safe areas, no coordinate conversion. Verified in a real window
    /// (`MacOverlayRealWindowTests`).
    private(set) var overlayHost: NSHostingView<AnyView>?

    func showOverlay(_ root: AnyView) {
        if let host = overlayHost {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.clipsToBounds = true
            host.autoresizingMask = [.width, .height]
            scrollView.addSubview(host, positioned: .above, relativeTo: nil)
            overlayHost = host
        }
        overlayHost?.frame = scrollView.bounds
        view.window?.makeFirstResponder(overlayHost)
    }

    func hideOverlay() {
        overlayHost?.removeFromSuperview()
        overlayHost = nil
    }

    /// The newest message from someone else that takes a tapback (⌘T, as in Mac Messages).
    var newestReactableID: String? {
        rows.reversed().lazy.compactMap { r -> String? in
            if case .message(let m, _, _, _) = r, !m.sender.isSelf, self.interactions.canReact(m) { return m.id }
            return nil
        }.first
    }

    // MARK: Scrolling

    @objc private func boundsChanged() {
        guard !isApplying else { return }
        viewportChanged()
    }

    private func viewportChanged() {
        let far = distanceFromBottom > clip.bounds.height
        if far != farFromBottom {
            farFromBottom = far
            onFarFromBottomChange(far)
        }
        // Prefetch about two screens before the top.
        if canLoadOlder, !olderRequested, !rows.isEmpty, clip.bounds.minY - minOffset < 2 * clip.bounds.height {
            olderRequested = true
            onNeedsOlder()
        }
    }

    /// The store finished `count` older loads so far. When one finished since the last call the
    /// prefetch is re-armed, even if it added no rows (errors, nothing new): the next scroll may
    /// ask again. It does not ask right away, so a load that keeps finding nothing never loops.
    func noteOlderLoads(_ count: Int) {
        guard count != olderLoads else { return }
        olderLoads = count
        olderRequested = false
    }

    /// Paging is possible (`hasMore` and not stalled): allow a new request.
    func setCanLoadOlder(_ value: Bool) {
        guard value != canLoadOlder else { return }
        canLoadOlder = value
        olderRequested = false
        if value { viewportChanged() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TranscriptCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HostingCell) ?? {
            let c = HostingCell()
            c.identifier = id
            return c
        }()
        cell.show(content(for: row))
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let width = measuredWidth > 0 ? measuredWidth : contentWidth
        let r = rows[row]
        let key = Self.key(r, contexts[row])
        if let hit = heights[r.id], hit.key == key, hit.width == width { return hit.height }
        sizer.rootView = content(for: row)
        let h = max(1, ceil(sizer.sizeThatFits(in: CGSize(width: width, height: .infinity)).height))
        measureCount += 1
        heights[r.id] = (key, width, h)
        return h
    }

    /// Tests: `row` measured now at the current width, bypassing the cache.
    func freshHeight(ofRow row: Int) -> CGFloat {
        sizer.rootView = content(for: row)
        return max(1, ceil(sizer.sizeThatFits(in: CGSize(width: measuredWidth, height: .infinity)).height))
    }

    private static func key(_ row: TranscriptRow, _ context: TranscriptRowContext) -> Int {
        var h = Hasher()
        h.combine(row)
        h.combine(context)
        return h.finalize()
    }

    private func content(for row: Int) -> AnyView {
        let r = rows[row]
        let width = measuredWidth > 0 ? measuredWidth : contentWidth
        let maxWidth = max(0, (width - 2 * TranscriptRowView.sideMargin) * metrics.maxWidthRatio)
        return AnyView(
            TranscriptRowView(row: r, context: contexts[row])
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.bubbleMetrics, metrics)
                .environment(\.bubbleMaxWidth, maxWidth)
                .environment(\.mediaLoader, mediaLoader)
                .environment(\.selfSenderIDs, selfSenderIDs)
                .environment(\.sendActions, sendActions)
                .environment(\.messageInteractions, interactions)
                .environment(\.bubbleContentReporter, { [weak self] id, frame in self?.bubbleFrames[id] = frame })
                .environment(\.messageOverlayPresenter, { [weak self] id, mode in self?.presentOverlay(messageID: id, mode: mode) })
        )
    }
}

/// A table cell holding one SwiftUI row.
final class HostingCell: NSTableCellView {
    private var host: NSHostingView<AnyView>?

    func show(_ view: AnyView) {
        if let host {
            host.rootView = view
            return
        }
        let h = NSHostingView(rootView: view)
        h.sizingOptions = []
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        host = h
    }
}

/// Reports the end of a live resize (the controller then re-measures every row).
final class TranscriptScrollView: NSScrollView {
    var onEndLiveResize: () -> Void = {}
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize()
    }
}
#endif
