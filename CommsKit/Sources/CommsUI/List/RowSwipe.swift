import CommsCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Row swipes (sprint Task 9, rebuilt in polish r2 to Messages' iOS 26 feel): the conversation row
// slides; behind it CIRCULAR coloured buttons (an SF Symbol in a filled circle, no label — the
// title is the VoiceOver label) come out from under the row with parallax and scale. The physics:
// - the row tracks the finger 1:1 (no animation while dragging: only the moving row redraws);
//   past the last button it keeps going when the outer button can full-swipe, else it
//   rubber-bands (UIScrollView's formula);
// - past the full-swipe threshold the outer button expands into a capsule over the others with a
//   spring and a haptic tick (back below it: it shrinks, another tick);
// - on release the end is projected from the velocity (a flick opens or closes) and the row
//   settles with an interpolating spring that starts at the finger's velocity (inertia);
// - full swipe unchanged: released past the threshold, or flicked fast past the buttons, applies
//   the outer button (leading: Read / Unread; trailing: Archive). A menu button never fires.
// One row is open at a time (`SwipeCoordinator`): swiping another row, touching any row, or
// scrolling the list closes it.
//
// GESTURE MODEL:
// - iPhone: a mostly-horizontal drag that starts on a row is that row's swipe (a UIKit pan that
//   only begins for |vx| > 1.5·|vy|, so vertical scrolling is untouched). The list has no paging
//   gestures any more (polish r2: pages are chosen from the folder menu).
// - Mac: a two-finger horizontal swipe over a row (`MacSwipeTracker` decides on the first points;
//   vertical scrolling is never taken), with the same physics: the velocity comes from the last
//   ~80 ms of trackpad deltas, and the threshold tick is the trackpad's haptic.

/// One button of a row swipe: an action or a menu.
struct SwipeItem {
    let title: String
    let systemImage: String
    let color: Color
    let identifier: String
    var action: (() -> Void)?
    var menu: (() -> AnyView)?
    /// Applying it takes the row out of the list (Archive): a full swipe slides the row away.
    var removesRow = false

    init(title: String, systemImage: String, color: Color, identifier: String, removesRow: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.identifier = identifier
        self.removesRow = removesRow
        self.action = action
    }

    init<M: View>(title: String, systemImage: String, color: Color, identifier: String, @ViewBuilder menu: @escaping () -> M) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.identifier = identifier
        self.menu = { AnyView(menu()) }
    }
}

/// The swipe's arithmetic, shared by the iPhone pan and the Mac trackpad (pure, unit-tested).
/// Distances are from the screen edge of the side being revealed; `offset` is the row's offset
/// (positive = leading side revealed).
public struct SwipeGeometry: Equatable, Sendable {
    #if os(iOS)
    public static let diameter: CGFloat = 50
    public static let spacing: CGFloat = 10
    public static let inset: CGFloat = 12
    #else
    public static let diameter: CGFloat = 34
    public static let spacing: CGFloat = 8
    public static let inset: CGFloat = 8
    #endif
    /// Each button's share of the reveal.
    public static var slot: CGFloat { diameter + spacing }
    public static let minimumFull: CGFloat = 160
    /// Past the threshold by this much beyond the buttons.
    static let fullBeyondReveal: CGFloat = 86
    /// A flick this fast (points per second) past the buttons is a full swipe.
    static let flickVelocity: CGFloat = 900
    /// How far a release "coasts" (seconds of the release velocity) when deciding open / close.
    static let projection: CGFloat = 0.12

    public let leading: Int
    public let trailing: Int
    /// Whether the outer button of that side may fire on a full swipe (a menu may not).
    public var leadingFires = true
    public var trailingFires = true

    public init(leading: Int, trailing: Int, leadingFires: Bool = true, trailingFires: Bool = true) {
        self.leading = leading
        self.trailing = trailing
        self.leadingFires = leadingFires
        self.trailingFires = trailingFires
    }

    /// The open width of a side: the inset, the circles and their gaps, and a gap to the row.
    static func reveal(_ n: Int) -> CGFloat { n > 0 ? inset + slot * CGFloat(n) : 0 }
    public var leadingReveal: CGFloat { Self.reveal(leading) }
    public var trailingReveal: CGFloat { Self.reveal(trailing) }

    /// The full-swipe threshold for a reveal (never beyond 80 % of the row).
    public func full(_ reveal: CGFloat, rowWidth: CGFloat = .infinity) -> CGFloat {
        min(max(Self.minimumFull, reveal + Self.fullBeyondReveal), max(reveal + 24, rowWidth * 0.8))
    }

    /// UIScrollView's rubber band: `x` beyond the limit shows as this much (never more than `dimension`).
    public static func rubber(_ x: CGFloat, dimension: CGFloat = 120) -> CGFloat {
        guard x > 0 else { return 0 }
        return (1 - 1 / (x * 0.55 / dimension + 1)) * dimension
    }

    /// The offset shown for a raw drag: a side without buttons does not move; past the buttons a
    /// side that can full-swipe tracks 1:1 (up to the row's width), any other rubber-bands.
    public func track(_ raw: CGFloat, rowWidth: CGFloat = .infinity) -> CGFloat {
        let n = raw > 0 ? leading : trailing
        guard n > 0, raw != 0 else { return 0 }
        let fires = raw > 0 ? leadingFires : trailingFires
        let reveal = raw > 0 ? leadingReveal : trailingReveal
        let r = abs(raw)
        let shown: CGFloat
        if r <= reveal { shown = r } else if fires { shown = min(r, rowWidth) } else { shown = reveal + Self.rubber(r - reveal) }
        return raw > 0 ? shown : -shown
    }

    /// Past the full-swipe threshold (the outer button is expanded and fires on release).
    public func isArmed(_ offset: CGFloat, rowWidth: CGFloat = .infinity) -> Bool {
        if offset > 0 { return leading > 0 && leadingFires && offset >= full(leadingReveal, rowWidth: rowWidth) }
        if offset < 0 { return trailing > 0 && trailingFires && -offset >= full(trailingReveal, rowWidth: rowWidth) }
        return false
    }

    public enum End: Equatable, Sendable { case close, openLeading, openTrailing, fireLeading, fireTrailing }

    /// Where a swipe ends: `reach` = the offset at release, `velocity` in points per second.
    /// Full swipe as before: past the threshold, or a fast flick past the buttons. Otherwise the
    /// release is projected by its velocity: a flick open opens, a flick back closes.
    public func end(reach: CGFloat, velocity: CGFloat, rowWidth: CGFloat = .infinity) -> End {
        if reach > 0, leading > 0 {
            if leadingFires, reach >= full(leadingReveal, rowWidth: rowWidth) || (velocity > Self.flickVelocity && reach > leadingReveal) { return .fireLeading }
            return reach + velocity * Self.projection > leadingReveal / 2 ? .openLeading : .close
        }
        if reach < 0, trailing > 0 {
            let r = -reach
            if trailingFires, r >= full(trailingReveal, rowWidth: rowWidth) || (velocity < -Self.flickVelocity && r > trailingReveal) { return .fireTrailing }
            return r - velocity * Self.projection > trailingReveal / 2 ? .openTrailing : .close
        }
        return .close
    }

    /// Where button `index` (0 = outer) sits while the row is offset by `offset`.
    public struct ButtonLayout: Equatable, Sendable {
        /// Distance of the button's centre from the screen edge.
        public var center: CGFloat
        /// The capsule's width (the diameter, more for the stretched / expanded outer button).
        public var width: CGFloat
        public var scale: CGFloat
        public var opacity: CGFloat
    }

    /// Parallax: while opening, the buttons sit where they will rest, scaled towards the screen
    /// edge by the progress, so they come out from under the row slower than it moves, growing
    /// (from 55 %, capped so they never touch the row) and fading in. Past the reveal they hug the row edge and the outer one stretches;
    /// armed, the outer one covers the whole reveal and the others shrink away beneath it.
    public static func layout(index: Int, count: Int, offset: CGFloat, armed: Bool) -> ButtonLayout {
        let w = abs(offset)
        let reveal = Self.reveal(count)
        guard count > 0, reveal > 0 else { return ButtonLayout(center: 0, width: diameter, scale: 0, opacity: 0) }
        let restCenter = inset + diameter / 2 + slot * CGFloat(index)
        if armed {
            if index == 0 {
                let width = max(diameter, w - inset - spacing)
                return ButtonLayout(center: inset + width / 2, width: width, scale: 1, opacity: 1)
            }
            return ButtonLayout(center: restCenter + (w - reveal), width: diameter, scale: 0.4, opacity: 0)
        }
        if w <= reveal {
            let p = w / reveal
            // Grows from 55 %, but never wider than its share of the gap: the innermost circle
            // stays clear of the row's edge.
            let scale = min(0.55 + 0.45 * p, p * (1 + 2 * spacing / diameter))
            return ButtonLayout(center: restCenter * p, width: diameter, scale: scale, opacity: min(1, p * 1.6))
        }
        let extra = w - reveal
        if index == 0 {
            let width = diameter + extra
            return ButtonLayout(center: inset + width / 2, width: width, scale: 1, opacity: 1)
        }
        return ButtonLayout(center: restCenter + extra, width: diameter, scale: 1, opacity: 1)
    }
}

/// One row's swipe state. Observed by that row only (the offset changes every frame of a drag).
@MainActor @Observable
final class RowSwipeState {
    var offset: CGFloat = 0
    /// Past the full-swipe threshold: the outer button is expanded.
    var armed = false
    @ObservationIgnored var leading: [SwipeItem] = []
    @ObservationIgnored var trailing: [SwipeItem] = []
    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored var dragStart: CGFloat = 0
    @ObservationIgnored var rowWidth: CGFloat { frame.width > 0 ? frame.width : .infinity }

    var geometry: SwipeGeometry {
        SwipeGeometry(leading: leading.count, trailing: trailing.count,
                      leadingFires: leading.first?.action != nil, trailingFires: trailing.first?.action != nil)
    }
}

/// The swipe on a conversation row (both sides). `leading` / `trailing` are outer-first.
struct RowSwipe: ViewModifier {
    let id: String
    let leading: [SwipeItem]
    let trailing: [SwipeItem]

    @Environment(SwipeCoordinator.self) private var coordinator: SwipeCoordinator?
    @State private var state = RowSwipeState()

    func body(content: Content) -> some View {
        // The row's current actions (their titles and closures follow the thread).
        state.leading = leading
        state.trailing = trailing
        // A preset (snapshots, the design gallery) shows without the row having appeared.
        let preset = coordinator?.presetOffset(for: id)
        let x = preset ?? state.offset
        let armed = preset.map { state.geometry.isArmed($0) } ?? state.armed
        let closesOnTouch = coordinator?.openID != nil && (coordinator?.openID != id || x != 0)
        return content
            .overlay {
                // A row is open: touching any row (this one included) only closes it (Messages).
                if closesOnTouch {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { coordinator?.closeAll() }
                        .accessibilityHidden(true)
                }
            }
            .modifier(SwipeRender(offset: x, armed: armed, leading: leading, trailing: trailing) { coordinator?.closeAll() })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.frame = $0 }
            .onAppear { coordinator?.register(id, state) }
            .onDisappear { coordinator?.unregister(id, state) }
            #if os(iOS)
            .gesture(HorizontalPan(
                began: { coordinator?.begin(id) },
                changed: { dx in coordinator?.drag(id, translation: dx) },
                ended: { _, velocity in coordinator?.release(id, velocity: velocity) }))
            #endif
    }
}

/// The row's offset and the circles behind it, drawn from ONE animated value (round 3, owner:
/// "when a swipe closes the row text slides back over the icons"). The offset is `Animatable`,
/// so during a spring this body runs every frame with the interpolated offset: the circles are
/// laid out (parallax, scale, fade) and clipped to exactly the width the row has vacated at
/// that frame, and the layer leaves only when the row is home. Before, the layer was inserted
/// with `if x < 0` on the *target* offset: a close removed it at once and faded it out at full
/// size while the row slid back over it.
private struct SwipeRender: ViewModifier, @MainActor Animatable {
    var offset: CGFloat
    let armed: Bool
    let leading: [SwipeItem]
    let trailing: [SwipeItem]
    let close: () -> Void

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 0.5 { SwipeButtonsLayer(items: leading, offset: offset, armed: armed, edge: .leading, close: close).transition(.identity) }
            }
            .background(alignment: .trailing) {
                if offset < -0.5 { SwipeButtonsLayer(items: trailing, offset: offset, armed: armed, edge: .trailing, close: close).transition(.identity) }
            }
    }
}

/// The circles behind a swiped row, clipped to the revealed area.
private struct SwipeButtonsLayer: View {
    let items: [SwipeItem]
    let offset: CGFloat
    let armed: Bool
    let edge: HorizontalEdge
    let close: () -> Void

    var body: some View {
        let w = abs(offset)
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            // Inner first, so the outer (the full-swipe button) is drawn over the others.
            ForEach(Array(items.enumerated()).reversed(), id: \.offset) { i, item in
                let l = SwipeGeometry.layout(index: i, count: items.count, offset: offset, armed: armed)
                let lead = l.center - l.width / 2
                SwipeCircleButton(item: item, width: l.width, expanded: i == 0 && (armed || l.width > SwipeGeometry.diameter + 1),
                                  edge: edge, close: close)
                    .scaleEffect(l.scale)
                    .opacity(l.opacity)
                    .offset(x: edge == .leading ? lead : -lead)
                    .allowsHitTesting(l.opacity > 0.5)
            }
        }
        .frame(width: w, alignment: edge == .leading ? .leading : .trailing)
        .frame(maxHeight: .infinity)
        .clipped()
    }
}

/// One coloured circle (a capsule when the outer one stretches) with its symbol.
private struct SwipeCircleButton: View {
    let item: SwipeItem
    let width: CGFloat
    /// Stretched or expanded: the symbol rides at the row's side of the capsule.
    let expanded: Bool
    let edge: HorizontalEdge
    let close: () -> Void

    var body: some View {
        if let menu = item.menu {
            Menu { menu() } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel(item.title)
                .accessibilityIdentifier(item.identifier)
        } else {
            Button {
                close()
                item.action?()
            } label: {
                label
            }
            .buttonStyle(SwipePressStyle())
            .accessibilityLabel(item.title)
            .accessibilityIdentifier(item.identifier)
        }
    }

    private var label: some View {
        let d = SwipeGeometry.diameter
        return Image(systemName: item.systemImage)
            .font(.system(size: d * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: d, height: d)
            .frame(width: width, alignment: expanded ? (edge == .leading ? .trailing : .leading) : .center)
            .background(item.color, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Press feedback: the circle dims and shrinks a touch, as the system's swipe buttons do.
private struct SwipePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Coordinator (both platforms)

/// The list's swipes: one open row at a time, the shared physics (drag, threshold, release), and
/// on the Mac the trackpad monitor that drives them.
@MainActor @Observable
final class SwipeCoordinator {
    /// The open (or swiping) row. Every row reads it (a touch elsewhere closes the open one); it
    /// changes only when a swipe starts or ends.
    private(set) var openID: String?

    private struct Weak { weak var state: RowSwipeState? }
    @ObservationIgnored private var rows: [String: Weak] = [:]
    /// Offsets to show as soon as a row appears (snapshots and the design gallery).
    @ObservationIgnored private var presets: [String: CGFloat] = [:]

    func register(_ id: String, _ state: RowSwipeState) {
        rows[id] = Weak(state: state)
    }

    func unregister(_ id: String, _ state: RowSwipeState) {
        // An open row that scrolls away is forgotten (LazyVStack drops its view).
        if rows[id]?.state === state { rows[id] = nil }
    }

    private func state(_ id: String) -> RowSwipeState? { rows[id]?.state }

    /// Show `id` swiped by `offset` (snapshots and the design gallery), armed past the threshold.
    func preset(_ id: String, offset: CGFloat) {
        presets[id] = offset
    }

    func presetOffset(for id: String) -> CGFloat? { presets.isEmpty ? nil : presets[id] }

    // MARK: Physics

    /// A swipe starts on `id`: any other open row closes; a drag starts from where the row is.
    func begin(_ id: String) {
        if let open = openID, open != id { close(open) }
        openID = id
        state(id)?.dragStart = state(id)?.offset ?? 0
    }

    /// The finger moved: the row follows (rubber-banded past what it can show), no animation.
    func drag(_ id: String, translation dx: CGFloat) {
        guard let s = state(id) else { return }
        let g = s.geometry
        let x = g.track(s.dragStart + dx, rowWidth: s.rowWidth)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { s.offset = x }
        let armed = g.isArmed(x, rowWidth: s.rowWidth)
        if armed != s.armed {
            withAnimation(.spring(duration: 0.32, bounce: 0.28)) { s.armed = armed }
            SwipeHaptics.threshold(armed: armed)
        }
    }

    /// The finger lifted with this horizontal velocity (points per second).
    func release(_ id: String, velocity: CGFloat) {
        guard let s = state(id) else { openID = openID == id ? nil : openID; return }
        let g = s.geometry
        switch g.end(reach: s.offset, velocity: velocity, rowWidth: s.rowWidth) {
        case .close: settle(id, s, to: 0, velocity: velocity)
        case .openLeading: settle(id, s, to: g.leadingReveal, velocity: velocity)
        case .openTrailing: settle(id, s, to: -g.trailingReveal, velocity: velocity)
        case .fireLeading: fire(id, s, leading: true, velocity: velocity)
        case .fireTrailing: fire(id, s, leading: false, velocity: velocity)
        }
    }

    func closeAll() {
        if let id = openID { close(id) }
        openID = nil
    }

    private func close(_ id: String) {
        if let s = state(id), s.offset != 0 || s.armed { settle(id, s, to: 0, velocity: 0) }
        if openID == id { openID = nil }
    }

    /// Spring to `target`, starting at the finger's velocity (inertia), settling with a slight
    /// overshoot when opening and none when closing.
    private func settle(_ id: String, _ s: RowSwipeState, to target: CGFloat, velocity: CGFloat) {
        let distance = target - s.offset
        let relative = abs(distance) > 1 ? max(-40, min(40, velocity / distance)) : 0
        withAnimation(.interpolatingSpring(duration: 0.42, bounce: target == 0 ? 0 : 0.16, initialVelocity: relative)) {
            s.offset = target
            s.armed = false
        }
        if target == 0, openID == id { openID = nil }
    }

    /// A full swipe: the outer button expands (if a flick got there first), then it applies.
    /// Archive slides the row away (the list then removes it); anything else springs back.
    private func fire(_ id: String, _ s: RowSwipeState, leading: Bool, velocity: CGFloat) {
        guard let item = leading ? s.leading.first : s.trailing.first, let action = item.action else {
            return settle(id, s, to: 0, velocity: velocity)
        }
        if !s.armed {
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { s.armed = true }
            SwipeHaptics.threshold(armed: true)
        }
        if openID == id { openID = nil }
        guard item.removesRow, s.rowWidth.isFinite else {
            action()
            return settle(id, s, to: 0, velocity: velocity)
        }
        let away = (leading ? 1 : -1) * s.rowWidth
        withAnimation(.spring(duration: 0.28, bounce: 0)) {
            s.offset = away
        } completion: { [weak s, weak self] in
            action()
            // Still here a moment later (the action failed, or Undo): back into place.
            Task { @MainActor [weak s, weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let s, s.offset == away else { return }
                self?.settle(id, s, to: 0, velocity: 0)
            }
        }
    }

    // MARK: Mac trackpad

    @ObservationIgnored private var tracker = MacSwipeTracker()
    @ObservationIgnored private var consumingMomentum = false
    /// Recent (time, finger x) samples of the current swipe, for its release velocity.
    @ObservationIgnored private var samples: [(t: TimeInterval, x: CGFloat)] = []
    #if os(macOS)
    @ObservationIgnored private var monitor: Any?
    /// The sidebar's own window (`SwipeHostWindow`). The monitor sees every scroll of the app;
    /// only this window's, while it is key with no sheet over it, may swipe a row (final review I1:
    /// a pan in Quick Look, Settings, a sheet or a second window used to swipe a hidden row).
    @ObservationIgnored weak var hostWindow: NSWindow?
    #endif

    /// Whether a scroll event may drive this sidebar (pure, unit-tested): it must come from the
    /// sidebar's own window, that window must be key (not behind Quick Look, Settings or another
    /// window) and have no sheet attached.
    nonisolated static func accepts(eventWindow: AnyObject?, host: AnyObject?, hostIsKey: Bool, hostHasSheet: Bool) -> Bool {
        guard let eventWindow, let host, eventWindow === host else { return false }
        return hostIsKey && !hostHasSheet
    }

    /// The release velocity from recent samples (points per second; 0 with too little to go on).
    nonisolated static func velocity(_ samples: [(t: TimeInterval, x: CGFloat)]) -> CGFloat {
        guard let last = samples.last, let first = samples.first(where: { last.t - $0.t <= 0.08 }), last.t - first.t > 0.004 else { return 0 }
        return (last.x - first.x) / CGFloat(last.t - first.t)
    }

    func hit(_ p: CGPoint) -> String? {
        rows.first { $0.value.state?.frame.contains(p) == true }?.key
    }

    #if os(macOS)
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let e = event
            let pass = MainActor.assumeIsolated { self?.handle(e) != nil || self == nil }
            return pass ? event : nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// nil = the event was the swipe's (the scroll view must not also scroll).
    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.type == .leftMouseDown || e.type == .rightMouseDown {
            // A click anywhere but the open row (its buttons included) closes it; rows have an
            // overlay for that too, this catches the rest of the window.
            if let id = openID, e.window === hostWindow, let content = e.window?.contentView {
                let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
                if state(id)?.frame.contains(p) != true { closeAll() }
            }
            return e
        }
        // Momentum after a swipe we took belongs to it too.
        if !e.momentumPhase.isEmpty { return consumingMomentum ? nil : e }
        guard e.hasPreciseScrollingDeltas, let window = e.window, let content = window.contentView else { return e }
        guard Self.accepts(eventWindow: window, host: hostWindow, hostIsKey: hostWindow?.isKeyWindow ?? false,
                           hostHasSheet: hostWindow?.attachedSheet != nil) else {
            // Not this sidebar's: untouched, and a half-made swipe here is abandoned.
            if tracker.decision != .undecided { tracker.reset() }
            return e
        }
        if e.phase.contains(.began) {
            tracker.reset()
            samples = []
            consumingMomentum = false
        }
        guard !e.phase.isEmpty else { return e }
        // Fingers' direction, whatever the "natural scrolling" setting.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
        let wasUndecided = tracker.decision == .undecided
        let decision = tracker.feed(dx: e.scrollingDeltaX * sign, dy: e.scrollingDeltaY * sign,
                                    hit: wasUndecided ? hit(p).map { .row($0) } : nil)
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        switch decision {
        case .horizontal(.row(let id)):
            if wasUndecided { begin(id) }
            samples.append((e.timestamp, tracker.dx))
            if samples.count > 12 { samples.removeFirst(samples.count - 12) }
            drag(id, translation: tracker.dx)
            if ended {
                consumingMomentum = true
                release(id, velocity: Self.velocity(samples))
            }
            return nil
        case .vertical:
            if openID != nil, tracker.dy != 0 { closeAll() }
            return e
        case .undecided, .ignored:
            return e
        }
    }
    #endif
}

/// The threshold tick: a medium impact on iPhone, the trackpad's alignment haptic on the Mac.
@MainActor
enum SwipeHaptics {
    static func threshold(armed: Bool) {
        #if os(iOS)
        let g = UIImpactFeedbackGenerator(style: armed ? .medium : .light)
        g.impactOccurred()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
}

#if os(iOS)
/// A pan that begins only when the finger moves mostly sideways (UIKit decides, so the
/// enclosing ScrollView keeps every vertical drag).
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var began: () -> Void = {}
    var changed: (CGFloat) -> Void
    var ended: (_ dx: CGFloat, _ velocityX: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ r: UIPanGestureRecognizer, context: Context) {
        let dx = r.translation(in: r.view).x
        switch r.state {
        case .began:
            began()
            changed(dx)
        case .changed: changed(dx)
        case .ended, .cancelled, .failed: ended(dx, r.velocity(in: r.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }
    }
}
#endif

// MARK: - Mac trackpad

#if os(macOS)
/// Hands the coordinator the window the sidebar lives in (and keeps it current if it moves).
struct SwipeHostWindow: NSViewRepresentable {
    let coordinator: SwipeCoordinator

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.coordinator = coordinator
        return v
    }

    func updateNSView(_ v: Probe, context: Context) {
        v.coordinator = coordinator
        coordinator.hostWindow = v.window
    }

    final class Probe: NSView {
        weak var coordinator: SwipeCoordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated { coordinator?.hostWindow = window }
        }
    }
}
#endif

/// Decides what a two-finger trackpad movement is (pure, unit-tested): nothing yet, a vertical
/// scroll (left alone), or a horizontal swipe on a row.
public struct MacSwipeTracker: Equatable, Sendable {
    public enum Target: Equatable, Sendable { case row(String) }
    public enum Decision: Equatable, Sendable { case undecided, vertical, horizontal(Target), ignored }

    public private(set) var decision: Decision = .undecided
    /// Finger movement so far (right / down positive), points.
    public private(set) var dx: CGFloat = 0
    public private(set) var dy: CGFloat = 0
    public init() {}

    /// The movement needed before a direction is decided.
    static let slop: CGFloat = 6

    /// Feed one scroll event's finger movement. `hit` names the row under the pointer at the
    /// start (nil = none). Returns the decision.
    @discardableResult
    public mutating func feed(dx ddx: CGFloat, dy ddy: CGFloat, hit: Target?) -> Decision {
        dx += ddx
        dy += ddy
        guard decision == .undecided else { return decision }
        guard abs(dx) >= Self.slop || abs(dy) >= Self.slop else { return decision }
        if abs(dx) > abs(dy) * 1.5 {
            decision = hit.map { .horizontal($0) } ?? .ignored
        } else {
            decision = .vertical
        }
        return decision
    }

    public mutating func reset() { self = MacSwipeTracker() }
}
