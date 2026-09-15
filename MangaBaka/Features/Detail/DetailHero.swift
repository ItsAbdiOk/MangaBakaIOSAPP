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
    /// Set when the schedule ask itself failed — see `DetailScheduleBlock`.
    var scheduleFailure: APIError?
    var onRetrySchedule: (() async -> Void)?
    /// MangaUpdates' original-run count and the language word to label it
    /// with — the schedule block's last resort, see `DetailScheduleBlock`.
    var originalRun: OriginalRun?
    var originalLanguage: String?
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
    /// The middle form's height, measured the same way.
    @State private var bylineHeight: CGFloat?
    /// The richest form's height — the full column plus the chapter count.
    @State private var chaptersHeight: CGFloat?
    /// The column width the three heights above were measured at, and for
    /// which series. The measurers are three whole extra columns, each
    /// carrying its own `.sheet` presenter, and they were laid out on every
    /// pass of the hero — four columns' worth of text layout to read three
    /// numbers that only change when the series, the width or the type size
    /// does (item 120). Once they have answered for a given key they are
    /// taken out of the tree; a new key puts them back.
    @State private var measuredFor: MeasureKey?
    /// The visible column's width, which is what the measurers are proposed.
    @State private var columnWidth: CGFloat = 0

    /// What a set of measured heights is true for.
    ///
    /// Everything `column(_:fill:rows:)` lays out from, not only the series id:
    /// the kicker, the byline, the chapter line, the "Also known as" count
    /// and the schedule block's shape all arrive *after* the first layout —
    /// `extras` fills in the chapter count and status a v2 feed payload
    /// lacks, and the cadence answers later still. With only the id in the
    /// key the measurers retired against the first, thinner column, and the
    /// form chosen no longer fit once the lines landed: the gap under the
    /// cover this whole mechanism exists to prevent came back (review item
    /// 66, 2026-09-14). Strings rather than `Series` itself, so a field
    /// that does not change the column's height does not re-measure it.
    struct MeasureKey: Equatable {
        var seriesID: Int
        var width: CGFloat
        var typeSize: DynamicTypeSize
        var kicker: String?
        var byline: String?
        var chapterCount: String?
        var titleCount: Int
        /// 0 no block, 1 loading, 2 failed, 3 an estimate — each a
        /// different height in `DetailScheduleBlock`.
        var scheduleShape: Int
    }

    /// Which `DetailScheduleBlock` the column carries, if any — see
    /// `MeasureKey.scheduleShape`. The same precedence `DetailScheduleBlock
    /// .blockState` decides with: a settled estimate wins, then a failure,
    /// then a live ask, and only once none of those has anything does the
    /// approximated original-run line get a shape of its own (4) — added
    /// after item 66 came back, 2026-09-15: `originalRun` mounts the block
    /// (`column(_:fill:rows:)`) but had no representation here, so the column
    /// was measured without its line and the gap reopened once MangaUpdates'
    /// categories leg landed the run several seconds later.
    nonisolated static func scheduleShape(
        hasSchedule: Bool, isLoading: Bool, failed: Bool, hasOriginalRun: Bool = false
    ) -> Int {
        if hasSchedule { return 3 }
        if failed { return 2 }
        if isLoading { return 1 }
        return hasOriginalRun ? 4 : 0
    }

    /// The key for the column as it would be laid out right now. Pure and
    /// static so `DetailHeroFormTests` can hold that a chapter count landing
    /// changes it and a field that does not shape the column does not.
    nonisolated static func measureKey(
        series: Series, scheduleShape: Int, width: CGFloat, typeSize: DynamicTypeSize
    ) -> MeasureKey {
        MeasureKey(
            seriesID: series.id, width: width, typeSize: typeSize,
            kicker: kicker(for: series), byline: byline(for: series), chapterCount: chapterCount(for: series),
            titleCount: series.titles?.count ?? 0, scheduleShape: scheduleShape
        )
    }

    /// Side by side normally; stacked at accessibility text sizes.
    ///
    /// The cover is a fixed 150pt (`Metrics.coverDetailHeroWidth`; it was
    /// 126 when this was measured), so the title gets whatever is left —
    /// about 175pt on a phone. At AX5 that is narrower than the word "Regressed",
    /// and the title broke mid-word across four lines. Stacking gives the
    /// title the full width, which is the only thing that fixes it: shrinking
    /// the cover far enough would leave a thumbnail.
    var body: some View {
        // Computed once per body pass and threaded down to every `column(_:
        // fill:rows:)` call — up to four while the measurers are mounted
        // (P15) — rather than each one re-running its own merge over
        // `titles` plus the three optional fields.
        let alternativeTitleRows = AlternativeTitlesButton.rows(
            titles: series.titles ?? [], shown: series.displayTitle,
            romanizedTitle: series.romanizedTitle, nativeTitle: series.nativeTitle,
            secondaryTitles: series.secondaryTitles
        )
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Metrics.gapHero) {
                cover
                // Stacked, the column has the whole width and nothing beside
                // it to leave a gap under, so it is always the full form.
                column(.full, fill: false, rows: alternativeTitleRows)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 24)
            .padding(.bottom, Metrics.gutter)
        } else {
            wide(rows: alternativeTitleRows)
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

    private func wide(rows: [SeriesTitle.Alternative]) -> some View {
        // Top-aligned, not bottom. Bottom-aligning a 150pt cover against a
        // taller column pushed the artwork half way down the screen, so the
        // page opened on a gap.
        //
        // The column is as full as the cover's height allows; see `text`.
        HStack(alignment: .top, spacing: Metrics.gapHero) {
            cover
            text(rows: rows)
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
        /// Everything `full` has, plus the chapter count. The richest form, and
        /// only reachable on a short column — a one- or two-line title with a
        /// cover's worth of height still unspent. Asked for by Abdi
        /// (2026-09-12): the count is the thing you want next to the artwork
        /// when deciding whether to start something, and on those series the
        /// space was simply empty. The stats strip still carries it further
        /// down for every series, short column or not.
        case chapters
        /// Eyebrow, pill and lateness, cadence sentence; kicker; title; byline.
        case full
        /// Pill and lateness on one line; kicker; title; byline. The middle:
        /// a three-line title had room for the byline but not the cadence
        /// sentence, and went straight to compact — 60pt of gap under a
        /// column that could have said who drew it (Abdi's screenshot,
        /// "Return of the Blossoming Blade", 2026-09-11).
        case byline
        /// Pill and lateness on one line; kicker; title. No byline.
        case compact

        var hasByline: Bool { self != .compact }
        var isExpanded: Bool { self == .chapters || self == .full }
        var showsChapters: Bool { self == .chapters }
    }

    /// The richest form whose measured height fits beside a cover this tall.
    ///
    /// Compact until measured: the first frame has no height yet, and a gap
    /// that appears and then closes is worse than a byline that appears.
    nonisolated static func form(
        chaptersHeight: CGFloat?,
        fullHeight: CGFloat?,
        bylineHeight: CGFloat?,
        coverHeight: CGFloat
    ) -> Form {
        if let chaptersHeight, chaptersHeight <= coverHeight { return .chapters }
        if let fullHeight, fullHeight <= coverHeight { return .full }
        if let bylineHeight, bylineHeight <= coverHeight { return .byline }
        return .compact
    }

    /// The front cover's height. The fan behind it adds a few points, but the
    /// space that reads as a gap is the one below the front cover.
    private var coverHeight: CGFloat { Metrics.coverDetailHeroWidth / Metrics.coverAspect }

    private func text(rows: [SeriesTitle.Alternative]) -> some View {
        let form = Self.form(
            chaptersHeight: chaptersHeight,
            fullHeight: fullHeight,
            bylineHeight: bylineHeight,
            coverHeight: coverHeight
        )
        // The chosen form, stretched to the cover's height with the slack
        // in the gaps between its blocks — schedule, name, other names — so
        // the column ends where the cover ends instead of some way above
        // it. A column taller than the cover is left alone.
        return column(form, fill: true, rows: rows)
            .frame(minHeight: coverHeight, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
            // The measurers are a background: proposed the visible column's
            // width, which is what decides the wrapping, and their own
            // heights cannot grow the column — the whole point.
            .background { measurers(rows: rows) }
    }

    /// The three off-screen columns, mounted only while their answer for the
    /// current series, width and type size is not already known.
    @ViewBuilder
    private func measurers(rows: [SeriesTitle.Alternative]) -> some View {
        let key = Self.measureKey(
            series: series,
            scheduleShape: Self.scheduleShape(
                hasSchedule: schedule != nil, isLoading: isScheduleLoading, failed: scheduleFailure != nil,
                hasOriginalRun: originalRun != nil
            ),
            width: columnWidth, typeSize: typeSize
        )
        if columnWidth > 0, measuredFor != key {
            ZStack {
                column(.chapters, fill: false, rows: rows)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        chaptersHeight = $0
                    }
                column(.full, fill: false, rows: rows)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        fullHeight = $0
                    }
                column(.byline, fill: false, rows: rows)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        bylineHeight = $0
                    }
            }
            // Recorded off the ZStack's own height rather than inside one of
            // the three actions above: an action only fires when its value
            // changes, and a re-measure that happens to land on the same
            // number would otherwise never retire the measurers.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard height > 0 else { return }
                measuredFor = key
            }
        }
    }

    /// `fill` puts spacers between the blocks, which is what lets the
    /// column stretch; the measurers leave them out so they report the
    /// column's natural height. `rows` is `AlternativeTitlesButton`'s
    /// already-merged list — computed once in `body`, not re-derived by
    /// each of up to four columns (P15).
    private func column(_ form: Form, fill: Bool, rows: [SeriesTitle.Alternative]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if schedule != nil || isScheduleLoading || scheduleFailure != nil || originalRun != nil {
                DetailScheduleBlock(
                    estimate: schedule,
                    isLoading: isScheduleLoading,
                    onOpen: onOpenSchedule,
                    isExpanded: form.isExpanded,
                    failure: scheduleFailure,
                    retry: onRetrySchedule,
                    originalRun: originalRun,
                    language: originalLanguage
                )
                .padding(.bottom, form.isExpanded ? 13 : 9)
                if fill { Spacer(minLength: 0) }
            }
            if let kicker {
                Text(kicker)
                    .typeEyebrow()
                    .foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            title
            if form.hasByline, let byline {
                Text(byline)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            if form.showsChapters, let chapterCount {
                Text(chapterCount)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, 7)
            }
            if fill { Spacer(minLength: 0) }
            // Directly under the name, because "is this the same book I
            // know as X?" is a question asked on arrival rather than two
            // screens down. A line and a count; the list itself is a
            // sheet, since twenty-five names inline would push the
            // synopsis off the screen.
            AlternativeTitlesButton(rows: rows)
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
    private var kicker: String? { Self.kicker(for: series) }
}
