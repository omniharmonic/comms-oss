import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Which sender-controlled links Comms will open. The server already allowlists link schemes
/// in rich text; this is defence in depth so one server regression cannot make a `file:`,
/// `smb:` or custom-scheme link launch something with one click.
/// - Link preview cards open http/https only.
/// - Links inside message text may be http, https or mailto; anything else renders as plain
///   text, and the transcript's `OpenURLAction` refuses it anyway.
public enum SafeLinks {
    static let webSchemes: Set<String> = ["http", "https"]
    static let textSchemes: Set<String> = ["http", "https", "mailto"]

    /// A link preview's URL when it is an http(s) URL with a host.
    public static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme),
              url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// A rich-text link's URL when its scheme is http, https or mailto.
    public static func textURL(_ href: String) -> URL? {
        guard let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return allowsTextLink(url) ? url : nil
    }

    public static func allowsTextLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), textSchemes.contains(scheme) else { return false }
        return scheme == "mailto" || url.host()?.isEmpty == false
    }

    /// Opens URLs with the system (NSWorkspace on the Mac, UIApplication on iOS). Swappable so
    /// tests can observe opens.
    @MainActor public static var opener: (URL) -> Void = { url in
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Ranges of web addresses and email addresses written as plain text (as Messages detects
    /// them), each with the URL it opens. Only URLs `allowsTextLink` accepts are returned.
    public static func detectedLinks(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard text.contains(where: { $0 == "." || $0 == "@" || $0 == ":" }),
              let detector = linkDetector else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: ns).compactMap { match in
            guard let url = match.url, allowsTextLink(url),
                  let range = Range(match.range, in: text) else { return nil }
            return (range, url)
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Opens a link preview's URL if it is http(s); returns whether it opened.
    @MainActor @discardableResult
    public static func openPreview(_ string: String) -> Bool {
        guard let url = webURL(string) else { return false }
        opener(url)
        return true
    }

    /// The transcript's link handler: allowed text links go to the system, the rest are dropped.
    @MainActor public static let openURLAction = OpenURLAction { url in
        guard allowsTextLink(url) else { return .discarded }
        opener(url)
        return .handled
    }
}
