#if os(iOS)
import CommsClient
import CommsCore
import SwiftUI
import UIKit

/// The iOS transcript scroller, productionised from the Phase 0 spike
/// (spikes/TranscriptSpike/iOS/FlippedTranscriptVC.swift, FINDINGS.md):
///
/// - a vertically flipped `UICollectionView` (item 0 = the newest row, at the visual bottom),
///   each cell's content flipped back upright; each cell hosts the shared `TranscriptRowView`
///   (the same `MessageBubble`s as the Mac) in a `UIHostingController` with no safe-area
///   regions (a `UIHostingConfiguration` inset rows under the header and composer by the
///   window's safe area, drawing them up to 90 pt away from their cells);
/// - older history is APPENDED to the items, i.e. below the existing content in flipped
///   content coordinates, so a prepend never moves what is on screen;
/// - row heights are measured up front with a sizing `UIHostingController` at the column
///   width and cached by row id + content (as the Mac table does), and laid out by
///   `TranscriptStackLayout` — no estimated heights, so nothing re-flows while scrolling;
/// - every change is applied as a diff without animation, then the viewport is restored: kept
///   at the newest row when it was there, otherwise the first visible row that survives keeps
///   its on-screen offset (a live message arriving while reading history does not move it);
/// - changes arriving while the finger is down are held until the drag ends; an
///   `isInserting` guard stops `scrollViewDidScroll` re-entering an update;
/// - when the viewport comes within two screens of the oldest row, `onNeedsOlder` asks for
///   the next page (re-armed by `noteOlderLoads`, as on the Mac).
///
/// Insets are visual: `top` is the header's band, `bottom` the composer plus the keyboard.
/// Changing the bottom inset (the keyboard) keeps the bottom row where it was relative to the
/// composer, so the transcript rides up with the keyboard as in Messages.
@MainActor
final class PhoneTranscriptController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    static let flip = CGAffineTransform(scaleX: 1, y: -1)

    let layout = TranscriptStackLayout()
    private(set) var collectionView: UICollectionView!

    /// Displayed items, newest first (item 0 at the visual bottom).
    private(set) var items: [TranscriptItem] = []

    var isGroup = false
    var metrics: BubbleMetrics = .current
    var mediaLoader: MediaLoader = .none
    /// Try Again / Delete for undelivered bubbles.
    var sendActions: SendActions = .none
    /// Reply, tapbacks, reaction details (the long-press / double-tap overlay).
    var interactions: MessageInteractions = .none
    /// Bubble frames by message id (and whole message views by `rowKey`), in each row's space.
    private(set) var bubbleFrames: [String: CGRect] = [:]
    /// The overlay on screen, if any (tests).
    private(set) weak var overlay: MessageOverlayController?
    var avatarLoader: AvatarLoader?
    var selfSenderIDs: Set<String> = []
    var canLoadOlder = false
    var onNeedsOlder: () -> Void = {}
    /// Test hook for the negative control: when false, a change is applied without restoring
    /// the anchor.
    var restoresAnchor = true
    /// Test hook for the iOS negative control: after an older page lands, push the content
    /// down by the inserted height (what an unflipped list without compensation does).
    var displacesOnInsertForTesting = false

    private var rows: [TranscriptRow] = []
    private var caption: String?
    private var heights: [String: (key: Int, width: CGFloat, height: CGFloat)] = [:]
    private lazy var sizer: UIHostingController<AnyView> = {
        let c = UIHostingController(rootView: AnyView(EmptyView()))
        c.sizingOptions = []
        return c
    }()
    private var measuredWidth: CGFloat = 0
    private var olderRequested = false
    private var olderLoads = 0
    private var isInserting = false
    /// Rows that arrived while the finger was down (applied when the drag ends).
    private var pending: (rows: [TranscriptRow], caption: String?)?
    private var visualInsets = UIEdgeInsets.zero

    /// Number of rows measured (tests check the cache works).
    private(set) var measureCount = 0
    /// Changes held because the finger was down / later applied (tests, diagnostics).
    private(set) var deferredSet = 0
    private(set) var deferredExecuted = 0
    private(set) var reentrantBlocked = 0

    private let registration = UICollectionView.CellRegistration<TranscriptCell, Int> { _, _, _ in }

    // MARK: View

    override func loadView() {
        layout.controller = self
        let cv = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.transform = Self.flip
        cv.backgroundColor = .clear
        cv.dataSource = self
        cv.delegate = self
        cv.contentInsetAdjustmentBehavior = .never
        cv.automaticallyAdjustsScrollIndicatorInsets = false
        cv.alwaysBounceVertical = true
        cv.keyboardDismissMode = .interactive
        // The status-bar tap would go to the flipped top, the newest row: Messages scrolls to
        // the oldest loaded row instead. Off rather than surprising.
        cv.scrollsToTop = false
        cv.allowsSelection = false
        // The system's scroll-edge blur assumes an unflipped scroll view (it blurred the whole
        // transcript); the header draws Messages' soft edge itself (`HeaderScrollEdge`).
        cv.topEdgeEffect.isHidden = true
        cv.bottomEdgeEffect.isHidden = true
        cv.accessibilityIdentifier = "transcript"
        cv.accessibilityLabel = "Messages"
        collectionView = cv
        // Messages: long press = the menu (tapbacks + actions); double tap = the tapbacks.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.4
        cv.addGestureRecognizer(press)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        double.delaysTouchesEnded = false
        cv.addGestureRecognizer(double)
        // The overlay is laid out with the keyboard down (review I3): track it.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        // A plain container as the root: SwiftUI owns the hosted root view's geometry (it
        // reset the flip when the collection view itself was the root).
        let root = UIView()
        root.backgroundColor = .clear
        cv.frame = root.bounds
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(cv)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard contentWidth > 0 else { return }
        if items.isEmpty, let p = pending {
            measuredWidth = contentWidth
            apply(p.rows, caption: p.caption)
        } else if contentWidth != measuredWidth {
            widthChanged(final: false)
        }
    }

    // MARK: Geometry (flipped content coordinates unless "visual")

    var contentWidth: CGFloat { collectionView.bounds.width }
    /// The offset at which the newest row sits just above the composer.
    private var newestOffset: CGFloat { -collectionView.contentInset.top }
    var distanceFromNewest: CGFloat { collectionView.contentOffset.y - newestOffset }
    var isAtNewest: Bool { distanceFromNewest <= 2 }

    /// Space between the newest row and the composer's top edge (Messages: "Delivered" ends
    /// 25.4 pt above the entry field, design/fidelity/apple-ios/composer-text-light.ax.txt).
    static let composerGap = Tokens.transcript.composerGap

    /// Visual insets: `top` = header band, `bottom` = the composer's top edge (+ keyboard).
    /// The transcript keeps `composerGap` above the composer; the composer does not move.
    func setInsets(top: CGFloat, bottom: CGFloat) {
        let new = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard new != visualInsets else { return }
        let old = visualInsets
        visualInsets = new
        let cv = collectionView!
        let deltaBottom = bottom - old.bottom
        // Read before the inset changes: UIScrollView clamps the offset to the new inset.
        let oldOffset = cv.contentOffset.y
        // Flipped: the visual bottom is the content's top.
        cv.contentInset = UIEdgeInsets(top: bottom + Self.composerGap, left: 0, bottom: top, right: 0)
        cv.verticalScrollIndicatorInsets = UIEdgeInsets(top: bottom, left: 0, bottom: top, right: 0)
        layout.invalidateLayout()
        cv.layoutIfNeeded()
        // The composer moved by deltaBottom: move the content with it (what sat just above
        // the composer still does, as in Messages when the keyboard comes up).
        cv.contentOffset.y = max(newestOffset, oldOffset - deltaBottom)
        if cv.contentOffset.y < newestOffset + 2 { cv.contentOffset.y = newestOffset }
    }

    func scrollToNewest(animated: Bool = false) {
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(CGPoint(x: 0, y: newestOffset), animated: animated)
    }

    func scroll(toY y: CGFloat) {
        collectionView.contentOffset = CGPoint(x: 0, y: y)
    }

    /// Visual y (from the top of the view) of the item's top edge.
    private func visualY(_ frame: CGRect) -> CGFloat {
        collectionView.bounds.height - (frame.maxY - collectionView.contentOffset.y)
    }

    /// Visual y of the row with `id`, if loaded (tests).
    func screenY(ofRowID id: String) -> CGFloat? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return visualY(layout.frame(at: i))
    }

    /// Ids and visual y of the items intersecting the viewport.
    func visibleRows() -> [(id: String, y: CGFloat)] {
        layout.indexes(in: collectionView.bounds).map { (items[$0].id, visualY(layout.frame(at: $0))) }
    }

    // MARK: Anchors

    private struct Anchor { var id: String; var offset: CGFloat }

    /// Visible items with their content offset from the viewport origin, nearest the bottom
    /// (newest) first: after a change the first one that still exists is put back.
    private func captureAnchors() -> [Anchor] {
        layout.indexes(in: collectionView.bounds).map { Anchor(id: items[$0].diffID, offset: layout.frame(at: $0).minY - collectionView.contentOffset.y) }
    }

    private func restore(_ anchors: [Anchor]) {
        guard restoresAnchor, !anchors.isEmpty else { return }
        let index = Dictionary(items.enumerated().map { ($1.diffID, $0) }, uniquingKeysWith: { a, _ in a })
        for a in anchors {
            if let i = index[a.id] {
                collectionView.contentOffset.y = layout.frame(at: i).minY - a.offset
                return
            }
        }
    }

    // MARK: Applying rows

    /// Show `newRows` (oldest first, the store's order) under an optional history caption
    /// ("WhatsApp" at the start of the conversation), keeping the viewport (see the type).
    func apply(_ newRows: [TranscriptRow], caption newCaption: String?) {
        guard contentWidth > 0 else {
            // Not laid out yet: measure once the width is known (viewDidLayoutSubviews).
            pending = (newRows, newCaption)
            return
        }
        if collectionView.isDragging, !items.isEmpty {
            if pending == nil { deferredSet += 1 }
            pending = (newRows, newCaption)
            return
        }
        pending = nil
        let newItems = Self.items(rows: newRows, caption: newCaption, isGroup: isGroup, metrics: metrics)
        guard newItems != items else {
            rows = newRows
            caption = newCaption
            return
        }
        let first = items.isEmpty
        let wasAtNewest = first || isAtNewest
        let anchors = captureAnchors()
        let old = items
        rows = newRows
        caption = newCaption
        isInserting = true
        defer { isInserting = false }

        if measuredWidth != contentWidth { measuredWidth = contentWidth }
        let oldTotal = layout.collectionViewContentSize.height
        items = newItems
        layout.heights = items.indices.map(height(at:))
        if first || old.isEmpty {
            collectionView.reloadData()
        } else {
            // By `diffID`: a pending bubble and its echo are one row (updated in place).
            let diff = newItems.map(\.diffID).difference(from: old.map(\.diffID))
            var removed: [IndexPath] = []
            var inserted: [IndexPath] = []
            var insertedSet = IndexSet()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removed.append(IndexPath(item: offset, section: 0))
                case .insert(let offset, _, _):
                    inserted.append(IndexPath(item: offset, section: 0))
                    insertedSet.insert(offset)
                }
            }
            let oldByID = Dictionary(old.map { ($0.diffID, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [IndexPath] = []
            for (i, item) in newItems.enumerated() where !insertedSet.contains(i) {
                if let o = oldByID[item.diffID], o != item { changed.append(IndexPath(item: i, section: 0)) }
            }
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates {
                    if !removed.isEmpty { collectionView.deleteItems(at: removed) }
                    if !inserted.isEmpty { collectionView.insertItems(at: inserted) }
                }
                if !changed.isEmpty { collectionView.reconfigureItems(at: changed) }
            }
        }
        collectionView.layoutIfNeeded()
        if wasAtNewest { collectionView.contentOffset.y = newestOffset } else { restore(anchors) }
        if displacesOnInsertForTesting, !first {
            collectionView.contentOffset.y += layout.collectionViewContentSize.height - oldTotal
        }
        olderRequested = false
        isInserting = false
        viewportChanged()
    }

    /// Items newest first: the rows reversed, then the caption (the oldest, top-most item).
    static func items(rows: [TranscriptRow], caption: String?, isGroup: Bool, metrics: BubbleMetrics) -> [TranscriptItem] {
        let receipt = Receipt.forLast(rows, isGroup: isGroup)
        var out: [TranscriptItem] = []
        out.reserveCapacity(rows.count + 1)
        for i in rows.indices.reversed() {
            let context = TranscriptRowContext(
                isGroup: isGroup,
                spacingAbove: TranscriptRowView.spacingAbove(rows[i], after: i > 0 ? rows[i - 1] : nil, metrics: metrics),
                receipt: receipt?.id == rows[i].id ? receipt?.receipt : nil)
            out.append(.row(rows[i], context))
        }
        if let caption, !rows.isEmpty { out.append(.caption(caption)) }
        return out
    }

    /// Take new layout inputs; what changes heights re-measures every row.
    func configure(isGroup: Bool, metrics: BubbleMetrics, selfSenderIDs: Set<String>, mediaLoader: MediaLoader, avatarLoader: AvatarLoader?) {
        let relayout = isGroup != self.isGroup || metrics != self.metrics
        let redraw = selfSenderIDs != self.selfSenderIDs
        self.isGroup = isGroup
        self.metrics = metrics
        self.selfSenderIDs = selfSenderIDs
        self.mediaLoader = mediaLoader
        self.avatarLoader = avatarLoader
        if relayout {
            relayoutAll()
        } else if redraw, !items.isEmpty {
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
        }
    }

    /// Above this many items a width change re-measures only the rows near the viewport at
    /// once, the rest once the width has settled (an inspector, rotation or Stage Manager
    /// resize changes the width every animation frame).
    static let bandOnlyAbove = 60
    /// How long the width must stay put before the off-screen rows are re-measured.
    static let settleDelay: TimeInterval = 0.25
    private var pendingRemeasure: DispatchWorkItem?

    /// Re-measure at the new width keeping the anchor: the rows within a screen of the
    /// viewport now, the others (still at their old-width heights) after `settleDelay`.
    private func widthChanged(final: Bool) {
        let wasAtNewest = items.isEmpty || isAtNewest
        let anchors = captureAnchors()
        measuredWidth = contentWidth
        guard !items.isEmpty else { return }
        isInserting = true
        defer { isInserting = false }
        let bandOnly = !final && items.count > Self.bandOnlyAbove
        var heightsNow = layout.heights
        if heightsNow.count != items.count { heightsNow = items.indices.map(height(at:)) }
        let cv = collectionView!
        let band = layout.indexes(in: cv.bounds.insetBy(dx: 0, dy: -cv.bounds.height))
        let measure: [Int] = bandOnly ? band : Array(items.indices)
        for i in measure { heightsNow[i] = height(at: i) }
        layout.heights = heightsNow
        layout.invalidateLayout()
        UIView.performWithoutAnimation { cv.reloadData() }
        cv.layoutIfNeeded()
        if wasAtNewest { cv.contentOffset.y = newestOffset } else { restore(anchors) }
        if bandOnly {
            scheduleFullRemeasure()
        } else {
            pendingRemeasure?.cancel()
            pendingRemeasure = nil
        }
    }

    private func scheduleFullRemeasure() {
        pendingRemeasure?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRemeasure = nil
                self.widthChanged(final: true)
            }
        }
        pendingRemeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Tests: run the pending settled re-measure now.
    func flushPendingRemeasure() {
        guard let work = pendingRemeasure else { return }
        work.cancel()
        pendingRemeasure = nil
        widthChanged(final: true)
    }

    /// Re-lay out every row keeping the viewport (the group flag or metrics changed).
    private func relayoutAll() {
        guard !items.isEmpty else { return }
        let wasAtNewest = isAtNewest
        let anchors = captureAnchors()
        isInserting = true
        defer { isInserting = false }
        heights.removeAll()
        items = Self.items(rows: rows, caption: caption, isGroup: isGroup, metrics: metrics)
        layout.heights = items.indices.map(height(at:))
        layout.invalidateLayout()
        UIView.performWithoutAnimation { collectionView.reloadData() }
        collectionView.layoutIfNeeded()
        if wasAtNewest { collectionView.contentOffset.y = newestOffset } else { restore(anchors) }
    }

    // MARK: Measuring

    private func height(at i: Int) -> CGFloat {
        let item = items[i]
        let width = measuredWidth > 0 ? measuredWidth : contentWidth
        let key = item.hashValue
        if let hit = heights[item.id], hit.key == key, hit.width == width { return hit.height }
        sizer.rootView = content(for: item, width: width)
        let h = max(1, ceil(sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        measureCount += 1
        heights[item.id] = (key, width, h)
        return h
    }

    /// Tests: the item measured now, bypassing the cache.
    func freshHeight(ofItem i: Int) -> CGFloat {
        sizer.rootView = content(for: items[i], width: measuredWidth)
        return max(1, ceil(sizer.sizeThatFits(in: CGSize(width: measuredWidth, height: .greatestFiniteMagnitude)).height))
    }

    private func content(for item: TranscriptItem, width: CGFloat) -> AnyView {
        // Messages: bubbles reach a share of the whole column width (0.71 × 402 ≈ 285 pt).
        let maxWidth = max(0, width * metrics.maxWidthRatio)
        let screenHeight = view.window?.windowScene?.screen.bounds.height ?? 874
        let body: AnyView
        switch item {
        case .row(let row, let context):
            body = AnyView(TranscriptRowView(row: row, context: context))
        case .caption(let text):
            body = AnyView(TranscriptHistoryCaption(text: text))
        }
        return AnyView(
            body
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.bubbleMetrics, metrics)
                .environment(\.bubbleMaxWidth, maxWidth)
                .environment(\.mediaLoader, mediaLoader)
                .environment(\.avatarLoader, avatarLoader)
                .environment(\.selfSenderIDs, selfSenderIDs)
                .environment(\.outgoingGradientHeight, screenHeight)
                .environment(\.sendActions, sendActions)
                .environment(\.messageInteractions, interactions)
                .environment(\.bubbleContentReporter, { [weak self] id, frame in self?.bubbleFrames[id] = frame })
                .environment(\.messageOverlayPresenter, { [weak self] id, mode in self?.presentOverlay(messageID: id, mode: mode) })
        )
    }

    // MARK: Message overlay

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let hit = message(at: g) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        presentOverlay(messageID: hit.id, mode: .menu)
    }

    private var keyboardVisible = false
    @objc private func keyboardWillShow() { keyboardVisible = true }
    @objc private func keyboardWillHide() { keyboardVisible = false }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        // Photos, videos and link cards open on a tap of their own: a double tap there would
        // open them AND the bar (review M7), so only text bubbles take it.
        guard let hit = message(at: g), interactions.canReact(hit), hit.attachments.isEmpty, hit.linkPreviews.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        presentOverlay(messageID: hit.id, mode: .tapbacks)
    }

    /// The message whose bubbles are under the gesture (not its blank margin).
    private func message(at g: UIGestureRecognizer) -> CommsMessage? {
        let point = g.location(in: collectionView)
        guard let path = collectionView.indexPathForItem(at: point), case .row(.message(let m, _, _, _), _) = items[path.item],
              !m.redacted, m.system == nil, let frame = windowFrame(of: m.id) else { return nil }
        return frame.insetBy(dx: -4, dy: -4).contains(g.location(in: nil)) ? m : nil
    }

    /// A message's bubbles (or with `rowKey`, its whole view) in window coordinates.
    func windowFrame(of key: String, messageID: String? = nil) -> CGRect? {
        let id = messageID ?? key
        guard let i = items.firstIndex(where: { $0.id == id }),
              let cell = collectionView.cellForItem(at: IndexPath(item: i, section: 0)),
              let f = bubbleFrames[key] else { return nil }
        let c = cell.convert(cell.bounds, to: nil)
        return CGRect(x: c.minX + f.minX, y: c.minY + f.minY, width: f.width, height: f.height)
    }

    /// Show the overlay for `messageID` (long press, double tap, a tap on its badges, or VoiceOver).
    func presentOverlay(messageID: String, mode: MessageOverlayMode) {
        guard overlay == nil, presentedViewController == nil,
              let i = items.firstIndex(where: { $0.id == messageID }),
              case .row(.message(let m, let position, _, _), let context) = items[i] else { return }
        // Nothing to offer (no tapbacks here, nothing to copy, no reply): no overlay (review M6).
        switch mode {
        case .menu:
            guard interactions.canReact(m) || !MessageMenuItem.groups(for: m, interactions: interactions, platformSelect: true).isEmpty else { return }
        case .tapbacks:
            guard interactions.canReact(m) else { return }
        case .details:
            guard !m.reactions.isEmpty else { return }
        }
        // Messages puts the keyboard away first; the overlay is measured once it is down (the
        // transcript moves with it), so nothing ends up behind the keyboard (review I3).
        if keyboardVisible {
            view.window?.endEditing(true)
            keyboardVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.presentOverlay(messageID: messageID, mode: mode)
            }
            return
        }
        let path = IndexPath(item: i, section: 0)
        // Only scroll when the bubble is not fully on screen (review M8: no viewport shift).
        let onScreen = windowFrame(of: messageID).map { f in view.window.map { $0.bounds.inset(by: $0.safeAreaInsets).contains(f) } ?? false } ?? false
        if !onScreen {
            collectionView.scrollToItem(at: path, at: [], animated: false)
            collectionView.layoutIfNeeded()
        }
        guard let window = view.window,
              let content = windowFrame(of: messageID),
              let row = windowFrame(of: MessageInteractionModifier.rowKey(messageID), messageID: messageID) else { return }
        let width = measuredWidth > 0 ? measuredWidth : contentWidth
        let ctx = MessageOverlayContext(
            message: m, position: position, isGroup: context.isGroup, rowFrame: row, contentFrame: content,
            screen: window.bounds.size, safeTop: window.safeAreaInsets.top, safeBottom: window.safeAreaInsets.bottom,
            metrics: metrics, maxWidth: max(0, width * metrics.maxWidthRatio), mediaLoader: mediaLoader,
            avatarLoader: avatarLoader, selfSenderIDs: selfSenderIDs,
            gradientHeight: window.windowScene?.screen.bounds.height ?? 874)
        // Weak: the overlay's root holds this closure, and the controller holds the root.
        weak var controller: MessageOverlayController?
        let root = MessageInteractionOverlay(context: ctx, mode: mode, interactions: interactions) {
            controller?.close()
        }
        let c = MessageOverlayController(root: AnyView(root))
        controller = c
        overlay = c
        present(c, animated: false)
    }


    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isInserting { reentrantBlocked += 1; return }
        viewportChanged()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let p = pending, !isInserting else { return }
        deferredExecuted += 1
        apply(p.rows, caption: p.caption)
    }

    private func viewportChanged() {
        guard canLoadOlder, !olderRequested, !items.isEmpty else { return }
        let cv = collectionView!
        // The older edge is the content's bottom in flipped coordinates.
        let visibleEnd = cv.contentOffset.y + cv.bounds.height
        if visibleEnd > layout.collectionViewContentSize.height + cv.contentInset.bottom - 2 * cv.bounds.height {
            olderRequested = true
            onNeedsOlder()
        }
    }

    /// See `TranscriptTableController.noteOlderLoads` (Mac).
    func noteOlderLoads(_ count: Int) {
        guard count != olderLoads else { return }
        olderLoads = count
        olderRequested = false
    }

    func setCanLoadOlder(_ value: Bool) {
        guard value != canLoadOlder else { return }
        canLoadOlder = value
        olderRequested = false
        if value { viewportChanged() }
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: indexPath.item)
        let item = items[indexPath.item]
        let width = measuredWidth > 0 ? measuredWidth : contentWidth
        let content = content(for: item, width: width)
        // Flipped back upright inside SwiftUI (a transform on the cell's content view did
        // not survive reuse).
        cell.show(AnyView(content
            // A fresh identity per row: a reused cell never shows the previous row's state.
            .id(item.diffID)
            .scaleEffect(x: 1, y: -1, anchor: .center)
            // A reused cell shows its new row at once (no implicit SwiftUI transition from
            // the previous row's layout).
            .transaction { $0.disablesAnimations = true }), parent: self)
        cell.accessibilityIdentifier = item.id
        return cell
    }
}

/// The flipped collection view with VoiceOver order made visual: the realised cells are
/// exposed top to bottom on screen (oldest → newest), not in index order (newest first).
/// Three-finger scrolls move by a page in the visual direction (up = older history).
final class TranscriptCollectionView: UICollectionView {
    override var accessibilityElements: [Any]? {
        get {
            visibleCells
                .filter { !$0.isHidden && $0.bounds.height > 0 }
                // Flipped: a larger content y is higher on screen.
                .sorted { $0.frame.minY > $1.frame.minY }
        }
        set {}
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let page = bounds.height - contentInset.top - contentInset.bottom
        var y = contentOffset.y
        switch direction {
        case .up: y += page // toward older history (visually up)
        case .down: y -= page
        default: return false
        }
        let maxY = max(-contentInset.top, contentSize.height + contentInset.bottom - bounds.height)
        y = min(max(y, -contentInset.top), maxY)
        guard y != contentOffset.y else { return false }
        setContentOffset(CGPoint(x: 0, y: y), animated: false)
        layoutIfNeeded()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }
}

/// One displayed item of the iOS transcript.
enum TranscriptItem: Hashable {
    case row(TranscriptRow, TranscriptRowContext)
    /// The network caption at the very start of the history ("WhatsApp").
    case caption(String)

    var id: String {
        switch self {
        case .row(let r, _): r.id
        case .caption: "history-caption"
        }
    }

    /// Identity on screen (`TranscriptRow.diffID`: a pending bubble and its echo are one row).
    var diffID: String {
        switch self {
        case .row(let r, _): r.diffID
        case .caption: "history-caption"
        }
    }
}

/// Messages opens a conversation's history with the service ("iMessage · Encrypted"); Comms
/// names the network (no encryption claim: bridged messages are not end-to-end to Comms).
struct TranscriptHistoryCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Tokens.color.secondaryLabel.color)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            // The real app: the time header 41 pt below the caption's top.
            .padding(.bottom, 15.4)
            .accessibilityIdentifier("transcript-network")
    }
}

/// A transcript cell hosting one SwiftUI row; its size is the layout's (never self-sized).
final class TranscriptCell: UICollectionViewCell {
    private var host: UIHostingController<AnyView>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
    }

    func show(_ view: AnyView, parent: UIViewController) {
        if let host {
            host.rootView = view
            return
        }
        let h = UIHostingController(rootView: view)
        h.safeAreaRegions = []
        h.sizingOptions = []
        h.view.backgroundColor = .clear
        h.view.frame = contentView.bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addChild(h)
        contentView.addSubview(h.view)
        h.didMove(toParent: parent)
        host = h
    }

    required init?(coder: NSCoder) { fatalError() }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attributes
    }

    /// A reused cell takes its new size at once, so its hosted row is never drawn for the
    /// previous row's height (it overlapped its neighbour for a frame or more).
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        setNeedsLayout()
        layoutIfNeeded()
    }
}

/// A vertical stack of full-width items with heights measured by the controller. A short
/// transcript is pushed to the far (visual top) end, so it sits under the header as in
/// Messages, not on the composer.
@MainActor
final class TranscriptStackLayout: UICollectionViewLayout {
    weak var controller: PhoneTranscriptController?
    /// Item heights, item order (newest first).
    var heights: [CGFloat] = []
    private var origins: [CGFloat] = []
    private var total: CGFloat = 0
    private var lead: CGFloat = 0

    override func prepare() {
        super.prepare()
        origins.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        for h in heights {
            origins.append(y)
            y += h
        }
        total = y
        // Zero once the content fills the screen, so a prepend never shifts anything.
        lead = shortFill
    }

    /// The space a short transcript needs below its newest row (flipped) to sit at the top.
    private var shortFill: CGFloat {
        guard let cv = collectionView else { return 0 }
        let available = cv.bounds.height - cv.contentInset.top - cv.contentInset.bottom
        return max(0, available - total)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: total + shortFill)
    }

    func frame(at i: Int) -> CGRect {
        guard i < origins.count else { return .zero }
        return CGRect(x: 0, y: lead + origins[i], width: collectionView?.bounds.width ?? 0, height: heights[i])
    }

    /// Item indexes intersecting `rect` (content coordinates), newest first.
    func indexes(in rect: CGRect) -> [Int] {
        guard !origins.isEmpty, origins.count == heights.count else { return [] }
        // Binary search the first item whose bottom is below rect.minY.
        var lo = 0, hi = origins.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lead + origins[mid] + heights[mid] <= rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var out: [Int] = []
        var i = lo
        while i < origins.count, lead + origins[i] < rect.maxY {
            out.append(i)
            i += 1
        }
        return out
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        indexes(in: rect).map { attributes(for: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < origins.count else { return nil }
        return attributes(for: indexPath.item)
    }

    private func attributes(for i: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
        a.frame = frame(at: i)
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        nil
    }
}
#endif
