import Foundation

/// Compact English ages for commit rows; the system formatter localizes and is too wide for 320pt.
enum RelativeTime {
    nonisolated static func compact(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        // A future timestamp is clock skew, not a prophecy.
        guard seconds >= 60 else { return "now" }

        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        // Months and years are approximated at 30 and 365 days; a history list needs no calendar.
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }

    /// The absolute stamp the detail pane shows, fixed to en_US because the app's UI is English.
    nonisolated static func absolute(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
