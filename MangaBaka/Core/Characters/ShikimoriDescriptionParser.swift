import Foundation

/// Cleans a Shikimori character description into the same `CharacterDescription`
/// span/block model `CharacterDescriptionParser` builds for AniList, so
/// `CharacterProfileView` renders either source through one path.
///
/// Shikimori's own dialect is BBCode, not markdown, and it is Russian text —
/// translation happens separately, after this parser has run (see
/// `CharacterDescriptionTranslator`), because a BBCode tag surviving a
/// machine translation usually comes back mangled or literal ("[b]" printed
/// as words). Structure is extracted first; only the plain words inside it
/// ever reach the translator.
///
/// Verified with curl against real character descriptions on 2026-09-12
/// (ids 40, 1, 5, 6, 46, 71, 118, 4899, 15613 — a One Piece, Cowboy Bebop,
/// Bleach, Death Note, Nanatsu no Bitoku and others). Observed tags across
/// that sample: `[h3]`, `[character=ID]`, `[spoiler]` and `[spoiler=label]`,
/// `[url=href]` and bare `[url]`. `[b]` and `[i]` were not hit by that sample
/// but are documented Shikimori BBCode and handled here on that basis alone —
/// unverified against a live response, unlike everything above it.
enum ShikimoriDescriptionParser {
    /// `[spoiler]...[/spoiler]` or `[spoiler=label]...[/spoiler]`. The label,
    /// when present, is Shikimori's own spoiler-topic hint ("спойлер") and is
    /// dropped: the app's own spoiler chip already says "Spoiler" without
    /// needing a second label to translate.
    private static let spoilerPattern = "\\[spoiler(?:=[^\\]]*)?\\]([\\s\\S]*?)\\[/spoiler\\]"

    /// `[h1]`–`[h6]`, `[b]`, `[i]`, `[url=href]text[/url]`, bare
    /// `[url]href[/url]`, and `[character=id]name[/character]`, matched
    /// within one spoiler-delimited segment. Non-greedy and `[\s\S]` throughout
    /// because a heading's own text has, in practice, run across more than
    /// one visual line without a blank line between (id 40's "История"
    /// section).
    private static let markupPattern = """
    \\[h[1-6]\\]([\\s\\S]*?)\\[/h[1-6]\\]\
    |\\[b\\]([\\s\\S]*?)\\[/b\\]\
    |\\[i\\]([\\s\\S]*?)\\[/i\\]\
    |\\[url=([^\\]]+)\\]([\\s\\S]*?)\\[/url\\]\
    |\\[url\\]([\\s\\S]*?)\\[/url\\]\
    |\\[character=(\\d+)\\]([\\s\\S]*?)\\[/character\\]
    """

    /// Where a `[character=id]` link points by default: Shikimori's own
    /// public site, never AniList's — the id in the tag is a Shikimori id,
    /// and the two id spaces must never be crossed (see `CharacterProfileRequest`).
    private static let defaultCharactersURL =
        URL(string: "https://shikimori.one/characters/").unsafeShikimoriCharactersFallback

    /// - Parameter charactersURL: overridable for tests; see `defaultCharactersURL`.
    static func parse(
        _ raw: String,
        charactersURL: URL = ShikimoriDescriptionParser.defaultCharactersURL
    ) -> CharacterDescription {
        // Shikimori sends CRLF; every other line-ending check in this file
        // and in the view layer assumes "\n" alone.
        let trimmed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CharacterDescription(blocks: []) }

        let segments = spoilerSegments(in: trimmed)
        let blocks = segments.compactMap { segment -> CharacterDescription.Block? in
            guard !segment.text.isEmpty else { return nil }
            return CharacterDescription.Block(
                spans: spans(in: segment.text, charactersURL: charactersURL),
                isSpoiler: segment.isSpoiler
            )
        }
        return CharacterDescription(blocks: blocks)
    }

    private struct Segment {
        let text: String
        let isSpoiler: Bool
    }

    /// Same split-on-marker approach as `CharacterDescriptionParser`'s
    /// spoiler handling — see that type for why the spoiler boundary has to
    /// be resolved before anything nested inside it.
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

    /// Parses heading, bold, italic, link and character-reference markup out
    /// of one segment, preserving the plain text between and around them.
    ///
    /// A heading becomes a bold span rather than a distinct visual style —
    /// `CharacterDescription.Span` has no heading case, by design (see its
    /// doc comment), so a Shikimori "###" and an AniList "__label:__" render
    /// exactly the same way through the one path `CharacterProfileView` uses.
    /// A newline follows it, matching the blank line Shikimori's own site
    /// puts after a heading.
    private static func spans(in text: String, charactersURL: URL) -> [CharacterDescription.Span] {
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
            spans.append(contentsOf: matchedSpans(match, in: ns, charactersURL: charactersURL))
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            spans.append(.plain(ns.substring(from: cursor)))
        }
        return spans.isEmpty ? [.plain(text)] : spans
    }

    /// One matched tag's spans, split out of `spans(in:charactersURL:)` to
    /// keep that function under the lint's complexity ceiling: it is one
    /// `if`/`else if` chain over the alternation's capture groups, group
    /// numbers fixed by `markupPattern`'s own order.
    private static func matchedSpans(
        _ match: NSTextCheckingResult, in ns: NSString, charactersURL: URL
    ) -> [CharacterDescription.Span] {
        func text(_ group: Int) -> String? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }

        if let heading = text(1) { return [.bold(heading), .plain("\n")] }
        if let bold = text(2) { return [.bold(bold)] }
        if let italic = text(3) { return [.italic(italic)] }
        if let href = text(4), let linkText = text(5) {
            // An `[url=href]` whose href does not parse is shown as plain
            // text rather than dropped, same rule as the AniList parser's
            // markdown links: the words are still part of the sentence even
            // when the destination is unusable.
            if let url = URL(string: href) { return [.link(text: linkText, url: url)] }
            return [.plain(linkText)]
        }
        if let bareURLText = text(6) {
            if let url = URL(string: bareURLText) { return [.link(text: bareURLText, url: url)] }
            return [.plain(bareURLText)]
        }
        if let id = text(7), let name = text(8) {
            let url = URL(string: id, relativeTo: charactersURL)?.absoluteURL ?? charactersURL
            return [.link(text: name, url: url)]
        }
        return []
    }
}

private extension Optional where Wrapped == URL {
    var unsafeShikimoriCharactersFallback: URL {
        guard let self else { preconditionFailure("Hard-coded Shikimori characters URL failed to parse.") }
        return self
    }
}
