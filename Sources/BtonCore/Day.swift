import Foundation

/// A calendar day as the repos write it, `yyyy-MM-dd`: the one formatter behind every date Bton
/// reads from or writes into a body.
public enum Day {
    /// `date` as a day in `zone`: UTC for what Bton reads back and compares (a feature's
    /// timeline), the owner's own calendar for what they sign (a Decisions row).
    public static func text(_ date: Date, in zone: TimeZone = utc) -> String {
        formatter(in: zone).string(from: date)
    }

    /// The day `text` names, at midnight UTC; nil for anything else.
    public static func date(_ text: String) -> Date? {
        formatter(in: utc).date(from: text)
    }

    public static let utc = TimeZone(identifier: "UTC")!

    private static func formatter(in zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
