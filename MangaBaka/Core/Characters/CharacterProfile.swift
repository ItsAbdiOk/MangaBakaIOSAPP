import Foundation

/// Everything AniList has about one character, beyond the name and portrait
/// already on the cast row. Verified against a live response for character
/// 138789 (Cha Hae-In) on 2026-09-12 with curl — this shape, not the
/// published schema alone, is what the mapping below was built against.
struct CharacterProfile: Equatable, Sendable {
    let id: Int
    let fullName: String
    let nativeName: String?
    /// Other names AniList knows the character by, e.g. a dub name or an
    /// epithet. Empty, not nil, when AniList sent none — the field is always
    /// an array in the schema.
    let alternativeNames: [String]
    let imageURL: URL?
    let gender: String?
    /// Verbatim from AniList. A string rather than an Int because AniList
    /// sends ranges as text, e.g. "17-18" for a character whose age changes
    /// across the story — checked against Luffy's live response, which is a
    /// number as a string, not a range, but the field is documented as
    /// freeform and other characters do carry ranges.
    let age: String?
    let bloodType: String?
    /// Formatted for display, e.g. "March 4" or "March". Nil when AniList
    /// gave no month — a day with no month is not a date worth printing, and
    /// that combination shows up in practice (year-only birthdates exist too,
    /// but a year alone answers "how old", which `age` already covers).
    let dateOfBirth: String?
    let favourites: Int?
    let siteURL: URL?
    let description: CharacterDescription?

    /// The facts worth a row each, in the order the profile screen shows
    /// them. Omits anything AniList did not send — every field above came
    /// back null at least once in real responses, and "Blood type: —" is a
    /// claim AniList never made.
    var facts: [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        if let gender, !gender.isEmpty { out.append(("Gender", gender)) }
        if let age, !age.isEmpty { out.append(("Age", age)) }
        if let dateOfBirth { out.append(("Birthday", dateOfBirth)) }
        if let bloodType, !bloodType.isEmpty { out.append(("Blood type", bloodType)) }
        if let favourites { out.append(("Favourited by", "\(favourites) on AniList")) }
        return out
    }
}

/// One character's description, cleaned of AniList's markdown-like syntax and
/// with its spoiler spans marked rather than rendered as plain text.
struct CharacterDescription: Equatable, Sendable {
    enum Span: Equatable, Sendable {
        case plain(String)
        case bold(String)
        case link(text: String, url: URL)
    }

    /// A contiguous run of the description that is either entirely inside a
    /// `~!...!~` spoiler marker or entirely outside one. Spoiler status is
    /// tracked per block, not per span, because AniList's own spoiler spans
    /// can themselves contain bold text or a link — splitting further would
    /// only fragment one reveal into several.
    struct Block: Equatable, Sendable {
        let spans: [Span]
        let isSpoiler: Bool
    }

    let blocks: [Block]

    var isEmpty: Bool { blocks.isEmpty }
}

/// Cleans an AniList character description into something safe to render.
///
/// AniList descriptions are their own dialect, not real markdown: `__bold__`,
/// `[text](url)` links, and `~!text!~` spoiler spans that can run across
/// several lines and can themselves contain bold text or a link (verified
/// live on 2026-09-12 against Luffy's and Meyrin Hawke's descriptions, both
/// of which do this). Nothing else in the app renders markdown, so this is a
/// small parser rather than a dependency.
enum CharacterDescriptionParser {
    /// `~!spoiler!~`, spanning any number of lines. Matched first: a spoiler
    /// boundary is the outermost structure, and bold/link markers inside a
    /// spoiler must not be parsed as if they belonged to the surrounding text.
    private static let spoilerPattern = "~!([\\s\\S]*?)!~"
    /// `__bold__` or `[text](url)`, matched within one spoiler-delimited
    /// segment. Not `[\s\S]` here: AniList's own bold fields are always
    /// single-line ("__Guild:__ Hunters Guild"), and letting `.` cross
    /// newlines risks swallowing an entire multi-line paragraph the moment a
    /// stray "__" appears without its closing pair.
    private static let markupPattern = "__(.+?)__|\\[([^\\]]+)\\]\\(([^)]+)\\)"

    static func parse(_ raw: String) -> CharacterDescription {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CharacterDescription(blocks: []) }
        // Cosmetic only: AniList descriptions often carry a blank line after
        // the field list before the prose starts, and some carry two or three
        // in a row. Collapsing runs of 3+ to a single blank line keeps that
        // paragraph break without leaving a gap the width of the fields list.
        let normalized = collapse(trimmed)

        let segments = spoilerSegments(in: normalized)
        let blocks = segments.compactMap { segment -> CharacterDescription.Block? in
            guard !segment.text.isEmpty else { return nil }
            return CharacterDescription.Block(spans: spans(in: segment.text), isSpoiler: segment.isSpoiler)
        }
        return CharacterDescription(blocks: blocks)
    }

    private static func collapse(_ text: String) -> String {
        replacing(pattern: "\\n{3,}", in: text, template: "\n\n")
    }

    private struct Segment {
        let text: String
        let isSpoiler: Bool
    }

    /// Splits on `~!...!~`, returning the non-spoiler text between markers and
    /// the spoiler text inside them, in the order they appeared.
    private static func spoilerSegments(in text: String) -> [Segment] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: spoilerPattern) else {
            return [Segment(text: text, isSpoiler: false)]
        }
        var segments: [Segment] = []
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let full = match.range
            if full.location > cursor {
                let range = NSRange(location: cursor, length: full.location - cursor)
                segments.append(Segment(text: ns.substring(with: range), isSpoiler: false))
            }
            segments.append(Segment(text: ns.substring(with: match.range(at: 1)), isSpoiler: true))
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            segments.append(Segment(text: ns.substring(from: cursor), isSpoiler: false))
        }
        return segments
    }

    /// Parses `__bold__` and `[text](url)` out of one segment, preserving the
    /// plain text between and around them.
    private static func spans(in text: String) -> [CharacterDescription.Span] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: markupPattern) else {
            return [.plain(text)]
        }
        var spans: [CharacterDescription.Span] = []
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let full = match.range
            if full.location > cursor {
                let range = NSRange(location: cursor, length: full.location - cursor)
                spans.append(.plain(ns.substring(with: range)))
            }
            if match.range(at: 1).location != NSNotFound {
                spans.append(.bold(ns.substring(with: match.range(at: 1))))
            } else if match.range(at: 2).location != NSNotFound, match.range(at: 3).location != NSNotFound {
                let linkText = ns.substring(with: match.range(at: 2))
                let rawURL = ns.substring(with: match.range(at: 3))
                // A link AniList sent that does not parse as a URL is shown as
                // plain text rather than dropped — the words are still part of
                // the sentence even if the destination is unusable.
                if let url = URL(string: rawURL) {
                    spans.append(.link(text: linkText, url: url))
                } else {
                    spans.append(.plain(linkText))
                }
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            spans.append(.plain(ns.substring(from: cursor)))
        }
        return spans.isEmpty ? [.plain(text)] : spans
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template
        )
    }
}

/// The one gate a profile request must pass: AniList's id space and
/// Shikimori's are two unrelated numbering systems that happen to overlap
/// (id 40 is Monkey D. Luffy on AniList; Shikimori's own id 40 is somebody
/// else). A character whose cast row was answered by Shikimori carries a
/// Shikimori id in `SeriesCharacter.id`, and asking AniList for a profile
/// with it would return a real, wrong person with no sign anything went
/// wrong. This function is the only place that is allowed to turn a
/// `SeriesCharacter` into an AniList character id.
enum CharacterProfileRequest {
    static func aniListID(for character: SeriesCharacter) -> Int? {
        character.source == .aniList ? character.id : nil
    }
}
