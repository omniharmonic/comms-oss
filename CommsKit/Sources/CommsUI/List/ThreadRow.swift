import CommsClient
import Foundation
import SwiftUI

/// One conversation row in the Mac sidebar (UX spec §3 row anatomy, §9 sizes): unread dot in
/// the leading gutter, 40 pt avatar with network badge, bold name, time, two-line preview.
/// Selected = filled accent-blue rounded rect with white text.
public struct ThreadRow: View {
    let thread: CommsThread
    let isSelected: Bool
    let now: Date
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(thread: CommsThread, isSelected: Bool, now: Date = .now) {
        self.thread = thread
        self.isSelected = isSelected
        self.now = now
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ZStack {
                if thread.unread.count > 0 {
                    Circle()
                        .fill(isSelected ? Color.white : ListMetrics.accent)
                        .frame(width: ListMetrics.unreadDot, height: ListMetrics.unreadDot)
                }
            }
            .frame(width: ListMetrics.gutter)

            AvatarView(thread.avatar, kind: thread.kind, size: ListMetrics.avatar, badge: thread.networks.first,
                       badgeRing: isSelected ? .white : nil, name: thread.title)
                .padding(.trailing, ListMetrics.avatarToText)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(thread.title)
                        .font(.system(size: ListMetrics.nameSize, weight: ListMetrics.nameWeight))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let forum = thread.forum {
                        // A Telegram forum: how many topics it holds (Telegram's "#" for a topic).
                        Self.topicCount(forum.topicCount)
                            .font(.system(size: ListMetrics.timeSize - 2, weight: .medium))
                            .foregroundStyle(secondary)
                            .fixedSize()
                    }
                    if thread.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: ListMetrics.timeSize - 2))
                            .foregroundStyle(secondary)
                    }
                    Spacer(minLength: 6)
                    Text(time)
                        .font(.system(size: ListMetrics.timeSize))
                        .foregroundStyle(secondary)
                        .fixedSize()
                    if ListMetrics.showsChevron {
                        // Messages' disclosure chevron: 30 % label colour, 10 pt after the time.
                        Image(systemName: "chevron.forward")
                            .font(.system(size: ListMetrics.chevronSize, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, ListMetrics.chevronGap - 4)
                            .accessibilityHidden(true)
                    }
                }
                Self.preview(thread.lastMessage, primary: Color.primary)
                    .font(.system(size: ListMetrics.previewSize))
                    .lineSpacing(ListMetrics.previewLineSpacing)
                    .foregroundStyle(secondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, ListMetrics.nameTop ?? 0)
            .frame(maxHeight: .infinity, alignment: ListMetrics.nameTop == nil ? .center : .top)
        }
        .padding(.trailing, ListMetrics.rowTrailing)
        .frame(height: ListMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: ListMetrics.selectionRadius, style: .continuous).fill(ListMetrics.accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "# 21": a forum's topic count, small, after the title.
    static func topicCount(_ n: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "number")
                .imageScale(.small)
            Text(verbatim: "\(n)")
                .monospacedDigit()
        }
        .accessibilityIdentifier("forum-topic-count")
    }

    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.white.opacity(0.82)) : AnyShapeStyle(.secondary)
    }

    private var time: String {
        var cal = calendar
        cal.timeZone = timeZone
        return ThreadTimestamp(calendar: cal, locale: locale).string(for: thread.lastActivityAt, now: now)
    }

    private var accessibilityText: String { Self.accessibilityLabel(for: thread, time: time) }

    /// The two preview lines. Email (PRD §5.8): the subject in semibold label colour on the first
    /// line, the snippet after it (as Mail lists a message); every other network: the text.
    static func preview(_ p: CommsMessagePreview?, primary: Color) -> Text {
        guard let p else { return Text("") }
        guard let subject = p.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty else { return Text(p.text) }
        var s = AttributedString(subject)
        s.font = .system(size: ListMetrics.previewSize, weight: .semibold)
        s.foregroundColor = primary
        var out = s
        if !p.text.isEmpty { out += AttributedString("\n" + p.text) }
        return Text(out)
    }

    /// The row's VoiceOver label (the badge and dot are drawn, not read): title, networks,
    /// unread count, muted, then time and preview (time and preview omitted when nil).
    static func accessibilityLabel(for thread: CommsThread, time: String?) -> String {
        var parts = [thread.title]
        if !thread.networks.isEmpty { parts.append(thread.networks.map(\.title).joined(separator: " and ")) }
        switch thread.unread.count {
        case 0: break
        case 1: parts.append("1 unread message")
        case let n: parts.append("\(n) unread messages")
        }
        if let forum = thread.forum { parts.append(forum.topicCount == 1 ? "forum, 1 topic" : "forum, \(forum.topicCount) topics") }
        if thread.muted { parts.append("muted") }
        if let time { parts.append(time) }
        if let subject = thread.lastMessage?.subject, !subject.isEmpty, time != nil { parts.append(subject) }
        if let text = thread.lastMessage?.text, !text.isEmpty, time != nil { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}

/// Messages' list timestamps: time today, "Yesterday", the weekday within the last week, else
/// the short numeric date.
public struct ThreadTimestamp {
    let calendar: Calendar
    let locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    public func string(for date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ...0:
            f.dateStyle = .none
            f.timeStyle = .short
        case 1:
            return String(localized: "Yesterday", locale: locale)
        case 2...6:
            f.setLocalizedDateFormatFromTemplate("EEEE")
        default:
            f.dateStyle = .short
            f.timeStyle = .none
        }
        return f.string(from: date)
    }
}
