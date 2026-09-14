import SwiftUI

/// "ESTIMATED NEXT" at the top of the series page, as the mockup draws it.
///
/// Reuses `ScheduleRow`'s wording rather than restating it. The confidence pill
/// and the lateness are deliberately two separate things: a very regular series
/// can still be late, and that combination is the most informative thing this
/// block can say. Collapsing them once produced "LIKELY — expected 6 days ago",
/// a healthy pill on a late chapter.
struct DetailScheduleBlock: View {
    /// Nil while MangaUpdates is still being asked.
    let estimate: Cadence?
    /// Whether the ask is still in flight, as opposed to finished with nothing.
    let isLoading: Bool
    let onOpen: (() -> Void)?
    /// The full form: an "Estimated next" eyebrow above the line and the
    /// cadence sentence below it. The hero asks for it only when the column
    /// has the room; see `DetailHero.Form`.
    var isExpanded: Bool = false
    /// Set when the ask itself failed — a 503, a rate limit — as opposed to
    /// MangaUpdates answering with too little history to estimate from
    /// (`ReleaseScheduleService.SeriesCadence.none`, which this block still
    /// renders nothing for). Before this the two read identically: both were
    /// "too few dated releases" by omission (gap 18, FAILURES-SUMMARY.md).
    var failure: APIError?
    var retry: (() async -> Void)?
    /// MangaUpdates' human-edited original-run text — Korean webtoons'
    /// fallback, since no lawful source publishes a next-episode date for
    /// one (`docs/sources/webtoon-episodes.md`). Nil for every series that
    /// has a real cadence estimate; see `blockState`.
    var originalRun: OriginalRun?
    /// e.g. "Korean" — `OriginalLanguageName.name(for:)` over `Series
    /// .nativeLanguage`/`impliedLanguage`. Only read alongside `originalRun`.
    var language: String?

    enum State: Equatable {
        case hidden
        case loading
        case failed(APIError)
        case measured(Cadence)
        /// No measured cadence and no feed answer — the case Korean webtoons
        /// hit. Ranked below every other case on purpose: a labelled
        /// approximation must never sit where a real next date, or even a
        /// live ask, could instead. See `OriginalRun`'s own doc comment for
        /// what it is and is not allowed to claim.
        case approximated(OriginalRun, language: String?)
    }

    /// A pure decision so the five outcomes can be pinned without building a
    /// view. `estimate` wins over `failure` — a settled measurement from a
    /// previous ask outranks a state a retry has not yet cleared. `failure`
    /// and `isLoading` both outrank `originalRun` too: an approximation is
    /// what this block falls back to only once a real ask has nothing left
    /// to say, never a state a live or failed ask could still overtake.
    nonisolated static func blockState(
        estimate: Cadence?, isLoading: Bool, failure: APIError?,
        originalRun: OriginalRun? = nil, language: String? = nil
    ) -> State {
        if let estimate { return .measured(estimate) }
        if let failure { return .failed(failure) }
        if isLoading { return .loading }
        if let originalRun { return .approximated(originalRun, language: language) }
        return .hidden
    }

    var body: some View {
        switch Self.blockState(
            estimate: estimate, isLoading: isLoading, failure: failure,
            originalRun: originalRun, language: language
        ) {
        case let .measured(estimate):
            Button { onOpen?() } label: { content(estimate) }
                .buttonStyle(.press)
                .disabled(onOpen == nil)
                .accessibilityElement(children: .combine)
                .accessibilityHint(onOpen == nil ? "" : "Opens the release schedule")
        case .loading:
            waiting
        case let .failed(error):
            InlineFailure(error: error, retry: retry)
        case let .approximated(run, language):
            approximation(run, language: language)
        case .hidden:
            EmptyView()
        }
    }

    /// The labelled-approximation line. Plain text, not a button dressed as
    /// one of the confidence pills above — nothing about a chapter count is
    /// a schedule, and the row must not read like the rest of this block's
    /// "likely"/"loose" claims.
    private func approximation(_ run: OriginalRun, language: String?) -> some View {
        Text(run.summaryLine(language: language))
            .typeSmallMeta()
            .foregroundStyle(Palette.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(run.summaryLine(language: language))
    }

    /// MangaUpdates is spaced at one request every three seconds, so this can
    /// genuinely be waiting. An empty space would read as "this series has no
    /// schedule", which is a different and possibly wrong answer.
    private var waiting: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(Palette.textMuted)
            Text("Estimating")
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Working out when the next chapter is due")
    }

    /// One line by default, inside the hero's text column; three when expanded.
    ///
    /// **It used to be four stacked rows there, always**: an "Estimated next"
    /// eyebrow, the pill and the lateness, and a cadence sentence. The column
    /// is about 230pt wide once the cover has taken its share, so the lateness
    /// wrapped to two lines and the cadence sentence to two more — six rows
    /// tall, and on a long title every one of them became empty space under
    /// the artwork. Reported on "Repeated Vice: I Refuse to Be Important
    /// Enough to Die", a five-line title.
    ///
    /// The one-line form is the pill and the lateness. The confidence and the
    /// lateness stay separate because a very regular series can still be late,
    /// and that pairing is the most informative thing this block says —
    /// collapsing them once produced "LIKELY — expected 6 days ago", a healthy
    /// pill on a late chapter. The expanded form puts the eyebrow back above
    /// and the cadence sentence back below, and the hero uses it only when it
    /// has measured that there is room. The schedule screen the chevron opens
    /// has the sentence either way.
    private func content(_ estimate: Cadence) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                Text("Estimated next")
                    .typeEyebrow()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.bottom, 8)
            }
            line(estimate)
            if isExpanded {
                Text(ScheduleRow.cadenceLine(estimate))
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func line(_ estimate: Cadence) -> some View {
        let now = Date()
        let isLate = estimate.state(asOf: now) == .late

        return HStack(spacing: 6) {
            Text(estimate.confidence.rawValue.uppercased())
                .typeTabLabel()
                .tracking(0.7)
                .foregroundStyle(
                    estimate.confidence == .likely ? Palette.onAccent : Palette.textSecondary
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    estimate.confidence == .likely ? Palette.accent : Palette.surfaceChip,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .layoutPriority(1)

            Text(ScheduleRow.stateText(estimate, isLate: isLate, now: now))
                .typeSmallMeta()
                .foregroundStyle(isLate ? Palette.accent : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if onOpen != nil {
                Image(systemName: "chevron.right")
                    .typeSymbol(size: 9, weight: .semibold)
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 0)
        }
    }
}
