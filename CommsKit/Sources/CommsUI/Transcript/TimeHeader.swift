import SwiftUI

/// The words of a centred time header (UX spec §5): the day word semibold, the time regular.
/// "**Today** 8:17 AM", "**Yesterday** 5:55 PM", "**Thursday** 8:24 PM" (the last week),
/// "**Fri, Jun 13** at 3:30 PM" (this year), "**Jun 13, 2025** at 3:30 PM" (older).
public struct TimeHeaderText: Equatable, Sendable {
    public var day: String
    /// The rest, including its leading separator (" 8:17 AM" or " at 3:30 PM").
    public var time: String

    public var plain: String { day + time }

    public init(day: String, time: String) {
        self.day = day
        self.time = time
    }

    public init(_ date: Date, now: Date = .now, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        time.timeZone = calendar.timeZone
        let clock = date.formatted(time)
        let startToday = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startDay, to: startToday).day ?? 0

        func style(_ template: String) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }

        if days == 0 {
            self.init(day: "Today", time: " " + clock)
        } else if days == 1 {
            self.init(day: "Yesterday", time: " " + clock)
        } else if days > 1, days < 7 {
            self.init(day: style("EEEE"), time: " " + clock)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            self.init(day: style("EEEMMMd"), time: " at " + clock)
        } else {
            self.init(day: style("yMMMd"), time: " at " + clock)
        }
    }
}

/// A centred transcript time header: secondary, day word semibold. iOS: 11 pt (the real
/// app's "Today 12:50 AM" line is 13.3 pt tall: Caption 2, Day Semibold + time Regular).
struct TimeHeader: View {
    let date: Date
    var now: Date = .now

    @Environment(\.bubbleMetrics) private var metrics

    var body: some View {
        let words = TimeHeaderText(date, now: now)
        Text("\(Text(words.day).fontWeight(.semibold))\(words.time)")
            .font(.system(size: Self.size(metrics)))
            .foregroundStyle(Tokens.color.secondaryLabel.color)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words.plain)
            .accessibilityAddTraits(.isHeader)
    }

    static func size(_ metrics: BubbleMetrics) -> CGFloat {
        #if os(iOS)
        metrics.captionSize - 1
        #else
        metrics.captionSize + 1
        #endif
    }
}
