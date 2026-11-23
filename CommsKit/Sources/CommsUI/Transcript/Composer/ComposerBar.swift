import CommsClient
import CommsCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The Messages composer: a glass "+" circle (the attachment menu) and a glass capsule field
/// whose placeholder names the network ("iMessage", "WhatsApp" …). Typing morphs in the blue
/// send arrow inside the field; picked photos and files show as removable previews inside the
/// field above the text; the waveform in the empty field records an audio message.
///
/// Sending: on the Mac Return sends and Option-Return starts a new line (as in Messages); on
/// iPhone/iPad Return is a new line and the arrow sends. In Omni mode (`@Omni …` or the + menu's
/// Omni row) Return on the Mac and the keyboard's Send key on iPhone/iPad submit the instruction
/// to Omni exactly like the ✦ button — never to the chat (polish r2). `onSend` receives the text and the
/// attachments; the transcript's `TimelineStore` sends each attachment as its own message,
/// then the text. Where the thread's channel cannot send (`canSend` false, e.g. iMessage until
/// BlueBubbles) the field is disabled and says so in its placeholder.
///
/// Geometry is the real iOS 27 app's (design/fidelity/apple-ios/transcript-light.ax.txt and
/// composer-text-light.ax.txt): "+" 40 pt at x 28; field 80 → 374, 40.3 pt tall, text from
/// x 91; bottom edge 28 pt above the screen bottom; send button 38 × 28 inside the field.
public struct ComposerBar: View {
    let network: CommsNetwork?
    let canSend: Bool
    let encrypted: Bool
    /// The channel takes attachments and audio ("+" and the waveform); false on email.
    let canAttach: Bool
    /// The server's cap on one attachment (nil = unknown): bigger picks are refused at once.
    let maxAttachmentBytes: Int?
    /// A merged conversation's channels (the placeholder becomes "WhatsApp ⌄"); empty = none.
    let channelChoices: [CommsChannelRef]
    let selectedChannel: CommsChannelRef?
    let onPickChannel: @MainActor (CommsChannelRef) -> Void
    /// `@` suggestions for a query (nil where mentions can't be sent).
    let mentionCandidates: (@MainActor (String) -> [CommsMember])?
    /// Drops on the conversation (the transcript or this bar) arrive here.
    let dropInbox: ComposerDropInbox?
    /// The conversation, for Omni (`@Omni`, the + menu's Omni row); nil = no Omni here.
    let omniThreadID: String?
    /// Replaces the network placeholder while sending is possible (a forum: "Reply in #General").
    let placeholderOverride: String?
    /// The composer went from empty to holding text / attachments (true) or back (false).
    let onComposingChange: (@MainActor (Bool) -> Void)?
    let onSend: @MainActor (String, [OutgoingAttachment], [ComposerMention]) -> Void

    @State private var draft: String
    @State private var attachments: [OutgoingAttachment]
    @State private var recorder: VoiceRecorder?
    @State private var showsPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsFiles = false
    @State private var showsCamera = false
    /// Why the last pick couldn't be attached (an alert).
    @State private var importError: String?
    @State private var importing = 0
    /// Members picked from the `@` suggestions (resolved against the text when sending).
    @State private var mentionPicks: [ComposerMention] = []
    /// The draft the picks' locations refer to (they follow every edit).
    @State private var trackedDraft = ""
    #if os(macOS)
    @State private var paste = ComposerPasteMonitor()
    #endif
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.simulatedVoiceRecorder) private var simulatedRecorder
    @Environment(\.omniStore) private var omni

    /// - Parameters:
    ///   - canSend: the thread's channel declares `send`; false disables the composer.
    ///   - draft / attachments / recorder: a starting state (previews and snapshots).
    ///   - onSend: the owner pressed Send (Return on the Mac) with this text and attachments.
    public init(
        network: CommsNetwork?,
        canSend: Bool = false,
        encrypted: Bool = false,
        canAttach: Bool = true,
        maxAttachmentBytes: Int? = nil,
        dropInbox: ComposerDropInbox? = nil,
        omniThreadID: String? = nil,
        draft: String = "",
        attachments: [OutgoingAttachment] = [],
        recorder: VoiceRecorder? = nil,
        channelChoices: [CommsChannelRef] = [],
        selectedChannel: CommsChannelRef? = nil,
        onPickChannel: @escaping @MainActor (CommsChannelRef) -> Void = { _ in },
        mentionCandidates: (@MainActor (String) -> [CommsMember])? = nil,
        placeholder: String? = nil,
        onComposingChange: (@MainActor (Bool) -> Void)? = nil,
        onSend: @escaping @MainActor (String, [OutgoingAttachment], [ComposerMention]) -> Void = { _, _, _ in }
    ) {
        self.network = network
        self.canSend = canSend
        self.encrypted = encrypted
        self.canAttach = canAttach
        self.maxAttachmentBytes = maxAttachmentBytes
        self.channelChoices = channelChoices
        self.selectedChannel = selectedChannel
        self.onPickChannel = onPickChannel
        self.mentionCandidates = mentionCandidates
        self.dropInbox = dropInbox
        self.omniThreadID = omniThreadID
        self.placeholderOverride = placeholder
        self.onComposingChange = onComposingChange
        self.onSend = onSend
        _draft = State(initialValue: draft)
        _trackedDraft = State(initialValue: draft)
        _attachments = State(initialValue: attachments)
        _recorder = State(initialValue: recorder)
    }

    #if os(macOS)
    // Mac Messages (guide macos26-guide-window-sidebar-transcript.png at ≈ 0.81 px/pt, and the
    // owner's description): "+" glass circle, capsule field with the waveform, and a separate
    // emoji circle at the far right; Body 13.
    static let plusSize: CGFloat = 28
    static let fieldHeight: CGFloat = 28
    static let gap: CGFloat = 8
    static let textInset: CGFloat = 12
    static let sendSize = CGSize(width: 28, height: 20)
    static let fontSize: CGFloat = 13
    static let lineHeight: CGFloat = 16
    static let glyphSize: CGFloat = 13
    static let sideMargin: CGFloat = 12
    static let focusedSideMargin: CGFloat = 12
    static let focusedLift: CGFloat = 0
    static let showsEmojiButton = true
    static let previewHeight: CGFloat = 64
    #else
    static let plusSize: CGFloat = 40
    static let fieldHeight: CGFloat = 40.33
    static let gap: CGFloat = 12
    static let textInset: CGFloat = 16 // placeholder ink at x 97.3 (field at 80)
    static let sendSize = CGSize(width: 38, height: 28)
    static let fontSize: CGFloat = 17
    static let lineHeight: CGFloat = 22
    static let glyphSize: CGFloat = 17
    static let sideMargin: CGFloat = 28
    // Keyboard up, Messages widens the bar: "+" moves to x 16 and the field ends 16 pt from
    // the edge, 16 pt above the keyboard (composer-text-light.ax.txt).
    static let focusedSideMargin: CGFloat = 16
    static let focusedLift: CGFloat = 22
    static let showsEmojiButton = false
    static let previewHeight: CGFloat = 88
    #endif

    /// "iMessage" for iMessage; otherwise the network's name, as Messages says "Text Message".
    static func placeholder(for network: CommsNetwork?) -> String {
        guard let network else { return "Message" }
        switch network {
        case .imessage: return "iMessage"
        case .sms: return "Text Message"
        default: return network.displayName
        }
    }

    /// The disabled field's placeholder, in Messages' "Text Message • SMS" form.
    static func disabledPlaceholder(for network: CommsNetwork?, encrypted: Bool = false) -> String {
        "\(placeholder(for: network)) • \(encrypted ? "Encrypted" : "Read Only")"
    }

    private var isDropTargeted: Bool { (dropInbox ?? fallbackInbox).isTargeted }
    /// A composer used without a transcript (previews, snapshots) still takes drops.
    @State private var fallbackInbox = ComposerDropInbox()

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasContent: Bool { omniActive ? !OmniStore.instruction(from: draft).isEmpty : hasText || !attachments.isEmpty }
    /// `@Omni …` typed while Omni is unavailable or not known yet: refused, never sent to the chat
    /// (review I2; D9 "@Omni is a private instruction").
    /// Also the + menu's Omni mode while Omni is unavailable (review N6): the field is still Omni's.
    private var omniBlocked: Bool { !omniActive && (OmniStore.addressesOmni(draft) || omniModeOn) }

    // MARK: Omni (PRD §5.7): `@Omni` or the + menu's Omni row turn the field into a private
    // instruction to Omni — tinted, "Ask Omni…", a ✦ send button. Nothing typed there reaches the chat.

    /// Omni in Comms is offered for this conversation.
    private var omniAvailable: Bool { omniThreadID != nil && (omni?.isAvailable ?? false) }
    /// The field is Omni's instruction field (the + menu row, or `@Omni` at the start).
    private var omniActive: Bool {
        guard omniAvailable, let id = omniThreadID else { return false }
        return (omni?.omniComposer.contains(id) ?? false) || OmniStore.addressesOmni(draft)
    }
    private var omniModeOn: Bool { omniThreadID.map { omni?.omniComposer.contains($0) ?? false } ?? false }
    private var fieldEnabled: Bool { canSend || omniActive }

    private func toggleOmni() {
        guard omniAvailable, let id = omniThreadID, let omni else { return }
        if omni.omniComposer.contains(id) { omni.endAsk(threadID: id) } else { omni.beginAsk(threadID: id) }
        focused = true
    }
    private var isRecording: Bool { recorder?.isActive ?? false }
    private var sendBlue: Color { scheme == .dark ? Color(red: 0, green: 0x91 / 255, blue: 1) : Tokens.color.accent.color }

    /// The merged-conversation picker shows (more than one channel, nothing typed yet).
    var showsChannelPicker: Bool { channelChoices.count > 1 && draft.isEmpty && attachments.isEmpty && !omniModeOn }

    /// The `@` suggestions for what is being typed (empty when none).
    var suggestions: [CommsMember] {
        guard let mentionCandidates, let q = MentionText.activeQuery(in: draft) else { return [] }
        return mentionCandidates(q)
    }

    public var body: some View {
        content
            .onChange(of: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty, initial: true) { _, empty in
                onComposingChange?(!empty)
            }
    }

    @ViewBuilder private var content: some View {
        let found = suggestions
        VStack(alignment: .leading, spacing: 8) {
            if !found.isEmpty {
                MentionSuggestions(members: found, fontSize: Self.fontSize) { member in pick(member) }
                .padding(.horizontal, focused ? Self.focusedSideMargin : Self.sideMargin)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bar
        }
        .animation(.snappy(duration: 0.2), value: found.map(\.id))
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            if let recorder, recorder.isActive {
                CircleGlyphButton(systemImage: recorder.phase == .recording ? "xmark" : "trash", size: Self.plusSize, glyph: Self.glyphSize,
                                  label: recorder.phase == .recording ? "Cancel recording" : "Delete recording", id: "recorder-delete") {
                    recorder.discard()
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                plusMenu
            }

            Group {
                if let recorder, recorder.isActive {
                    VoiceRecorderField(recorder: recorder, fieldHeight: Self.fieldHeight, glyph: Self.glyphSize, fontSize: Self.fontSize,
                                       sendSize: Self.sendSize, sendBlue: sendBlue) {
                        if let note = recorder.take() { onSend("", [note], []) }
                    }
                } else {
                    textField
                }
            }
            .frame(minHeight: Self.fieldHeight)
            .background {
                if omniActive {
                    // Omni's tint under the glass, and its outline: the field visibly talks to Omni.
                    RoundedRectangle(cornerRadius: Self.fieldHeight / 2, style: .continuous)
                        .fill(OmniStyle.tint.opacity(0.10))
                }
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.fieldHeight / 2))
            .overlay {
                // A drag the composer can attach is over the conversation: the field takes the
                // system's drop-target ring (the accent colour, as around a focused control).
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: Self.fieldHeight / 2, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 3)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("composer-drop-target")
                } else if omniActive {
                    RoundedRectangle(cornerRadius: Self.fieldHeight / 2, style: .continuous)
                        .strokeBorder(OmniStyle.tint.opacity(0.75), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            .animation(.spring(duration: 0.25), value: omniActive)
            .animation(.spring(duration: 0.25), value: hasContent)
            .animation(.spring(duration: 0.25), value: attachments.map(\.id))

            if Self.showsEmojiButton {
                CircleGlyphButton(systemImage: "face.smiling", size: Self.plusSize, glyph: Self.glyphSize, label: "Emoji", id: "composer-emoji",
                                  secondary: true) {
                    focused = true
                    Self.emojiCircleTapped()
                }
                .disabled(!canSend)
            }
        }
        .background {
            // ⌘⇧O: Omni (as in the + menu), anywhere in the transcript.
            Button("Omni") { toggleOmni() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!omniAvailable)
                .hidden()
                .accessibilityHidden(true)
        }
        .onChange(of: omniThreadID.flatMap { omni?.composerInsert[$0] }) { _, text in
            // Edit on an Omni draft: its text becomes the owner's own message to send.
            guard let text, let id = omniThreadID else { return }
            omni?.composerInsert[id] = nil
            draft = text
            focused = true
        }
        .onChange(of: omniModeOn) { _, on in if on { focused = true } }
        .padding(.horizontal, focused ? Self.focusedSideMargin : Self.sideMargin)
        .padding(.bottom, focused ? Self.focusedLift : 0)
        .animation(.spring(duration: 0.3), value: focused)
        .animation(.spring(duration: 0.25), value: isRecording)
        .photosPicker(isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 10, selectionBehavior: .ordered,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .onChange(of: dropInbox?.generation) {
            guard let dropInbox, canSend, canAttach else { _ = dropInbox?.take(); return }
            importAll(AttachmentDrop.jobs(for: dropInbox.take(), limit: maxAttachmentBytes))
        }
        // The bar itself is a drop target too (the iPad composer sits outside the transcript).
        .composerDropTarget(dropInbox ?? fallbackInbox, enabled: canSend && canAttach && !isRecording)
        #if os(macOS)
        .onChange(of: focused, initial: true) { _, f in paste.isFocused = f && canSend && canAttach }
        .onAppear {
            paste.start { [maxAttachmentBytes] in
                guard let jobs = ComposerPaste.jobs(limit: maxAttachmentBytes), !jobs.isEmpty else { return false }
                importAll(jobs)
                return true
            }
        }
        .onDisappear { paste.stop() }
        #endif
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let limit = maxAttachmentBytes
            importAll(urls.map { url in { try await AttachmentImport.make(fileURL: url, limit: limit) } })
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { capture in
                showsCamera = false
                let limit = maxAttachmentBytes
                switch capture {
                case .photo(let data)?:
                    importAll([{ try AttachmentImport.make(data: data, type: .jpeg, filename: "Photo.jpg", limit: limit) }])
                case .movie(let url)?:
                    importAll([{ try await AttachmentImport.make(ownedFile: url, originalName: "Video.\(url.pathExtension)", limit: limit) }])
                case nil:
                    break
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .alert("Can't Attach", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounded mid-recording: stop and keep it (Messages does the same).
            if phase == .background { recorder?.suspend() }
        }
        .onDisappear {
            // Another conversation, sign-out or quit: nothing unsent outlives the composer.
            // (Not while the full-screen camera merely covers it.)
            guard !showsCamera else { return }
            recorder?.discard()
            for a in attachments { a.deleteFile() }
        }
    }

    // MARK: Pieces

    /// Messages 26's "+": the app menu (Camera, Photos, Audio, Files where available).
    private var plusMenu: some View {
        Menu {
            Group {
                #if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showsCamera = true } label: { Label("Camera", systemImage: "camera") }
                }
                #endif
                Button { showsPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                Button { startRecording() } label: { Label("Audio", systemImage: "waveform") }
                Button { showsFiles = true } label: { Label("Files", systemImage: "folder") }
            }
            // Email takes text only; with Omni the menu still opens (for its Omni row).
            .disabled(!canSend || !canAttach)
            if omniAvailable {
                Divider()
                // ⌘⇧O works without the menu (the hidden button in `body`).
                Button { toggleOmni() } label: { Label(omniModeOn ? "Stop Asking Omni" : "Omni", systemImage: OmniStyle.sparkle) }
                    .accessibilityIdentifier("composer-omni")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.glyphSize + 2, weight: .medium))
                .foregroundStyle((canSend && canAttach) || omniAvailable ? .primary : .tertiary)
                .frame(width: Self.plusSize, height: Self.plusSize)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!(canSend && canAttach) && !omniAvailable)
        .accessibilityLabel("Add")
        .accessibilityHint(canSend ? (omniAvailable ? "Camera, photos, audio, files and Omni" : "Camera, photos, audio and files") : "Sending isn't available in this conversation")
        .accessibilityIdentifier("composer-plus")
    }

    private var textField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if omniBlocked {
                Label("Omni isn't available — this won't be sent", systemImage: "exclamationmark.circle")
                    .font(.system(size: Self.fontSize - 4, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .accessibilityIdentifier("composer-omni-unavailable")
            }
            if !attachments.isEmpty {
                ComposerAttachmentStrip(attachments: attachments, height: Self.previewHeight) { id in
                    attachments.first { $0.id == id }?.deleteFile()
                    attachments.removeAll { $0.id == id }
                }
                .padding(.top, (Self.fieldHeight - Self.sendSize.height) / 2 + 2)
                .padding(.trailing, Self.textInset)
                .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 4) {
                if omniModeOn {
                    Button { toggleOmni() } label: {
                        Label("Omni", systemImage: OmniStyle.sparkle)
                            .font(.system(size: Self.fontSize - 2, weight: .semibold))
                            .foregroundStyle(OmniStyle.tint)
                            .frame(height: Self.fieldHeight)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Omni")
                    .accessibilityHint("Stops asking Omni; the field writes messages again")
                    .accessibilityIdentifier("composer-omni-token")
                }
                field
                if omniActive, hasContent {
                    Button(action: submit) {
                        Image(systemName: OmniStyle.sparkle)
                            .font(.system(size: Self.glyphSize - 2, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: Self.sendSize.width, height: Self.sendSize.height)
                            .background(OmniStyle.tint, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, (Self.fieldHeight - Self.sendSize.height) / 2)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityLabel("Ask Omni")
                    .accessibilityHint("Goes to Omni privately, not to the conversation")
                    .accessibilityIdentifier("composer-omni-send")
                } else if canSend, canAttach, !hasContent, !omniActive {
                    // Messages' waveform in the empty field: records an audio message.
                    Button { startRecording() } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: Self.glyphSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: Self.fieldHeight)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Record audio")
                    .accessibilityIdentifier("composer-record")
                }
                if hasContent, !omniActive, !omniBlocked {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: Self.glyphSize - 2, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: Self.sendSize.width, height: Self.sendSize.height)
                            .background(sendBlue, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, (Self.fieldHeight - Self.sendSize.height) / 2)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("composer-send")
                }
            }
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, hasContent ? (Self.fieldHeight - Self.sendSize.height) / 2 : Self.textInset - 4) // owner's device: waveform ends at x 362
    }

    private var placeholderText: String {
        // The merged conversation's picker stands in for the placeholder.
        if showsChannelPicker { return "" }
        return canSend ? (placeholderOverride ?? Self.placeholder(for: network)) : Self.disabledPlaceholder(for: network, encrypted: encrypted)
    }

    /// Messages' merged-conversation placeholder: "WhatsApp ⌄", a menu of the person's channels.
    /// Stays usable when the picked channel can't send (so the owner can switch back).
    private var channelPicker: some View {
        Menu {
            ForEach(Array(channelChoices.enumerated()), id: \.offset) { _, c in
                Button {
                    onPickChannel(c)
                } label: {
                    if Self.same(c, selectedChannel) {
                        Label(Self.channelName(c), systemImage: "checkmark")
                    } else {
                        Text(Self.channelName(c))
                    }
                }
                .accessibilityIdentifier("channel-choice-\(c.network.wire)")
            }
        } label: {
            HStack(spacing: 3) {
                Text(canSend ? Self.channelName(selectedChannel) : Self.disabledPlaceholder(for: selectedChannel?.network, encrypted: encrypted))
                    .font(.system(size: Self.fontSize))
                Image(systemName: "chevron.down")
                    .font(.system(size: Self.fontSize * 0.6, weight: .semibold))
            }
            .foregroundStyle(.tertiary)
            .frame(height: Self.fieldHeight)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Send with \(Self.channelName(selectedChannel))")
        .accessibilityHint("Chooses the network for this conversation")
        .accessibilityIdentifier("composer-channel")
    }

    static func channelName(_ c: CommsChannelRef?) -> String {
        let name = placeholder(for: c?.network)
        guard let label = c?.accountLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return name }
        return "\(name) (\(label))"
    }

    static func same(_ a: CommsChannelRef, _ b: CommsChannelRef?) -> Bool {
        guard let b else { return false }
        return a.network == b.network && a.accountLabel == b.accountLabel
    }

    private var field: some View {
        TextField(omniModeOn ? "Ask Omni…" : placeholderText, text: $draft, axis: .vertical)
            .font(.system(size: Self.fontSize))
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($focused)
            .disabled(!fieldEnabled)
            .padding(.vertical, (Self.fieldHeight - Self.lineHeight) / 2)
            #if os(macOS)
            // Messages on the Mac: Return sends, Option-Return (or Shift-Return) is a new line.
            // While an input method is composing (Japanese, Chinese, Korean…), Return belongs to
            // it (it confirms the conversion) and never sends.
            .onKeyPress(.return, phases: .down) { press in
                switch Self.returnAction(option: press.modifiers.contains(.option), shift: press.modifiers.contains(.shift),
                                         composing: ComposerKeyboard.isComposing()) {
                case .send:
                    // Omni mode: Return is the ✦ button (the instruction goes to Omni, privately).
                    // Always handled, so the field never gets a stray newline after the submit.
                    if omniActive { submitToOmni() } else { submit() }
                    return .handled
                case .newline, .passThrough:
                    return .ignored
                }
            }
            .onSubmit {
                // Fallback if the key press reached the field: only a real Return key-down, never
                // focus loss, and never while composing.
                guard ComposerKeyboard.currentEventIsReturn() else { return }
                let flags = NSEvent.modifierFlags
                switch Self.returnAction(option: flags.contains(.option), shift: flags.contains(.shift), composing: ComposerKeyboard.isComposing()) {
                case .send: if omniActive { submitToOmni() } else { submit() }
                case .newline: ComposerKeyboard.insertNewlineAtCaret()
                case .passThrough: break
                }
            }
            #endif
            #if os(macOS)
            .onKeyPress(.escape) {
                guard omniModeOn else { return .ignored }
                toggleOmni()
                return .handled
            }
            #endif
            #if os(iOS)
            // Omni mode: the keyboard's return key reads Send and submits the instruction to Omni
            // (a chat message keeps Messages' Return = new line).
            .submitLabel(omniActive ? .send : .return)
            #endif
            .accessibilityHint(omniActive ? "An instruction to Omni, private; it is not sent to the conversation" : canSend ? "" : "Sending isn't available in this conversation yet")
            .accessibilityIdentifier("composer-field")
            .overlay(alignment: .topLeading) {
                if showsChannelPicker { channelPicker }
            }
            .onChange(of: draft) { old, text in
                #if os(iOS)
                // Omni mode: the Send key types one newline into the multi-line field; that newline
                // is the submit (the ✦ button's), not text.
                if omniActive, let instruction = Self.omniSubmitOnReturn(old: old, new: text) {
                    draft = instruction
                    submitToOmni()
                    return
                }
                #endif
                // Picks follow the edit (a touched name stops being a mention); a cleared draft
                // forgets them all.
                if text.isEmpty {
                    mentionPicks = []
                } else if text != trackedDraft {
                    mentionPicks = MentionText.track(mentionPicks, from: trackedDraft, to: text)
                }
                trackedDraft = text
            }
    }

    // MARK: Actions

    enum ReturnAction: Equatable { case send, newline, passThrough }

    /// The Mac emoji circle: the system Character Viewer (Edit ▸ Emoji & Symbols), which types
    /// into the focused field. Replaceable in tests.
    @MainActor static func emojiCircleTapped() { openEmojiPalette() }
    @MainActor static var openEmojiPalette: @MainActor () -> Void = {
        #if os(macOS)
        NSApp.orderFrontCharacterPalette(nil)
        #endif
    }

    /// Mac Messages' Return: sends; Option/Shift-Return: a new line; while an input method has
    /// marked (uncommitted) text: the input method's (confirm the conversion), never a send.
    static func returnAction(option: Bool, shift: Bool, composing: Bool) -> ReturnAction {
        if composing { return .passThrough }
        if option || shift { return .newline }
        return .send
    }

    /// Run each import, attaching what works and saying why the rest can't be attached.
    private func importAll(_ all: [@MainActor () async throws -> OutgoingAttachment]) {
        guard !all.isEmpty else { return }
        // Messages' limit per message: what fits is attached, the rest is refused with a reason.
        let room = max(0, AttachmentImport.maxPerMessage - attachments.count - importing)
        let jobs = Array(all.prefix(room))
        let overflow = jobs.count < all.count ? [AttachmentImport.ImportError.tooMany(limit: AttachmentImport.maxPerMessage).errorDescription!] : []
        guard !jobs.isEmpty else { importError = overflow.first; return }
        importing += jobs.count
        Task {
            var problems = overflow
            for job in jobs {
                do {
                    attachments.append(try await job())
                } catch {
                    let message = (error as? AttachmentImport.ImportError)?.errorDescription ?? AttachmentImport.ImportError.unreadable.errorDescription!
                    if !problems.contains(message) { problems.append(message) }
                }
                importing -= 1
            }
            if !problems.isEmpty { importError = problems.joined(separator: "\n\n") }
            focused = true
        }
    }

    /// A suggestion was chosen: the `@query` becomes the name, bound to exactly that place.
    private func pick(_ member: CommsMember) {
        guard let done = MentionText.completeLocated(draft, with: member.name) else { return }
        mentionPicks = MentionText.track(mentionPicks, from: trackedDraft, to: draft)
        mentionPicks = MentionText.track(mentionPicks, from: draft, to: done.draft)
        mentionPicks.append(ComposerMention(userID: member.id, name: member.name, location: done.location))
        trackedDraft = done.draft
        draft = done.draft
        focused = true
    }

    /// The ✦ button, Return (Mac) and the Send key (iOS) in Omni mode: the instruction goes to
    /// Omni, privately — never to the chat (D9). Nothing at all happens outside Omni mode.
    private func submitToOmni() {
        guard omniActive, let id = omniThreadID, let omni else { return }
        guard hasContent, !isRecording else { return }
        let text = draft
        draft = ""
        trackedDraft = ""
        mentionPicks = []
        Task { await omni.ask(threadID: id, text: text) }
        focused = true
    }

    /// iOS Omni mode: did this edit type exactly one newline (the keyboard's Send key) into the
    /// text? Then the text without it is the instruction to submit; nil for any other edit
    /// (typing, a paste with newlines, deleting). Pure, unit-tested.
    static func omniSubmitOnReturn(old: String, new: String) -> String? {
        guard new.count == old.count + 1 else { return nil }
        let o = Array(old), n = Array(new)
        var i = 0
        while i < o.count, o[i] == n[i] { i += 1 }
        guard n[i] == "\n" else { return nil }
        guard Array(n[(i + 1)...]) == Array(o[i...]) else { return nil }
        return old
    }

    private func submit() {
        if omniActive {
            submitToOmni()
            return
        }
        // `@Omni …` never falls through to the chat (review I2).
        guard canSend, hasContent, !isRecording, !omniBlocked, !OmniStore.addressesOmni(draft) else { return }
        let text = draft
        let files = attachments
        let picks = mentionPicks
        draft = ""
        attachments = []
        mentionPicks = []
        trackedDraft = ""
        onSend(text, files, picks)
        focused = true
    }

    private func startRecording() {
        guard canSend else { return }
        // A new recorder when the outgoing channel's voice format changed (a merged conversation).
        let format = VoiceNoteFormat.for(network)
        let r = recorder.flatMap { $0.format == format ? $0 : nil } ?? VoiceRecorder(source: simulatedRecorder ? .simulated : .microphone, format: format)
        recorder = r
        focused = false
        Task { await r.start() }
    }

    /// Photos hands each item over as a file (never loaded into memory here); it is then
    /// size-checked and location-stripped like any other pick.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        let limit = maxAttachmentBytes
        importAll(items.map { item in {
            guard let picked = try await item.loadTransferable(type: PickedFile.self) else { throw AttachmentImport.ImportError.unreadable }
            let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            return try await AttachmentImport.make(ownedFile: picked.url, originalName: (isMovie ? "Video." : "Photo.") + picked.url.pathExtension, limit: limit)
        } })
    }
}

/// A glass circle with one glyph (the composer's "+"-sized buttons).
struct CircleGlyphButton: View {
    let systemImage: String
    let size: CGFloat
    let glyph: CGFloat
    let label: String
    let id: String
    var secondary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyph + 2, weight: .medium))
                .foregroundStyle(secondary ? .secondary : .primary)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

#if os(macOS)
/// ⌘V while the composer has focus: attaches copied files / images (`ComposerPaste`) before the
/// field editor pastes them as text (a Finder copy would otherwise paste the file's NAME). A
/// local event monitor, because ⌘V is a key equivalent the text view consumes.
@MainActor
final class ComposerPasteMonitor {
    var isFocused = false
    private var monitor: Any?

    /// `handle` answers whether it took the paste.
    func start(_ handle: @escaping @MainActor () -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isFocused, event.window?.isKeyWindow == true,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  event.window?.firstResponder is NSTextView else { return event }
            return handle() ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The Mac field editor, for Return handling.
enum ComposerKeyboard {
    /// An input method has marked (uncommitted) text in the focused text view.
    @MainActor static func isComposing() -> Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    /// The event being handled is a Return / Enter key-down (not focus loss, Tab, a click).
    @MainActor static func currentEventIsReturn() -> Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown else { return false }
        return e.keyCode == 36 || e.keyCode == 76
    }

    /// A line break at the caret (not at the end of the draft).
    @MainActor static func insertNewlineAtCaret() {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
    }
}
#endif
