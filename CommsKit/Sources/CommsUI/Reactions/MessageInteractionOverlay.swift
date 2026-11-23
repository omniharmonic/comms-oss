import CoreGraphics

/// Where the overlay's pieces go (window coordinates). Pure, unit-tested.
struct MessageOverlayGeometry: Equatable {
    var shift: CGFloat
    var barOrigin: CGPoint
    var moreOrigin: CGPoint
    var menuOrigin: CGPoint

    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    /// Tapback badges stick out past the bubble's edge by about this much: the smiley clears them.
    static let badgeOverhang: CGFloat = 12
    #if os(macOS)
    static let moreSize: CGFloat = 32
    #else
    static let moreSize: CGFloat = 44
    #endif

    /// - content: the bubbles' frame; lifts: the bubble may move (long press) so the bar above
    ///   and the menu below fit on screen. A bubble taller than the screen keeps the bar at the
    ///   top and the menu over its lower part, as Messages does.
    static func layout(content: CGRect, screen: CGSize, safeTop: CGFloat, safeBottom: CGFloat, outgoing: Bool,
                       bar: CGSize?, menu: CGSize?, lifts: Bool) -> MessageOverlayGeometry {
        let top = safeTop + gap
        let bottom = screen.height - safeBottom - gap
        let above = bar.map { $0.height + gap } ?? 0
        let below = menu.map { $0.height + gap } ?? 0
        var shift: CGFloat = 0
        if lifts {
            if content.minY - above < top { shift = top - (content.minY - above) }
            if content.maxY + shift + below > bottom { shift -= content.maxY + shift + below - bottom }
            if content.minY + shift - above < top { shift = top + above - content.minY }
        }
        func clampX(_ x: CGFloat, width: CGFloat) -> CGFloat {
            min(max(margin, x), max(margin, screen.width - margin - width))
        }
        let barSize = bar ?? .zero
        let barX = clampX(outgoing ? content.maxX - barSize.width : content.minX, width: barSize.width)
        var barY = content.minY + shift - above
        if !lifts, barY < top { barY = top }
        // The smiley sits in the free space beside the bubble (left of an outgoing one, right of
        // an incoming one), under the bar, as in Messages.
        let moreX = outgoing ? max(margin, content.minX - gap - badgeOverhang - moreSize)
            : min(screen.width - margin - moreSize, content.maxX + gap + badgeOverhang)
        let menuSize = menu ?? .zero
        let menuX = clampX(outgoing ? content.maxX - menuSize.width : content.minX, width: menuSize.width)
        let menuY = min(content.maxY + shift + gap, bottom - menuSize.height)
        return MessageOverlayGeometry(shift: shift, barOrigin: CGPoint(x: barX, y: barY),
                                      moreOrigin: CGPoint(x: moreX, y: barY + barSize.height + 4),
                                      menuOrigin: CGPoint(x: menuX, y: menuY))
    }
}

import CommsCore
import PrismModels
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if canImport(Translation)
import Translation
#endif

/// The "more emoji" hook: the overlay's smiley shows this picker (iOS: in a sheet; Mac: in a
/// glass panel under the tapback bar); `pick` reacts with the chosen emoji and closes the
/// overlay. The default (no environment value) is Task 5's in-app `EmojiPicker`.
public struct MessageEmojiPicker: Sendable {
    public var makeView: @MainActor @Sendable (_ pick: @escaping @MainActor @Sendable (String) -> Void) -> AnyView
    public init(makeView: @escaping @MainActor @Sendable (_ pick: @escaping @MainActor @Sendable (String) -> Void) -> AnyView) {
        self.makeView = makeView
    }
}

extension EnvironmentValues {
    @Entry public var messageEmojiPicker: MessageEmojiPicker? = nil
}

/// What the overlay shows the message with (the transcript's environment, frozen).
struct MessageOverlayContext {
    var message: CommsMessage
    var position: RunPosition
    var isGroup: Bool
    /// The whole message view's frame and its bubbles' frame, in window coordinates.
    var rowFrame: CGRect
    var contentFrame: CGRect
    var screen: CGSize
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var metrics: BubbleMetrics
    var maxWidth: CGFloat
    var mediaLoader: MediaLoader
    var avatarLoader: AvatarLoader?
    var selfSenderIDs: Set<String>
    var gradientHeight: CGFloat
    /// The pane the frames are relative to, in window coordinates, when the overlay is NOT
    /// hosted on that pane: it then measures where it was put and shifts onto the pane. Nil (the
    /// normal case) = the overlay's host IS the pane — the Mac's AppKit host over the transcript
    /// scroll view since round 3 (`TranscriptTableController.showOverlay`), and iPhone / iPad.
    var paneInWindow: CGRect? = nil
}

/// DEBUG: the overlay's pieces as drawn, in window coordinates (the real-window test reads them).
@MainActor
enum MessageOverlayProbe {
    static var frames: [String: CGRect] = [:]
    static func reset() { frames = [:] }
}

extension View {
    /// DEBUG builds: record this view's window frame under `name` (no-op in Release).
    func overlayProbe(_ name: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MessageOverlayProbe.frames[name] = $0 }
        #else
        self
        #endif
    }
}

/// Where the overlay draws its pane (pure, unit-tested): the shift from where SwiftUI placed the
/// overlay (its frame in window coordinates) to the pane the frames are measured in.
enum MessageOverlayPlacement {
    static func shift(pane: CGRect?, overlayOrigin: CGPoint?) -> CGSize {
        guard let pane, let overlayOrigin else { return .zero }
        return CGSize(width: pane.minX - overlayOrigin.x, height: pane.minY - overlayOrigin.y)
    }
}

/// Messages' message overlay on iPhone/iPad, and (the same, Mac Messages 26 style) on the Mac,
/// where right-click, Control-click or a Force Touch opens `.menu`, a double-click `.tapbacks`,
/// and Esc / a click away closes it:
/// - `.menu` (long press): the background blurs and dims, the bubble lifts (moving only as far
///   as needed so everything fits), the glass tapback bar appears above it with the smiley
///   "more emoji" bubble, and the glass action menu below (Reply, Copy, Translate, Select);
/// - `.tapbacks` (double tap): the tapback bar alone over the transcript;
/// - `.details` (tap the badges): who reacted with what.
/// A tap outside closes it.
struct MessageInteractionOverlay: View {
    let context: MessageOverlayContext
    let interactions: MessageInteractions
    let onClose: () -> Void
    @State private var mode: MessageOverlayMode

    init(context: MessageOverlayContext, mode: MessageOverlayMode, interactions: MessageInteractions, onClose: @escaping () -> Void) {
        self.context = context
        self.interactions = interactions
        self.onClose = onClose
        _mode = State(initialValue: mode)
    }

    @State private var appeared = false
    @State private var barSize = CGSize(width: TapbackPicker.width(count: 6), height: TapbackPicker.height)
    @State private var menuSize: CGSize?
    @State private var detailsSize = CGSize(width: 140, height: 160)
    @State private var showsTranslation = false
    @State private var showsSelect = false
    /// The emoji picker (the smiley): any emoji as a reaction.
    @State private var showsEmojiPicker = false
    @State private var closing = false
    /// A tapback was picked: further taps do nothing (review M3).
    @State private var picked = false
    /// Top of the keyboard (the emoji keyboard) in window coordinates, when it is up.
    @State private var keyboardTop: CGFloat?
    /// Mac: where SwiftUI put the overlay, in window coordinates (see `paneInWindow`).
    @State private var placedAt: CGPoint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.messageEmojiPicker) private var emojiPicker
    @FocusState private var focused: Bool

    #if os(iOS)
    static let platformSelect = true
    #else
    static let platformSelect = false
    #endif

    private var message: CommsMessage { interactions.message(context.message.id) ?? context.message }
    private var outgoing: Bool { message.sender.isSelf }
    private var canReact: Bool { interactions.canReact(message) }
    private var menuGroups: [[MessageMenuItem]] {
        MessageMenuItem.groups(for: message, interactions: interactions, platformSelect: Self.platformSelect,
                               showReactions: !Self.platformSelect && !message.reactions.isEmpty)
    }

    private var geometry: MessageOverlayGeometry {
        let groups = menuGroups
        let menu: CGSize? = mode == .menu && !groups.isEmpty
            ? (menuSize ?? CGSize(width: MessageActionMenu.width, height: MessageActionMenu.height(groups))) : nil
        return MessageOverlayGeometry.layout(content: context.contentFrame, screen: context.screen, safeTop: context.safeTop,
                                             safeBottom: context.safeBottom, outgoing: outgoing,
                                             bar: canReact && mode != .details ? barSize : nil, menu: menu, lifts: mode == .menu)
    }

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            background
            if mode == .menu { liftedBubble(shift: g.shift) }
            if canReact, mode != .details {
                bar(g)
            }
            if mode == .menu, !menuGroups.isEmpty, !showsEmojiPicker, keyboardTop == nil {
                MessageActionMenu(groups: menuGroups, action: perform)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
                    .scaleEffect(appeared ? 1 : 0.6, anchor: outgoing ? .topTrailing : .topLeading)
                    .opacity(appeared ? 1 : 0)
                    .offset(x: g.menuOrigin.x, y: g.menuOrigin.y)
                    .overlayProbe("menu")
            }
            #if os(macOS)
            // Mac: the picker opens in place under the bar (a glass panel; the overlay is its own window).
            if showsEmojiPicker {
                pickerView { pick($0) }
                    .frame(width: 340, height: 380)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                    .offset(x: max(12, min(g.barOrigin.x, context.screen.width - 12 - 340)), y: g.barOrigin.y + barSize.height + 10)
            }
            #endif
            if mode == .details { details }
        }
        .frame(width: context.screen.width, height: context.screen.height, alignment: .topLeading)
        // A lifted bubble taller than the pane never draws outside it.
        .clipped()
        .ignoresSafeArea()
        #if os(macOS)
        // Measured before the shift (an offset does not move the layout frame), then moved onto
        // the transcript pane; hidden until measured so it never flashes in the wrong place.
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { placedAt = $0 }
        .offset(MessageOverlayPlacement.shift(pane: context.paneInWindow, overlayOrigin: placedAt))
        .opacity(context.paneInWindow == nil || placedAt != nil ? 1 : 0)
        #endif
        .environment(\.bubbleMetrics, context.metrics)
        .environment(\.bubbleMaxWidth, context.maxWidth)
        .environment(\.mediaLoader, context.mediaLoader)
        .environment(\.avatarLoader, context.avatarLoader)
        .environment(\.selfSenderIDs, context.selfSenderIDs)
        .environment(\.outgoingGradientHeight, context.gradientHeight)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.78)) { appeared = true }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTop = end.minY < context.screen.height - 1 ? end.minY : nil
        }
        // iPhone / iPad: the picker in a sheet over the overlay (Task 5).
        .sheet(isPresented: $showsEmojiPicker) {
            pickerView { key in
                showsEmojiPicker = false
                pick(key)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSelect, onDismiss: close) {
            SelectTextSheet(text: MessageInteractions.text(of: message) ?? "")
        }
        #else
        // Keyboard: Esc closes, 1–6 pick a tapback (Mac Messages), Tab moves through the bar
        // and the menu (Full Keyboard Access).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onExitCommand { close() }
        .onKeyPress(characters: .decimalDigits) { press in
            guard canReact, mode != .details, let n = Int(press.characters), (1...Tapbacks.keys.count).contains(n) else { return .ignored }
            pick(Tapbacks.keys[n - 1])
            return .handled
        }
        #endif
        .accessibilityAction(.escape) { close() }
        .translationPresentation(isPresented: $showsTranslation, text: MessageInteractions.text(of: message) ?? "")
        .onChange(of: showsTranslation) { _, shown in if !shown { close() } }
    }

    // MARK: Pieces

    @ViewBuilder private var background: some View {
        ZStack {
            if mode == .menu {
                Rectangle().fill(.regularMaterial)
                Color.black.opacity(scheme == .dark ? 0.3 : 0.06)
            } else {
                Color.black.opacity(0.001)
            }
        }
        .opacity(appeared ? 1 : 0)
        .overlayProbe("dim")
        .contentShape(.rect)
        .onTapGesture { close() }
        .accessibilityElement()
        .accessibilityLabel("Dismiss")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { close() }
        .accessibilityIdentifier("message-overlay-dismiss")
    }

    private func liftedBubble(shift: CGFloat) -> some View {
        MessageBubble(message: message, position: context.position, isGroup: context.isGroup)
            .frame(width: context.rowFrame.width)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(appeared ? 0.12 : 0), radius: 12, y: 4)
            .offset(x: context.rowFrame.minX, y: context.rowFrame.minY + (appeared ? shift : 0))
            .overlayProbe("bubble")
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func bar(_ g: MessageOverlayGeometry) -> some View {
        // With the emoji keyboard up the bar (and the smiley) rise above it.
        let lift = keyboardTop.map { min(0, $0 - 16 - MessageOverlayGeometry.moreSize - (g.barOrigin.y + barSize.height)) } ?? 0
        return ZStack(alignment: .topLeading) {
            TapbackPicker(selected: Set(message.reactions.filter(\.mine).map(\.key)), recents: RecentReactions.all) { pick($0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .offset(x: g.barOrigin.x, y: g.barOrigin.y)
                .overlayProbe("bar")
            EmojiMoreButton(size: MessageOverlayGeometry.moreSize) { moreEmoji() }
            .offset(x: g.moreOrigin.x, y: g.moreOrigin.y)
        }
        .offset(y: lift)
        .allowsHitTesting(!picked)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.5, anchor: outgoing ? .bottomTrailing : .bottomLeading)
        .opacity(appeared ? 1 : 0)
    }

    private var details: some View {
        let people = interactions.people(message.id)
        let c = context.contentFrame
        let badgeX = outgoing ? c.minX : c.maxX
        let x = min(max(12, badgeX - detailsSize.width / 2), context.screen.width - 12 - detailsSize.width)
        let above = c.minY - 6 - detailsSize.height
        let y = above >= context.safeTop + 8 ? above : min(c.maxY + 6, context.screen.height - context.safeBottom - 8 - detailsSize.height)
        return ReactionDetailsView(people: people, avatar: { interactions.avatar($0) })
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { detailsSize = $0 }
            .scaleEffect(appeared ? 1 : 0.6, anchor: .bottom)
            .opacity(appeared ? 1 : 0)
            .offset(x: x, y: y)
    }

    // MARK: Actions

    /// The picker the smiley opens: the environment's, else the in-app `EmojiPicker` — built
    /// directly (not through AnyView) so its search field keeps focus when the overlay re-renders
    /// as the keyboard comes up.
    @ViewBuilder private func pickerView(_ onPick: @escaping @MainActor @Sendable (String) -> Void) -> some View {
        if let emojiPicker { emojiPicker.makeView(onPick) } else { EmojiPicker { onPick($0) } }
    }

    /// The smiley: opens (Mac: toggles) the emoji picker.
    private func moreEmoji() {
        showsEmojiPicker.toggle()
    }

    private func pick(_ key: String) {
        guard !picked, !closing else { return }
        picked = true
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
        interactions.react(key, message.id)
        // Let the badge land before the overlay goes (Messages keeps the bar a beat).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            close()
        }
    }

    private func perform(_ kind: MessageMenuItem.Kind) {
        switch kind {
        case .reply:
            interactions.reply(message)
            close()
        case .copy:
            if let t = MessageInteractions.text(of: message) { MessageInteractions.copy(t) }
            close()
        case .translate:
            showsTranslation = true
        case .select:
            showsSelect = true
        case .showReactions:
            withAnimation(.snappy) { mode = .details }
        case .askOmni:
            interactions.askOmni?(message)
            close()
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.easeOut(duration: 0.2)) { appeared = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(210))
            onClose()
        }
    }
}

#if os(iOS)
/// Select: the message's text in a sheet where any part of it can be selected and copied.
struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .padding(.horizontal, 12)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.text = text
        v.accessibilityIdentifier = "select-text"
        DispatchQueue.main.async {
            v.becomeFirstResponder()
            v.selectAll(nil)
        }
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}

/// Presents the overlay over everything (keeps the transcript's flipped geometry out of it).
final class MessageOverlayController: UIHostingController<AnyView> {
    init(root: AnyView) {
        super.init(rootView: root)
        modalPresentationStyle = .overFullScreen
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        // The overlay is laid out for the size and text size it opened with: a rotation, a
        // Split View / Stage Manager resize or a Dynamic Type change closes it (review I3).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self,
                                 UITraitVerticalSizeClass.self]) { (c: MessageOverlayController, _) in
            c.close()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if size != view.bounds.size { close() }
    }

    func close() {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        view.window?.endEditing(true)
        dismiss(animated: false)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
#endif
