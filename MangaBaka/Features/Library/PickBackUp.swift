import SwiftUI

/// The row of series you are part-way through, with progress across each cover.
///
/// Its own file because LibraryView reached the lint's body-length ceiling.
struct PickBackUp: View {
    let entries: [LibraryEntry]
    @Binding var path: [Series]
    /// The library's strip is small; Discover passes the same width as the
    /// rows under it so the sections read as one family (Abdi, 2026-09-13).
    var coverWidth: CGFloat = Metrics.coverSavedStripWidth
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
                                    .arrives()
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 2)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
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
                    width: coverWidth,
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
                // Clipped to the cover's own corners: the bar used to run
                // straight across the foot and stick out past the curve, so
                // it read as a separate object under the picture (Abdi,
                // 2026-09-13).
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous))
                Text(Self.chapterLabel(entry))
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(width: coverWidth, alignment: .leading)
        }
        .buttonStyle(.press)
        .zoomSource("pickup", series.id)
        .accessibilityLabel(
            "\(series.displayTitle ?? "Untitled series"), \(Self.chapterLabel(entry))"
        )
    }

    private func fraction(_ entry: LibraryEntry, series: Series) -> Double? {
        guard let read = entry.progressChapter, read > 0,
              let total = series.totalChapters, total > 0
        else { return nil }
        return min(read / total, 1)
    }

    nonisolated static func chapterLabel(_ entry: LibraryEntry) -> String {
        guard let read = entry.progressChapter, read > 0 else { return "Not started" }
        // L7: truncated to "ch 12" for a reader at 12.5, the same number
        // shown whole one tap away in the editor.
        return "ch \(LibraryEditSheet.chapterText(read))"
    }
}
