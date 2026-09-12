import Foundation

/// How far the original has run ahead of the translation a reader follows.
///
/// The English edition leads the section — it is the one being read — and the
/// original is only mentioned when it has something to say that English cannot.
/// Abdi's framing (2026-09-12): "show english and mention the gap when korean
/// is ahead."
///
/// Two different facts live here, and conflating them would be the bug. That
/// the original is further along is ordinary — every translation lags, and
/// saying so on every series is noise. That the original has *stopped* while
/// the translation is still running is not ordinary: it means the English will
/// catch up and then halt, and nothing on the English side can reveal it. That
/// is the case worth surfacing, and the reason for reading the Korean feed at
/// all.
enum TranslationGap: Equatable, Sendable {
    /// Nothing worth saying — no original data, or it is not meaningfully ahead.
    case none
    /// The original is further along, and still moving.
    case ahead(episodes: Int)
    /// The original has not released in a long time, measured against its own
    /// rhythm rather than the calendar. The translation will run out.
    case originalPaused(since: Date, episodesAhead: Int)

    var isEmpty: Bool {
        if case .none = self { return true }
        return false
    }

    /// How many of the original's own release gaps must pass in silence before
    /// this calls it paused.
    ///
    /// **A guess.** Three missed releases is the fewest that is clearly not one
    /// slipped week, and a weekly series then has to be quiet for the better
    /// part of a month before the app says anything. It was not fitted against
    /// a corpus of real hiatuses — that would need a set of known ones to check
    /// against, which nothing here has.
    static let silentGapsBeforePaused = 3.0

    /// Compares the translation a reader follows against its original.
    ///
    /// - Parameters:
    ///   - translated: the highest episode number the reader's edition has.
    ///   - original: the highest the original has, and when it last moved.
    ///   - originalCadence: the original's own rhythm, where enough history
    ///     exists to have measured one. Without it nothing is called paused:
    ///     "quiet for six weeks" means one thing for a weekly series and
    ///     nothing at all for an irregular one.
    static func between(
        translated: Int?,
        original: (number: Int, lastRelease: Date)?,
        originalCadence: Cadence?,
        now: Date
    ) -> TranslationGap {
        guard let original, let translated, original.number > translated else { return .none }
        let ahead = original.number - translated

        guard let cadence = originalCadence, cadence.medianGapDays > 0 else {
            return .ahead(episodes: ahead)
        }
        let silence = now.timeIntervalSince(original.lastRelease)
        let allowed = Double(cadence.medianGapDays) * 86_400 * silentGapsBeforePaused
        guard silence > allowed else { return .ahead(episodes: ahead) }
        return .originalPaused(since: original.lastRelease, episodesAhead: ahead)
    }
}
