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

    var body: some View {
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
            // sections show before a "see more".
            ForEach(entries.prefix(5), id: \.published) { entry in
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
        }
    }

    /// "2 Feb".
    private static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "2 Feb 2025".
    private static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
