import SwiftUI

/// What a publisher's own feed says about when a series releases.
///
/// Placed right before the volumes shelf, and styled the same way: the header
/// names the source the way `AppleVolumesRow` names Apple and Google, because
/// a claim as specific as "every 7 days" needs to say who is making it. See
/// `ReleaseFeedService` for how the report is built and `ReleaseSummary` for
/// why `.none` renders nothing at all — an empty box here would read as "this
/// series has no schedule" rather than "nothing came back".
struct ReleaseSection: View {
    let report: ReleaseReport
    /// Nothing is shown while loading either, for the same reason `.none`
    /// shows nothing: a placeholder box reads as an answer, not as "asking".
    let isLoading: Bool
    /// The series' own links, so the loading skeleton (gap 20) only appears
    /// for a series a provider is actually matched to — every other series
    /// would otherwise flash an empty "Releases" skeleton on every visit
    /// while the providers answer `.notCarried`.
    var links: [SeriesLink] = []
    var retry: (() async -> Void)?

    enum State: Equatable {
        case hidden
        case loading
        case failed(APIError)
        case shown
    }

    /// Whether any of the series' links belong to a publisher this app reads
    /// releases from at all.
    nonisolated static func isMatched(links: [SeriesLink]) -> Bool {
        links.contains { ReleaseSource.serving($0.safeURL) != nil }
    }

    /// A pure decision over the report — no `isMatched` here, since a report
    /// with a real answer or a real failure already implies a provider was
    /// asked; `isMatched` only gates the loading skeleton in `body`, where
    /// nothing has answered yet.
    nonisolated static func sectionState(report: ReleaseReport, isLoading: Bool) -> State {
        if !report.summary.isEmpty, report.source != nil { return .shown }
        if isLoading { return .loading }
        // Gap 19: `.notCarried` providers are excluded from `failedSources`
        // (`ReleaseFeedService.report`) — only a provider that actually had a
        // link for this series and then failed lands here, so this branch
        // never fires for a series no provider serves at all.
        if let failure = report.failures.first {
            return .failed(failure.error)
        }
        return .hidden
    }

    var body: some View {
        let state = Self.sectionState(report: report, isLoading: isLoading)
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case .loading:
                if Self.isMatched(links: links) {
                    loadingSkeleton
                        .transition(.blurReplace)
                }
            case let .failed(error):
                VStack(alignment: .leading, spacing: 11) {
                    Text("Releases")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, Metrics.gutter)
                    InlineFailure(error: error, retry: retry)
                }
                .transition(.blurReplace)
            case .shown:
                content
                    .transition(.blurReplace)
            }
        }
        .animation(Motion.reduced(Motion.settle), value: state)
    }

    @ViewBuilder
    private var content: some View {
        if !report.summary.isEmpty, let source = report.source {
            VStack(alignment: .leading, spacing: 11) {
                Text(header(source))
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                VStack(alignment: .leading, spacing: 6) {
                    rows
                    if !report.gap.isEmpty {
                        gapLine
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
        }
    }

    /// A single muted line where the content would be, so the section does
    /// not pop in after the page has already settled (gap 20).
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Releases")
                .typeDetailSectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Metrics.gutter)
            Capsule()
                .fill(Palette.surface)
                .frame(width: 160, height: 12)
                .padding(.horizontal, Metrics.gutter)
                .shimmering()
        }
        .accessibilityHidden(true)
    }

    /// "Releases · Tonari no Young Jump" for a GigaViewer feed matched to a
    /// specific host, "Releases · Webtoons" / "Releases · Naver Webtoon"
    /// otherwise.
    private func header(_ source: ReleaseSource) -> String {
        if let sourceName = report.sourceName { return "Releases · \(sourceName)" }
        return source.attribution
    }

    @ViewBuilder
    private var rows: some View {
        switch report.summary {
        case .none:
            EmptyView()

        case let .rhythm(cadence, latest):
            Text(ScheduleRow.cadenceLine(cadence))
                .typeSmallMeta()
                .foregroundStyle(Palette.textPrimary)
            if let latest {
                row(episodeLine(latest))
            }

        case let .recent(entries):
            // At most five: this is a list of what actually arrived, not the
            // whole feed, and five matches what the mockup's other rowed
            // sections show before a "see more". Keyed by offset, not
            // `\.published`: True Beauty's Episode 0-2 and Estate Developer's
            // Ep. 1-3 all share one timestamp in the live feed (measured
            // 2026-09-13), and a duplicate SwiftUI id collapses or
            // mis-renders rows.
            ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                row(episodeLine(entry))
            }

        case let .lastSeen(latest, _):
            row("Last episode · \(Self.shortDate(latest))")

        case let .seasonEnded(season, on):
            row(seasonEndedLine(season: season, on: on))
        }
    }

    private func row(_ text: String) -> some View {
        Text(text)
            .typeSmallMeta()
            .foregroundStyle(Palette.textMuted)
    }

    private func episodeLine(_ entry: ReleaseEntry) -> String {
        guard let number = entry.number else { return Self.shortDate(entry.published) }
        return "Ep. \(number) · \(Self.shortDate(entry.published))"
    }

    private func seasonEndedLine(season: Int?, on date: Date) -> String {
        let seasonPart = season.map { "Season \($0)" } ?? "The season"
        return "\(seasonPart) ended on \(Self.longDate(date))"
    }

    /// "The Korean original is 28 episodes ahead" or, when it has stopped
    /// releasing, the warning that the translation will run out.
    private var gapLine: some View {
        Text(gapText)
            .typeSmallMeta()
            .foregroundStyle(Palette.textMuted)
    }

    private var gapText: String {
        switch report.gap {
        case .none:
            return ""
        case let .ahead(episodes):
            return "The Korean original is \(episodes) episode\(episodes == 1 ? "" : "s") ahead"
        case let .originalPaused(since, _):
            return "The Korean original hasn't released since \(Self.longDate(since)) — " +
                "the translation will catch up and stop"
        case let .originalComplete(episodesAhead):
            return "The Korean original is complete, \(episodesAhead) episode" +
                "\(episodesAhead == 1 ? "" : "s") ahead — the translation will end there"
        }
    }

    /// "2 Feb", or "19 Sep 2018" when `date` is not from the current year.
    ///
    /// Without the year, a 2018 episode (True Beauty's feed, see
    /// `ReleaseSummary`) printed as "19 Sep" — indistinguishable from last
    /// week.
    private static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        guard calendar.component(.year, from: date) == calendar.component(.year, from: now) else {
            return longDate(date)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "2 Feb 2025".
    private static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
