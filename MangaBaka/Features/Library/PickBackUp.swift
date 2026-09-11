import SwiftUI

/// The row of series you are part-way through, with progress across each cover.
///
/// Its own file because LibraryView reached the lint's body-length ceiling.
struct PickBackUp: View {
    let entries: [LibraryEntry]
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Pick back up")
                        .typeSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(entries.count) in progress")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 11)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: Metrics.gapCovers) {
                        ForEach(entries) { entry in
                            if let series = entry.series {
                                card(entry, series: series)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    /// A cover with a progress bar across its foot. `progress_chapter` against
    /// `total_chapters` is real for about three quarters of a library.
    private func card(_ entry: LibraryEntry, series: Series) -> some View {
        Button {
            zoomRoute?.source = ZoomRoute.id("pickup", series.id)
            path.append(series)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                CoverImage(
                    cover: series.cover,
                    width: Metrics.coverSavedStripWidth,
                    radius: Metrics.radiusCoverRow,
                    accessibilityText: series.displayTitle ?? "Untitled series"
                )
                .overlay(alignment: .bottom) {
                    if let fraction = fraction(entry, series: series) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5))
                                Rectangle()
                                    .fill(Palette.accent)
                                    .frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                Text(chapterLabel(entry))
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(width: Metrics.coverSavedStripWidth, alignment: .leading)
        }
        .buttonStyle(.press)
        .zoomSource("pickup", series.id)
        .accessibilityLabel(
            "\(series.displayTitle ?? "Untitled series"), \(chapterLabel(entry))"
        )
    }

    private func fraction(_ entry: LibraryEntry, series: Series) -> Double? {
        guard let read = entry.progressChapter, read > 0,
              let total = series.totalChapters, total > 0
        else { return nil }
        return min(read / total, 1)
    }

    private func chapterLabel(_ entry: LibraryEntry) -> String {
        guard let read = entry.progressChapter, read > 0 else { return "Not started" }
        return "ch \(Int(read))"
    }
}
