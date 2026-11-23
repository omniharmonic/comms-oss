import CommsCore
import PrismAuth
import SwiftUI
import UserNotifications

/// Sign-in window until the session is ready, then `ready(session)` (the app's main window;
/// by default a placeholder split view).
public struct RootView: View {
    private let makeSession: @MainActor (ServerOrigin) -> Session
    private let ready: (@MainActor (Session) -> AnyView)?
    private let defaultOrigin: String
    @State private var originText: String
    @State private var session: Session?
    @State private var originError: String?

    public init(
        defaultOrigin: String = "https://prism.example.com",
        makeSession: @escaping @MainActor (ServerOrigin) -> Session,
        ready: (@MainActor (Session) -> AnyView)? = nil
    ) {
        self.defaultOrigin = defaultOrigin
        self.makeSession = makeSession
        self.ready = ready
        _originText = State(initialValue: Self.savedOrigin() ?? defaultOrigin)
    }

    public var body: some View {
        Group {
            if let session, session.state == .ready {
                if let ready { ready(session) } else { ReadyView(session: session) }
            } else if let session, session.isOffline {
                // A saved sign-in the server could not confirm: Retry, never a new sign-in.
                OfflineView(session: session, signOut: { signOut(session) })
            } else {
                SignInView(originText: $originText, state: session?.state ?? .signedOut, originError: originError, signIn: signIn)
            }
        }
        .task { await restoreSaved() }
        // Back online (a successful Retry or restore): avatars that failed may load now.
        .onChange(of: session?.state == .ready) { _, ready in if ready { AvatarCache.shared.forgetFailures() } }
        #if os(macOS)
        // The sign-in and offline windows match the main window's chrome: no "Comms" title.
        .toolbar(removing: .title)
        #endif
    }

    private func restoreSaved() async {
        guard session == nil, let saved = Self.savedOrigin(), let origin = try? ServerOrigin(saved) else { return }
        let s = makeSession(origin)
        session = s
        await s.restore()
    }

    private func signIn() {
        originError = nil
        guard let origin = try? ServerOrigin(originText) else {
            originError = "Enter a valid server address, like https://prism.example.com."
            return
        }
        let s = (session?.origin == origin ? session : nil) ?? makeSession(origin)
        session = s
        Task {
            await s.signIn()
            // Remember the server as soon as a token exists (also when the first check ends
            // offline), so the next launch restores it instead of minting another device.
            if s.shouldRememberOrigin { Self.saveOrigin(origin.value) }
        }
    }

    /// Sign out (or change server): revoke when reachable, forget the token and the saved
    /// origin, back to the sign-in screen with the server field editable.
    private func signOut(_ s: Session) {
        Task {
            await s.signOut()
            try? await UNUserNotificationCenter.current().setBadgeCount(0) // no badge for a signed-out app (M4)
            UserDefaults.standard.removeObject(forKey: Self.originKey)
            session = nil
        }
    }

    private static let originKey = "comms.serverOrigin"
    private static func savedOrigin() -> String? { UserDefaults.standard.string(forKey: originKey) }
    private static func saveOrigin(_ value: String) { UserDefaults.standard.set(value, forKey: originKey) }
}

struct SignInView: View {
    @Binding var originText: String
    let state: Session.State
    let originError: String?
    let signIn: () -> Void

    private var busy: Bool { state == .signingIn || state == .verifying }

    #if os(iOS)
    @FocusState private var fieldFocused: Bool

    // A native iOS onboarding screen: the app mark and a welcome title centred in the upper
    // half, the server in an inset-grouped field, and a full-width prominent button at the
    // bottom (as Apple's own first-run screens).
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    AppMark()
                        .padding(.top, 72)
                    Text("Welcome to Comms")
                        .font(.system(size: 34, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 28)
                    Text("All your conversations — iMessage, WhatsApp, Telegram and more — from your Prism server.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SERVER")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                        TextField("https://prism.example.com", text: $originText)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($fieldFocused)
                            .onSubmit(signIn)
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
                            .accessibilityLabel("Server")
                            .accessibilityIdentifier("sign-in-server")
                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(isError ? Color.red : .secondary)
                                .padding(.horizontal, 16)
                                .accessibilityIdentifier("sign-in-message")
                        }
                    }
                    .padding(.top, 40)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 14) {
                Button {
                    fieldFocused = false
                    signIn()
                } label: {
                    ZStack {
                        Text("Sign In").opacity(busy ? 0 : 1)
                        if busy { ProgressView().tint(.white) }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.glassProminent)
                .disabled(busy || originText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("sign-in-button")
                Text("You'll sign in with your Prism account in a secure browser sheet. Comms only reads your messages; it never sends.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: 480)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private var isError: Bool {
        if originError != nil { return true }
        if case .failed = state { return true }
        return false
    }
    #else
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Comms").font(.largeTitle.weight(.semibold))
            TextField("Server", text: $originText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(maxWidth: 320)
                .onSubmit(signIn)
            Button(action: signIn) {
                if busy { ProgressView().controlSize(.small) } else { Text("Sign In") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 360)
    }

    #endif

    private var message: String? {
        if let originError { return originError }
        switch state {
        #if os(iOS)
        case .signingIn: return "Finish signing in in the sheet."
        #else
        case .signingIn: return "Finish signing in in your browser."
        #endif
        case .verifying: return "Checking the server…"
        case .failed(let m): return m
        default: return nil
        }
    }
}

/// "Offline — Retry": the saved sign-in is kept; Retry (and automatic retries every 5 s,
/// doubling to 60 s) verifies it again. Only a rejected token leads back to sign-in.
struct OfflineView: View {
    let session: Session
    var signOut: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase

    static func delay(attempt: Int) -> Duration { .seconds(min(60, 5 << min(attempt, 4))) }

    private var message: String {
        if case .offline(let m) = session.state { return m }
        return ""
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Offline").font(.title2.weight(.semibold))
            Text("\(message) Your sign-in is kept; Comms will try again.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button {
                Task { await session.retry() }
            } label: {
                if session.isRetrying { ProgressView().controlSize(.small) } else { Text("Retry") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(session.isRetrying)
            #if os(iOS)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("offline-retry")
            #endif
            HStack(spacing: 20) {
                Button("Change Server", action: signOut)
                    .accessibilityHint("Signs out of \(session.origin.value) so you can enter another server")
                Button("Sign Out", role: .destructive, action: signOut)
            }
            .font(.callout)
            .padding(.top, 6)
        }
        .padding(32)
        // Back in the foreground: try at once instead of waiting out the backoff.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, session.isOffline { Task { await session.retry() } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .task {
            var attempt = 0
            while !Task.isCancelled, session.isOffline {
                do { try await Task.sleep(for: Self.delay(attempt: attempt)) } catch { return }
                attempt += 1
                await session.retry()
            }
        }
    }
}

/// The app's mark: a white message glyph on the accent gradient, in the app-icon shape.
struct AppMark: View {
    var body: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(
                LinearGradient(colors: [Color(red: 0.33, green: 0.72, blue: 1), Color(red: 0.0, green: 0.48, blue: 1)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 22, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ReadyView: View {
    let session: Session

    var body: some View {
        NavigationSplitView {
            List {}
                .navigationTitle("Comms")
        } detail: {
            ContentUnavailableView("No Conversation Selected", systemImage: "message")
        }
    }
}
