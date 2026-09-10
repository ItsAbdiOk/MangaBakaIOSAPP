import Foundation

/// The API's publication statuses, in words a reader would use.
///
/// The raw values are identifiers, and printing them capitalised produced
/// "Manhwa · On_hiatus" on the series page. They are also the values the
/// schedule matches on, so they cannot simply be prettified at the source.
enum SeriesStatus {
    private static let names: [String: String] = [
        "releasing": "Releasing",
        "completed": "Completed",
        "hiatus": "On hiatus",
        "on_hiatus": "On hiatus",
        "cancelled": "Cancelled",
        "upcoming": "Upcoming",
        "unknown": "Status unknown"
    ]

    /// Nil for a status the API did not give, so a caller can leave it out
    /// rather than print a placeholder.
    static func label(for status: String?) -> String? {
        guard let status, !status.isEmpty else { return nil }
        // An unrecognised status is still shown, tidied — a new value from the
        // API should read oddly, not disappear.
        return names[status] ?? status
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
