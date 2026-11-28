import Foundation

/// How often a repeating checklist's template is copied into a fresh list,
/// and whether a new copy takes over the previous copy's unfinished tasks.
///
/// Stored in the template file as a marker line after its title:
///
///     # Morning Routine
///     <!-- listful: repeat=weekly:mon,wed carry-over made-on=<id>:Home%20Mac -->
///
/// Every frequency's options are kept (so switching frequency in the editor
/// and back doesn't lose them), but only the current frequency's are written
/// or compared.
public struct RepeatSchedule: Equatable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable {
        case daily, weekdays, weekly, monthly, quarterly, yearly
    }

    public var frequency: Frequency
    /// For weekly: `Calendar` weekday numbers, 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    /// For monthly: 1–31, clamped to the month's length; 0 is the last day.
    public var dayOfMonth: Int
    /// For yearly: the month (1–12) and day (1–31, clamped as for monthly).
    public var month: Int
    public var day: Int
    /// Whether a new copy takes the previous copy's unfinished tasks,
    /// removing them from it.
    public var carriesOver: Bool
    /// The only device that makes this template's copies; nil for any device.
    /// Written as `made-on=<id>:<name>`, the name percent-encoded.
    public var maker: RepeatingDevice?

    public init(
        frequency: Frequency = .daily,
        weekdays: Set<Int> = [2],
        dayOfMonth: Int = 1,
        month: Int = 1,
        day: Int = 1,
        carriesOver: Bool = false,
        maker: RepeatingDevice? = nil
    ) {
        self.frequency = frequency
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.month = month
        self.day = day
        self.carriesOver = carriesOver
        self.maker = maker
    }

    public static func == (a: RepeatSchedule, b: RepeatSchedule) -> Bool {
        a.markerWords == b.markerWords
    }

    // MARK: - Periods

    /// The start (midnight) of the period containing `date`: the most recent
    /// day on or before it that the schedule makes a copy.
    public func occurrence(onOrBefore date: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.year, .month], from: today)
        let year = parts.year!, thisMonth = parts.month!
        switch frequency {
        case .daily:
            return today
        case .weekdays, .weekly:
            let days = frequency == .weekdays ? Set(2...6) : effectiveWeekdays
            for back in 0..<7 {
                let day = calendar.date(byAdding: .day, value: -back, to: today)!
                if days.contains(calendar.component(.weekday, from: day)) { return day }
            }
            return today
        case .monthly:
            let candidate = Self.date(year: year, month: thisMonth, day: dayOfMonth, calendar: calendar)
            if candidate <= today { return candidate }
            let previous = calendar.date(byAdding: .month, value: -1, to: Self.date(year: year, month: thisMonth, day: 1, calendar: calendar))!
            let p = calendar.dateComponents([.year, .month], from: previous)
            return Self.date(year: p.year!, month: p.month!, day: dayOfMonth, calendar: calendar)
        case .quarterly:
            return Self.date(year: year, month: (thisMonth - 1) / 3 * 3 + 1, day: 1, calendar: calendar)
        case .yearly:
            let candidate = Self.date(year: year, month: month, day: day, calendar: calendar)
            return candidate <= today ? candidate : Self.date(year: year - 1, month: month, day: day, calendar: calendar)
        }
    }

    /// Names the period starting at `occurrence` in copies' file names. Keys
    /// of one frequency sort in date order.
    public func periodKey(for occurrence: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: occurrence)
        switch frequency {
        case .daily, .weekdays, .weekly: return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        case .monthly: return String(format: "%04d-%02d", c.year!, c.month!)
        case .quarterly: return String(format: "%04d-Q%d", c.year!, (c.month! - 1) / 3 + 1)
        case .yearly: return String(format: "%04d", c.year!)
        }
    }

    /// Whether `key` has the shape `periodKey` gives for this frequency.
    public func isPeriodKey(_ key: String) -> Bool {
        let pattern = switch frequency {
        case .daily, .weekdays, .weekly: #"^\d{4}-\d{2}-\d{2}$"#
        case .monthly: #"^\d{4}-\d{2}$"#
        case .quarterly: #"^\d{4}-Q[1-4]$"#
        case .yearly: #"^\d{4}$"#
        }
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    /// Names the period starting at `occurrence` in copies' titles, such as
    /// "Tue 3 Nov", "November 2026" or "Q4 2026".
    public func periodLabel(for occurrence: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let c = calendar.dateComponents([.year, .month], from: occurrence)
        switch frequency {
        case .daily, .weekdays, .weekly: formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        case .monthly: formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        case .quarterly: return "Q\((c.month! - 1) / 3 + 1) \(c.year!)"
        case .yearly: return "\(c.year!)"
        }
        return formatter.string(from: occurrence)
    }

    /// A sentence for the template's header, such as "Repeats weekly on Mon and Wed".
    public func summary(calendar: Calendar, locale: Locale) -> String {
        switch frequency {
        case .daily: return "Repeats every day"
        case .weekdays: return "Repeats every weekday"
        case .weekly:
            let symbols = calendar.shortWeekdaySymbols
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
            let names = order.filter(effectiveWeekdays.contains).map { symbols[$0 - 1] }
            return "Repeats weekly on " + ListFormatter.localizedString(byJoining: names)
        case .monthly:
            return "Repeats monthly on the " + (dayOfMonth == 0 ? "last day" : Self.ordinal(dayOfMonth, locale: locale))
        case .quarterly:
            return "Repeats every quarter"
        case .yearly:
            let monthName = calendar.monthSymbols[min(max(month, 1), 12) - 1]
            return "Repeats yearly on \(day == 0 ? "the last day of" : "\(day)") \(monthName)"
        }
    }

    private var effectiveWeekdays: Set<Int> {
        let days = weekdays.filter { (1...7).contains($0) }
        return days.isEmpty ? [2] : days
    }

    /// The date for `day` of a month, clamped to the month's length; 0 is the last day.
    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        let first = calendar.date(from: DateComponents(year: year, month: min(max(month, 1), 12), day: 1))!
        let length = calendar.range(of: .day, in: .month, for: first)!.count
        let clamped = day <= 0 ? length : min(day, length)
        return calendar.date(byAdding: .day, value: clamped - 1, to: first)!
    }

    private static func ordinal(_ n: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: n as NSNumber) ?? "\(n)"
    }

    // MARK: - File marker

    private static let weekdayCodes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The marker's words: `repeat=<frequency>[:<options>]`, then `carry-over` if set.
    var markerWords: [String] {
        var value = frequency.rawValue
        switch frequency {
        case .weekly:
            value += ":" + effectiveWeekdays.sorted().map { Self.weekdayCodes[$0 - 1] }.joined(separator: ",")
        case .monthly:
            value += ":" + (dayOfMonth == 0 ? "last" : "\(dayOfMonth)")
        case .yearly:
            value += String(format: ":%02d-", month) + (day == 0 ? "last" : String(format: "%02d", day))
        case .daily, .weekdays, .quarterly:
            break
        }
        var words = ["repeat=" + value] + (carriesOver ? ["carry-over"] : [])
        if let maker, let name = maker.name.addingPercentEncoding(withAllowedCharacters: Self.nameCharacters) {
            words.append("made-on=\(maker.id):\(name)")
        }
        return words
    }

    /// Reads a schedule from a marker's words; nil if there's no valid `repeat=`.
    /// What a device name may hold unencoded in a marker.
    private static let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    init?(markerWords words: Set<String>) {
        guard let word = words.first(where: { $0.hasPrefix("repeat=") }) else { return nil }
        let value = word.dropFirst("repeat=".count)
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard let name = parts.first, let frequency = Frequency(rawValue: name) else { return nil }
        self.init(frequency: frequency, carriesOver: words.contains("carry-over"))
        if let made = words.first(where: { $0.hasPrefix("made-on=") }) {
            let parts = made.dropFirst("made-on=".count).split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty {
                maker = RepeatingDevice(id: parts[0], name: parts[1].removingPercentEncoding ?? parts[1])
            }
        }
        let options = parts.count > 1 ? parts[1] : ""
        func day(_ text: Substring) -> Int? { text == "last" ? 0 : Int(text).flatMap { (1...31).contains($0) ? $0 : nil } }
        switch frequency {
        case .weekly:
            let days = options.split(separator: ",").compactMap { Self.weekdayCodes.firstIndex(of: String($0)).map { $0 + 1 } }
            if !days.isEmpty { weekdays = Set(days) }
        case .monthly:
            if let d = day(Substring(options)) { dayOfMonth = d }
        case .yearly:
            let md = options.split(separator: "-")
            if md.count == 2, let m = Int(md[0]), (1...12).contains(m), let d = day(md[1]) {
                month = m
                self.day = d
            }
        case .daily, .weekdays, .quarterly:
            break
        }
    }
}
