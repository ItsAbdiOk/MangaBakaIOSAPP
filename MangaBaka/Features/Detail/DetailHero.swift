import SwiftUI

/// The top of a series page, built to the mockup.
///
/// The kicker (type and status) sits above the title in the accent, not in a
/// row of grey chips below it, and the native title and author share one quiet
/// line under the title rather than the author having a line of their own. The
/// wash behind it is `DetailBackdrop`, applied to the whole page.
struct DetailHero: View {
    let series: Series
    /// The release estimate, when the schedule knows one for this series.
    let schedule: Cadence?
    let onOpenSchedule: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: Metrics.gapHero) {
            CoverImage(
                cover: series.cover,
                width: Metrics.coverDetailHeroWidth,
                radius: 14
            )
            .shadow(color: .black.opacity(0.65), radius: 20, y: 18)

            VStack(alignment: .leading, spacing: 0) {
                if let schedule {
                    DetailScheduleBlock(estimate: schedule, onOpen: onOpenSchedule)
                        .padding(.bottom, 13)
                }
                if let kicker {
                    Text(kicker)
                        .typeEyebrow()
                        .foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(series.displayTitle ?? "Untitled series")
                    .typeDetailHeroTitle()
                    .foregroundStyle(Palette.textEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                if let byline {
                    Text(byline)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }
            }
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 24)
        .padding(.bottom, Metrics.gutter)
    }

    /// "Manhwa · Completed". Either half alone is still worth showing.
    private var kicker: String? {
        let parts = [series.type?.capitalized, series.status?.capitalized].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The mockup writes "native title · author". A series with no native title
    /// distinct from the displayed one shows the author alone rather than a
    /// separator with nothing before it.
    private var byline: String? {
        let parts = [nativeTitle, series.authors?.joined(separator: ", ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var nativeTitle: String? {
        guard let displayed = series.displayTitle else { return nil }
        return series.titles?
            .first { $0.traits.contains("native") && $0.title != displayed }?
            .title
    }
}
