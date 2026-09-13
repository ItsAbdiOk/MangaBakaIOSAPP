import Foundation

/// A rough fuzzy match between two character display names from different
/// trackers, so a union of AniList's and Shikimori's casts does not show
/// "Sung Jin-Woo" and "Jinwoo Sung" as two different people.
///
/// Deliberately approximate. Abdi, 2026-09-13, verbatim: "When comparing which
/// characters are on which sites, use a fuzzy match — sometimes the full name
/// (unique first name and surname), sometimes just a shorthand. A rough
/// estimation is fine; I don't mind if duplicates come through once in a
/// while." Every rule below is biased toward matching too eagerly rather than
/// too rarely on that instruction: an occasional duplicate row is the accepted
/// cost, a character silently dropped from the union is not.
///
/// Nonisolated and pure by design, so it is testable without either tracker's
/// actor: `CharacterService` is the only caller, and calls this while merging
/// two already-fetched casts.
enum CharacterNameMatch {
    /// Whether `nameA` and `nameB` are, roughly, the same character.
    ///
    /// - Parameters:
    ///   - nameA: a display name, e.g. AniList's `name.full` or Shikimori's
    ///     romaji `name`.
    ///   - nameB: the other source's display name for comparison.
    ///   - nativeA: `nameA`'s native-script name (AniList's `name.native`,
    ///     Shikimori's `japanese`), when the source sent one.
    ///   - nativeB: the other source's native-script name.
    ///
    /// Four rules, any one of which is enough — order does not matter, this
    /// is not a scored match:
    /// 1. The same tokens, in either order: "Sung Jin-Woo" / "Jinwoo Sung",
    ///    "Cha Hae-In" / "Hae-In Cha". A hyphen is treated as joining one
    ///    name rather than separating two, so "Jin-Woo" and "Jinwoo" both
    ///    normalise to the single token "jinwoo" regardless of which source
    ///    chose to spell it with a hyphen.
    /// 2. The same surname (this string's last token) and the same
    ///    first-name initial — catches an abbreviated first name against a
    ///    full one, when both sources happen to order the name the same way.
    /// 3. A single-token name (a nickname or shorthand — "Beru") equals any
    ///    token of the other ("Beru (Ant King)").
    /// 4. Both sides have a native-script name and those match, even when the
    ///    romanised names above do not. Currently unreachable from
    ///    `CharacterService`'s union — see its call site — because neither
    ///    tracker's cast-list response (as opposed to a full profile) carries
    ///    a native name; kept here, tested, and wired for whichever future
    ///    caller has one.
    static func matches(
        _ nameA: String, _ nameB: String, nativeA: String? = nil, nativeB: String? = nil
    ) -> Bool {
        guard !nameA.isEmpty, !nameB.isEmpty else { return false }
        let tokensA = normalizedTokens(nameA)
        let tokensB = normalizedTokens(nameB)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }

        if tokensA.sorted() == tokensB.sorted() { return true }

        if let lastA = tokensA.last, let lastB = tokensB.last, lastA == lastB,
           let firstA = tokensA.first?.first, let firstB = tokensB.first?.first, firstA == firstB {
            return true
        }

        if tokensA.count == 1, tokensB.contains(tokensA[0]) { return true }
        if tokensB.count == 1, tokensA.contains(tokensB[0]) { return true }

        if let nativeA, let nativeB, !nativeA.isEmpty, !nativeB.isEmpty {
            let nativeTokensA = normalizedTokens(nativeA)
            let nativeTokensB = normalizedTokens(nativeB)
            if !nativeTokensA.isEmpty, nativeTokensA == nativeTokensB { return true }
        }

        return false
    }

    /// Lowercase, diacritic-folded tokens with punctuation stripped.
    ///
    /// Hyphens and apostrophes are dropped rather than turned into spaces —
    /// deliberately, so "Jin-Woo" and "O'Brien" each normalise to one token
    /// ("jinwoo", "obrien") rather than two, matching however the other
    /// source chose to spell the same name without the punctuation. Every
    /// other non-alphanumeric character (spaces, brackets, commas) becomes a
    /// token boundary.
    static func normalizedTokens(_ raw: String) -> [String] {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var tokens: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == "'" || scalar == "\u{2019}" {
                continue
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
