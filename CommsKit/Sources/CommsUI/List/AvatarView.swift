import CommsClient
import CommsCore
import CoreGraphics
import Foundation
import ImageIO
import os
import SwiftUI

// MARK: Loading

/// Fetches avatar bytes for a media token with the session's credential (never a plain URL
/// load: the server refuses unauthenticated media requests).
public struct AvatarLoader: Sendable {
    public let fetch: @Sendable (String) async throws -> Data
    public init(fetch: @escaping @Sendable (String) async throws -> Data) { self.fetch = fetch }
}

extension EnvironmentValues {
    /// nil (previews, snapshots): token avatars show only what `AvatarCache` already holds.
    @Entry public var avatarLoader: AvatarLoader? = nil
}

/// Decoded avatars in memory, keyed by media token, with one fetch in flight per token.
public final class AvatarCache: @unchecked Sendable {
    public static let shared = AvatarCache()

    private let cache = NSCache<NSString, CGImage>()
    private let inflight = OSAllocatedUnfairLock(initialState: [String: Task<CGImage?, Never>]())
    /// Tokens whose fetch failed permanently (404, 410, not an image) and when: not fetched
    /// again until `retryAfter` has passed, the app returns to the foreground or a Retry
    /// succeeds (`forgetFailures()`), or the app relaunches (memory only). Most bridged
    /// avatars 404 at the homeserver, so without this every scroll would refetch them.
    /// Transient failures (offline, timeouts, 5xx) are not remembered.
    private let failures = OSAllocatedUnfairLock(initialState: [String: Date]())
    /// How long a failed token is left alone.
    public static let retryAfter: TimeInterval = 10 * 60

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    private static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    public func image(for token: String) -> CGImage? { cache.object(forKey: token as NSString) }

    /// The token failed within `retryAfter` of `now`.
    public func hasRecentFailure(_ token: String, now: Date = Date()) -> Bool {
        failures.withLock { f in
            guard let at = f[token] else { return false }
            if now.timeIntervalSince(at) < Self.retryAfter { return true }
            f[token] = nil
            return false
        }
    }

    func recordFailure(_ token: String, at date: Date = Date()) { failures.withLock { $0[token] = date } }

    /// Forget remembered failures (foreground reconnect, a successful Retry).
    public func forgetFailures() { failures.withLock { $0.removeAll() } }
    /// Tests: empty the cache (a hosted real-window test must not leak avatars into snapshots).
    func removeAllForTests() {
        cache.removeAllObjects()
        forgetFailures()
    }
    public func insert(_ image: CGImage, for token: String) { cache.setObject(image, forKey: token as NSString, cost: Self.cost(image)) }

    /// The cached image, or fetch + decode (downsampled to `maxPixels`) and cache it. nil on failure.
    func load(_ token: String, with loader: AvatarLoader, maxPixels: Int = 240) async -> CGImage? {
        if let hit = image(for: token) { return hit }
        if hasRecentFailure(token) { return nil }
        let task = inflight.withLock { running -> Task<CGImage?, Never> in
            if let t = running[token] { return t }
            let t = Task<CGImage?, Never> { [cache, weak self] in
                let data: Data
                do { data = try await loader.fetch(token) } catch {
                    if !Task.isCancelled, MediaFailure.isPermanent(error) { self?.recordFailure(token) }
                    return nil
                }
                guard let img = Self.decode(data, maxPixels: maxPixels) else {
                    self?.recordFailure(token)
                    return nil
                }
                cache.setObject(img, forKey: token as NSString, cost: Self.cost(img))
                return img
            }
            running[token] = t
            return t
        }
        let result = await task.value
        inflight.withLock { _ = $0.removeValue(forKey: token) }
        return result
    }

    static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

// MARK: Avatar

/// A conversation avatar (D16: every conversation has one): the server's photo, a member
/// cluster for groups without a photo, a monogram, or a silhouette; with an optional network
/// badge at the bottom-right.
public struct AvatarView: View {
    let avatar: CommsAvatar?
    let kind: CommsThreadKind
    let size: CGFloat
    let badge: CommsNetwork?
    let badgeRing: Color?
    /// Whose avatar this is: the monogram shown while a photo loads, or instead of one that
    /// cannot be fetched (most bridged avatars 404 at the homeserver).
    let name: String?

    /// - Parameter badgeRing: the colour around the badge (defaults to the sidebar's).
    public init(_ avatar: CommsAvatar?, kind: CommsThreadKind = .dm, size: CGFloat, badge: CommsNetwork? = nil, badgeRing: Color? = nil, name: String? = nil) {
        self.avatar = avatar
        self.name = name
        self.kind = kind
        self.size = size
        self.badge = badge
        self.badgeRing = badgeRing
    }

    public var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    // ≈ 14 pt on a 40 pt row avatar, a little smaller relative to larger avatars.
                    let d = (size * (size > 48 ? 0.3 : 0.35)).rounded()
                    NetworkBadge(network: badge, size: d, ring: badgeRing)
                        .offset(x: d * 0.18, y: d * 0.12)
                }
            }
    }

    @ViewBuilder private var face: some View {
        switch avatar {
        case .monogram(_, let members) where !members.isEmpty:
            MemberCluster(members: Array(members.prefix(3)), size: size)
        default:
            MemberFace(avatar: avatar, kind: kind, size: size, name: name)
        }
    }
}

/// One circular face: photo, monogram or silhouette (no clusters, so it can nest in one).
struct MemberFace: View {
    let avatar: CommsAvatar?
    let kind: CommsThreadKind
    let size: CGFloat
    var name: String? = nil

    var body: some View {
        switch avatar {
        case .token(let token):
            TokenImage(token: token, kind: kind, size: size, name: name)
        case .monogram(let text, _) where !text.isEmpty:
            Monogram(text: text, size: size)
        default:
            Silhouette(kind: kind, size: size)
        }
    }
}

/// A photo avatar. Until (or unless) the photo arrives it shows the monogram for `name`
/// (the silhouette when there is no name with letters), never an empty circle; a token that
/// failed is not fetched again for `AvatarCache.retryAfter`.
private struct TokenImage: View {
    let token: String
    let kind: CommsThreadKind
    let size: CGFloat
    let name: String?
    @Environment(\.avatarLoader) private var loader
    @State private var image: CGImage?

    init(token: String, kind: CommsThreadKind, size: CGFloat, name: String?) {
        self.token = token
        self.kind = kind
        self.size = size
        self.name = name
        _image = State(initialValue: AvatarCache.shared.image(for: token))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                AvatarFallback(kind: kind, size: size, name: name)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: token) {
            image = AvatarCache.shared.image(for: token)
            guard image == nil, let loader else { return }
            if let loaded = await AvatarCache.shared.load(token, with: loader) { image = loaded }
        }
    }
}

/// What stands in for a missing photo: the monogram of `name` for a person, else the
/// silhouette (groups, and names without letters such as phone numbers).
struct AvatarFallback: View {
    let kind: CommsThreadKind
    let size: CGFloat
    let name: String?

    var body: some View {
        if kind != .group, let initials = Self.initials(name) {
            Monogram(text: initials, size: size)
                .accessibilityIdentifier("avatar-monogram")
        } else {
            Silhouette(kind: kind, size: size)
                .accessibilityIdentifier("avatar-silhouette")
        }
    }

    /// Apple's initials: the first letter of the first and last words ("Alice Example" →
    /// "AE", "bob" → "B"); nil when the name has no letters.
    static func initials(_ name: String?) -> String? {
        guard let name else { return nil }
        let words = name.split(whereSeparator: { $0.isWhitespace }).compactMap { w in w.first(where: \.isLetter) }
        guard let first = words.first else { return nil }
        let last = words.count > 1 ? String(words.last!) : ""
        return (String(first) + last).uppercased()
    }
}

/// Apple's contact-monogram gradient. iOS 27: the blue-violet gradient sampled from the real
/// app's monogram avatars (design/fidelity/apple-ios/list-*.png); Mac keeps the classic gray
/// until a real macOS 27 capture is allowed.
private struct MonogramFill: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        #if os(iOS)
        let c = Tokens.color
        let top = (scheme == .dark ? c.monogramTopDark : c.monogramTopLight).color
        let bottom = (scheme == .dark ? c.monogramBottomDark : c.monogramBottomLight).color
        #else
        let top = scheme == .dark ? Color(white: 0.45) : Color(red: 0.66, green: 0.68, blue: 0.73)
        let bottom = scheme == .dark ? Color(white: 0.33) : Color(red: 0.53, green: 0.55, blue: 0.60)
        #endif
        Circle().fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
    }
}

private struct Monogram: View {
    let text: String
    let size: CGFloat
    var body: some View {
        MonogramFill()
            .overlay {
                Text(text.prefix(2).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(size * 0.1)
            }
            .frame(width: size, height: size)
    }
}

/// No photo and no monogram: a person (or people) silhouette on the monogram gradient.
private struct Silhouette: View {
    let kind: CommsThreadKind
    let size: CGFloat
    var body: some View {
        MonogramFill()
            .overlay {
                Image(systemName: kind == .group ? "person.2.fill" : "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: size * (kind == .group ? 0.62 : 0.5))
                    .offset(y: size * 0.04)
            }
            .frame(width: size, height: size)
    }
}

/// A group without a photo: up to three member faces inside a light circle, Messages-style
/// (one large, the others small and overlapping with a cut-out ring).
private struct MemberCluster: View {
    let members: [CommsAvatar]
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let plate = scheme == .dark ? Color(white: 0.27) : Color(red: 0.89, green: 0.89, blue: 0.91)
        ZStack {
            Circle().fill(plate)
            ForEach(Array(layout.enumerated()), id: \.offset) { i, slot in
                MemberFace(avatar: members[i], kind: .dm, size: size * slot.scale)
                    .padding(slot.ring ? size * 0.025 : 0)
                    .background(Circle().fill(plate))
                    .offset(x: size * slot.x, y: size * slot.y)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Diameter (fraction of `size`) and centre offset for each member, drawn back to front.
    private var layout: [(scale: CGFloat, x: CGFloat, y: CGFloat, ring: Bool)] {
        switch members.count {
        case 1: [(0.62, 0, 0, false)]
        // Messages puts the small face bottom-right; mirrored so the network badge never hides it.
        case 2: [(0.58, 0.09, -0.08, false), (0.38, -0.2, 0.2, true)]
        default: [(0.5, 0.12, 0.02, false), (0.3, -0.24, -0.2, true), (0.27, -0.2, 0.25, true)]
        }
    }
}

// MARK: Network badge

/// A small network mark at the avatar's bottom-right: the network's brand mark (Simple
/// Icons vector path, `NetworkMarks.swift`) in white on its brand-colour circle, with a crisp
/// ring of the background around it, like Apple's status badges. (Owner, Phase B: accurate
/// brand marks in brand colours on the badges; the outgoing bubble blues stay per D4.)
struct NetworkBadge: View {
    let network: CommsNetwork
    let size: CGFloat
    let ring: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        mark
            .frame(width: size, height: size)
            .padding(Self.ringWidth(for: size))
            .background(Circle().fill(ring ?? ListMetrics.sidebarFill(scheme)))
            .accessibilityLabel(network.title)
    }

    /// 1.5 pt at small badges, 2 pt from 16 pt up.
    static func ringWidth(for size: CGFloat) -> CGFloat { size >= 16 ? 2 : 1.5 }

    @ViewBuilder private var mark: some View {
        let brand = NetworkMark.color(for: network)
        switch NetworkMark.mark(for: network) {
        case .glyph(let path, let scale):
            Circle().fill(brand)
                .overlay {
                    SVGPathShape(path: path)
                        .fill(.white, style: FillStyle(eoFill: true, antialiased: true))
                        .frame(width: size * scale, height: size * scale)
                }
        case .knockout(let path):
            Circle().fill(.white)
                .padding(size * 0.08)
                .overlay { SVGPathShape(path: path).fill(brand, style: FillStyle(eoFill: true, antialiased: true)) }
        case .multicolor(let layers, let scale):
            Circle().fill(.white)
                .overlay {
                    // A hairline so the white disc keeps its edge on light backgrounds.
                    if scheme == .light { Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5) }
                }
                .overlay {
                    ZStack {
                        ForEach(layers.indices, id: \.self) { i in
                            SVGPathShape(path: layers[i].0).fill(layers[i].1, style: FillStyle(eoFill: false, antialiased: true))
                        }
                    }
                    .frame(width: size * scale, height: size * scale)
                }
        case .symbol(let name):
            Circle().fill(brand)
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}

extension CommsNetwork {
    /// Display name (menus, accessibility).
    var title: String {
        switch self {
        case .imessage: "iMessage"
        case .sms: "SMS"
        case .whatsapp: "WhatsApp"
        case .telegram: "Telegram"
        case .messenger: "Messenger"
        case .x: "X"
        case .discord: "Discord"
        case .email: "Email"
        case .matrix: "Matrix"
        case .instagram: "Instagram"
        case .linkedin: "LinkedIn"
        case .unknown: displayName
        }
    }

    var symbol: String {
        switch self {
        case .imessage: "message.fill"
        case .sms: "ellipsis.message.fill"
        case .whatsapp: "phone.fill"
        case .telegram: "paperplane.fill"
        case .messenger: "bolt.fill"
        case .x: "xmark"
        case .discord: "gamecontroller.fill"
        case .email: "envelope.fill"
        case .signal: "lock.fill"
        case .slack: "number.square.fill"
        case .instagram: "camera.fill"
        case .linkedin: "briefcase.fill"
        case .matrix, .unknown: "number"
        }
    }
}
