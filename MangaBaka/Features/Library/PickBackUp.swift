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
                        .countsNotCuts()
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
            zoomRoute?.neighbours = entries.compactMap(\.series)
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
                    if let fraction = Self.fraction(entry, series: series) {
                        ProgressFootBar(fraction: fraction)
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

    /// The target `ProgressFootBar` animates to — `nonisolated static` so a
    /// test can check the value the bar is aiming for without a live view.
    nonisolated static func fraction(_ entry: LibraryEntry, series: Series) -> Double? {
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

/// The 3pt bar across a cover's foot, animating in from empty rather than
/// appearing already at its value.
///
/// `Motion.settle` both times: the brief calls out first appearance
/// explicitly ("content arriving"), and a chapter just logged is content
/// arriving too — the bar answering a `+1` a beat later than the number
/// beside it would read as two different controls disagreeing.
private struct ProgressFootBar: View {
    let fraction: Double
    @State private var animatedFraction: Double = 0
    @State private var hasAppeared = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.5))
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: proxy.size.width * animatedFraction)
            }
        }
        .frame(height: 3)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            withAnimation(Motion.reduced(Motion.settle)) { animatedFraction = fraction }
        }
        .onChange(of: fraction) { _, new in
            guard hasAppeared else { return }
            withAnimation(Motion.reduced(Motion.settle)) { animatedFraction = new }
        }
    }
}
