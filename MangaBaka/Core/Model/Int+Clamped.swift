import Foundation

extension Int {
    /// `Int(someDouble)` traps outside roughly ±9.2×10¹⁸, on a value read
    /// straight off the wire. `LibraryEditSheet.swift:309-315` accepts and
    /// sends a chapter number as large as `1e20` with no upper bound on the
    /// field, and whether MangaBaka itself stores a value that large is
    /// unverified — every audit that looked at this flagged it as such. If it
    /// does, every one of the 27 sites below traps the next time that series'
    /// data is read, and several of them run on the very first screen after
    /// launch (`ReadingInsights` from `RootView.swift:164`,
    /// `SpotlightIndex.startSession`), which is a crash loop with no
    /// in-app fix until the value is corrected on the website.
    ///
    /// `Int(exactly:)` is the correct primitive for "does this fit losslessly"
    /// but returns `nil` for the ordinary case too — `12.5` has no exact
    /// `Int` and this initialiser's job is specifically to still produce a
    /// sensible whole number for that case, not just to survive the traps.
    ///
    /// - NaN → `0`. Not `.min`/`.max`: a NaN chapter or count is not a
    ///   directional overflow, it's a missing number, and `0` is what every
    ///   caller in this list already treats an absent count as.
    /// - `+.infinity` / a finite value that overflows `Int` → `.max`.
    /// - `-.infinity` / a finite value that underflows `Int` → `.min`.
    /// - Otherwise: truncated toward zero, same as `Int(_:)`.
    ///
    /// The 27 sites this replaces (`FAILURES-SUMMARY.md` §2(g)); each is an
    /// `Int(someDouble)` on a value that ultimately comes from the API:
    /// `SpotlightIndex.swift:93-94`; `ReadingInsights.swift:78,90`;
    /// `ReadingWrappedYear.swift:64,156`; `ReadingInsightsView.swift:96,179`;
    /// `LibraryList.swift:145,148,149,155,171,175`;
    /// `LibraryEditSheet.swift:35,152`;
    /// `ShelfDetailView.swift:239,240,252`;
    /// `LibraryControl.swift:180,191,195`; `DetailHero.swift:313`;
    /// `DetailStatsStrip.swift:58,61`; `SeriesDetailView+Store.swift:24,53`;
    /// `TrackerScores.swift:54-55`; `BlendDNAView.swift:92` (mix `weight`);
    /// `CommunityPulse.swift:73`; `SeasonReading.swift:93`. `Series.swift:136`
    /// already does the equivalent by hand for `ratingCount` and is left
    /// alone — nothing to gain from replacing a correct guard with a call
    /// to this initialiser.
    init(wholeOrClamped value: Double) {
        guard !value.isNaN else {
            self = 0
            return
        }
        guard value.isFinite else {
            self = value < 0 ? .min : .max
            return
        }
        if let exact = Int(exactly: value.rounded(.towardZero)) {
            self = exact
        } else {
            self = value < 0 ? .min : .max
        }
    }
}
