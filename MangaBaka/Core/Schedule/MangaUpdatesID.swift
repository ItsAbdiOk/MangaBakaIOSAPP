import Foundation

/// Converts MangaBaka's MangaUpdates identifier into the number their API wants.
///
/// MangaBaka publishes the id as a base-36 string ("7s905mh"); the MangaUpdates
/// API expects the decoded integer (16945653113).
///
/// **Getting this wrong does not fail loudly.** Sending the raw base-36 string
/// returns HTTP 200 with releases from entirely unrelated series — verified
/// 2026-09-09, where "7s905mh" came back with today's chapters of "I'm Really
/// Not the Evil God's Lackey" and "The Stellar Swordmaster" instead of
/// "Shingetsutan Tsukihime". The search silently falls back to a text match.
///
/// A cadence built from that is not missing, it is confidently wrong: every
/// series would look like it ships daily, because the fallback returns whatever
/// happened to be released today. That is why this is its own type with its own
/// tests rather than an inline `Int(string, radix: 36)`.
enum MangaUpdatesID {
    /// The numeric id, or nil when the value cannot be decoded.
    ///
    /// Accepts an already-numeric id unchanged, because the API returns ids as
    /// strings on some trackers and numbers on others and this app should not
    /// care which it was handed.
    static func number(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // An all-digit id is already the number. Note this is deliberately
        // checked first: "12345" is also valid base-36 and would decode to
        // something entirely different.
        if trimmed.allSatisfy(\.isNumber) { return Int(trimmed) }

        // Base 36 uses 0-9 and a-z. Anything else is not an id we understand,
        // and guessing would send a malformed search that returns wrong data
        // rather than an error.
        guard trimmed.allSatisfy({ $0.isNumber || ("a"..."z").contains($0) }) else { return nil }
        return Int(trimmed, radix: 36)
    }
}
