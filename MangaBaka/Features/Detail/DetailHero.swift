import SwiftUI
import UIKit

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
    /// Whether MangaUpdates is still being asked.
    let isScheduleLoading: Bool
    let onOpenSchedule: (() -> Void)?
    /// The series' other covers, for the fan and the gallery.
    var otherCovers: [SeriesImage] = []
    /// Overrides the series' own cover — an English edition where one exists.
    var preferredCover: Cover?
    var onOpenCovers: ((Int) -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var didCopy = false
    /// Bumped per copy, for the haptic; see `Haptics`.
    @State private var copies = 0
    /// The full column's height at the current width, measured off-screen;
    /// nil until the first layout. See `text`.
    @State private var fullHeight: CGFloat?

    /// Side by side normally; stacked at accessibility text sizes.
    ///
    /// The cover is a fixed 150pt (`Metrics.coverDetailHeroWidth`; it was
    /// 126 when this was measured), so the title gets whatever is left —
    /// about 175pt on a phone. At AX5 that is narrower than the word "Regressed",
    /// and the title broke mid-word across four lines. Stacking gives the
    /// title the full width, which is the only thing that fixes it: shrinking
    /// the cover far enough would leave a thumbnail.
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Metrics.gapHero) {
                cover
                // Stacked, the column has the whole width and nothing beside
                // it to leave a gap under, so it is always the full form.
                column(.full)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 24)
            .padding(.bottom, Metrics.gutter)
        } else {
            wide
        }
    }

    private var cover: some View {
        CoverStack(
            series: series,
            frontCover: preferredCover ?? series.cover,
            extraCovers: otherCovers,
            width: Metrics.coverDetailHeroWidth,
            onOpen: { onOpenCovers?($0) }
        )
    }

    private var wide: some View {
        // Top-aligned, not bottom. Bottom-aligning a 150pt cover against a
        // taller column pushed the artwork half way down the screen, so the
        // page opened on a gap.
        //
        // The column is as full as the cover's height allows; see `text`.
        HStack(alignment: .top, spacing: Metrics.gapHero) {
            cover
            text
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 12)
        .padding(.bottom, Metrics.gutter)
    }

    /// How much of the hero the column shows beside the cover.
    ///
    /// The hero is an HStack of a fixed-height cover beside a column that
    /// grows, so every line the column gains past the cover becomes empty
    /// space under the artwork: on "Repeated Vice: I Refuse to Be Important
    /// Enough to Die", a five-line title, over 160pt of it between the cover
    /// and "Add to library". The first fix compressed the column for every
    /// series — one-line schedule, no byline — which threw away the byline and
    /// the cadence sentence on the short titles that had room for them.
    ///
    /// Now the full column is measured off-screen at the column's real width,
    /// and shown only if it is no taller than the cover; otherwise the compact
    /// form. Not `ViewThatFits`: inside a vertical ScrollView the proposed
    /// height is unbounded, so every candidate "fits", and forcing a frame
    /// height on it would fix the hero's height at the cover's and overlap
    /// whatever follows when even the compact form runs longer.
    enum Form: Equatable {
        /// Eyebrow, pill and lateness, cadence sentence; kicker; title; byline.
        case full
        /// Pill and lateness on one line; kicker; title. No byline.
        case compact
    }

    /// The form the measured full column earns beside a cover this tall.
    ///
    /// Compact until measured: the first frame has no height yet, and a gap
    /// that appears and then closes is worse than a byline that appears.
    nonisolated static func form(fullHeight: CGFloat?, coverHeight: CGFloat) -> Form {
        guard let fullHeight else { return .compact }
        return fullHeight <= coverHeight ? .full : .compact
    }

    /// The front cover's height. The fan behind it adds a few points, but the
    /// space that reads as a gap is the one below the front cover.
    private var coverHeight: CGFloat { Metrics.coverDetailHeroWidth / Metrics.coverAspect }

    private var text: some View {
        column(Self.form(fullHeight: fullHeight, coverHeight: coverHeight))
            // The measurer is a background: it is proposed the visible
            // column's width, which is what decides the wrapping, and its own
            // height cannot grow the column — the whole point.
            .background {
                column(.full)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        fullHeight = $0
                    }
            }
    }

    private func column(_ form: Form) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if schedule != nil || isScheduleLoading {
                DetailScheduleBlock(
                    estimate: schedule,
                    isLoading: isScheduleLoading,
                    onOpen: onOpenSchedule,
                    isExpanded: form == .full
                )
                .padding(.bottom, form == .full ? 13 : 9)
            }
            if let kicker {
                Text(kicker)
                    .typeEyebrow()
                    .foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            title
            if form == .full, let byline {
                Text(byline)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            // Directly under the name, because "is this the same book I
            // know as X?" is a question asked on arrival rather than two
            // screens down. A line and a count; the list itself is a
            // sheet, since twenty-five names inline would push the
            // synopsis off the screen.
            AlternativeTitlesButton(
                titles: series.titles ?? [],
                shown: series.displayTitle
            )
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tapping the title copies it.
    ///
    /// Reading manga means looking a title up somewhere else constantly — a
    /// reader, a shop, a search — and retyping a romanised Korean title from a
    /// phone screen is the worst way to do that. It is a tap on the thing you
    /// would point at anyway, and it says so rather than copying silently,
    /// because a clipboard change with no acknowledgement is indistinguishable
    /// from a tap that missed.
    private var title: some View {
        Button {
            UIPasteboard.general.string = series.displayTitle ?? ""
            copies += 1
            Motion.run(.snappy(duration: 0.2)) { didCopy = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                Motion.run(.snappy(duration: 0.25)) { didCopy = false }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.displayTitle ?? "Untitled series")
                    .typeDetailHeroTitle()
                    .foregroundStyle(Palette.textEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if didCopy {
                    Text("Copied")
                        .typeChip()
                        .foregroundStyle(Palette.accent)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(series.displayTitle == nil)
        .padding(.top, 6)
        .haptic(Haptics.copied, onEach: copies)
        .accessibilityLabel(series.displayTitle ?? "Untitled series")
        .accessibilityHint("Copies the title")
    }

    /// "Manhwa · Completed". Either half alone is still worth showing.
    private var kicker: String? {
        let parts = [series.type?.capitalized, SeriesStatus.label(for: series.status)]
            .compactMap { $0 }
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
