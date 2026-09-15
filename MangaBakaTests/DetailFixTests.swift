import Foundation
import Testing
@testable import MangaBaka

/// Tests for the 2026-09-15 perf-review fix batch (`docs/reviews/perf/
/// detail.md`, P7/P8/P9/P13/P15/P17/P18). One file per batch rather than
/// scattering each fix into whichever existing suite is topically closest,
/// so a future reader can find "what did that batch actually change" in one
/// place.
@Suite("Perf fix batch 2026-09-15 — detail")
struct DetailFixTests {
    // MARK: P7 — originalRun is part of the hero's re-measure key

    /// Before the fix `DetailHero.scheduleShape` had no `hasOriginalRun`
    /// parameter at all, so a webtoon whose `originalRun` landed after the
    /// first layout (it rides the categories leg, seconds behind cadence)
    /// never changed `MeasureKey.scheduleShape` — the measurers stayed
    /// retired against a column that had not yet grown the approximation
    /// line, and the gap under the cover came back (item 66, second time).
    /// Fails on the old signature: it does not compile without the new
    /// parameter, so there is nothing to assert a wrong value for.
    @Test("An arriving originalRun changes the schedule shape, and so the key")
    func originalRunChangesScheduleShape() {
        let none = DetailHero.scheduleShape(hasSchedule: false, isLoading: false, failed: false)
        let approximated = DetailHero.scheduleShape(
            hasSchedule: false, isLoading: false, failed: false, hasOriginalRun: true
        )
        #expect(none != approximated)

        let series = SeriesFactory.make(id: 7, title: "Regressed")
        let key = { (shape: Int) in
            DetailHero.measureKey(series: series, scheduleShape: shape, width: 175, typeSize: .large)
        }
        #expect(key(none) != key(approximated))
    }

    /// `blockState`'s own precedence (estimate > failure > loading >
    /// originalRun > hidden) is mirrored in `scheduleShape`: a live ask or a
    /// settled measurement must never be demoted by an original-run count
    /// arriving alongside it.
    @Test("A real schedule or a live ask outranks originalRun in the shape too")
    func scheduleShapePrecedenceMatchesBlockState() {
        let estimate = DetailHero.scheduleShape(hasSchedule: true, isLoading: false, failed: false)
        #expect(
            DetailHero.scheduleShape(hasSchedule: true, isLoading: false, failed: false, hasOriginalRun: true)
                == estimate
        )
        let loading = DetailHero.scheduleShape(hasSchedule: false, isLoading: true, failed: false)
        #expect(
            DetailHero.scheduleShape(hasSchedule: false, isLoading: true, failed: false, hasOriginalRun: true)
                == loading
        )
    }

    // MARK: P8 — "Started" is a bare year in the column, the range in the footer

    /// Fails on the old code: `stats` put `published.rangeLine` ("c. 2018 –
    /// ongoing") straight into the "Started" segment, which truncated in a
    /// six-column strip at `minimumScaleFactor(0.7)`. The column must now
    /// carry only the leading year.
    @Test("The Started column carries only the year, never the range")
    func startedColumnIsBareYear() {
        let series = Series(
            id: 1, state: "active", mergedWith: nil, titles: nil, cover: .empty,
            description: nil, authors: nil, artists: nil, status: nil, rating: nil, type: nil,
            contentRating: nil, totalChapters: 40, finalVolume: 5, publishers: nil, anime: nil,
            source: nil,
            published: Published(
                startDate: "2018-04-01", endDate: nil,
                startDateIsEstimated: true, endDateIsEstimated: nil
            )
        )
        let strip = DetailStatsStrip(series: series)
        let started = strip.stats.first { $0.label == "Started" }
        #expect(started?.value == "2018", "the column must not carry \"c. \" or an end date")
    }

    /// The full range — the fact an ongoing/estimated range exists to state
    /// at all — must still be shown somewhere: the footer line.
    @Test("The full published range appears on the footer line")
    func publishedRangeIsOnTheFooterLine() {
        let ongoing = Series(
            id: 1, state: "active", mergedWith: nil, titles: nil, cover: .empty,
            description: nil, authors: nil, artists: nil, status: nil, rating: nil, type: nil,
            contentRating: nil, totalChapters: nil, finalVolume: nil, publishers: nil, anime: nil,
            source: nil,
            published: Published(
                startDate: "2020-05-26", endDate: nil,
                startDateIsEstimated: false, endDateIsEstimated: nil
            )
        )
        #expect(DetailStatsStrip(series: ongoing).publishedRangeLine == "2020 – ongoing")

        let noPublished = SeriesFactory.make(id: 2, year: 2015)
        #expect(DetailStatsStrip(series: noPublished, year: 2015).publishedRangeLine == nil)
    }

    // MARK: P13 — the onward rows show a skeleton, never a card, while a
    // .background leg is waiting

    /// The behaviour `DetailPagePriorityTests` could only assert by grepping
    /// `SeriesRepository.swift` for the string `priority: .background`: what
    /// the *page* actually draws while that leg is still out. `List` (a
    /// card) must never be the answer for "no items yet, still loading" —
    /// only `.loading` (a skeleton) is. Fails if `onwardRowState` were
    /// changed to treat "isLoading and no items" as anything but `.loading`
    /// — e.g. the P1 fix accidentally hiding the row instead of skeletoning
    /// it while the tail legs wait at the rate gate.
    @Test("Empty and still loading renders a skeleton, not a list or nothing")
    func onwardRowIsSkeletonWhileLoading() {
        let state = DetailOnwardRows.onwardRowState(items: [], isLoading: true, failure: nil)
        #expect(state == .loading)
        #expect(state != .hidden)
    }

    /// The control: once real items land, the row must show them even if
    /// `isLoading` is still (incorrectly, or momentarily) true elsewhere on
    /// the page — a card always wins over a skeleton once there is
    /// something to show.
    @Test("Items arriving win over isLoading, so a stray loading flag can't strand a skeleton")
    func onwardRowShowsItemsEvenIfStillLoading() {
        let series = [SeriesFactory.make(id: 1, title: "A Series")]
        let state = DetailOnwardRows.onwardRowState(items: series, isLoading: true, failure: nil)
        #expect(state == .list)
    }

    // MARK: P17 — CoverGallery.selection is gone

    /// Fails on the old code: `selection` does not exist any more, so the
    /// dead read `scrolledIndex ?? selection` (always the `scrolledIndex`
    /// half, since `init` seeds both to `startAt`) cannot be there to find.
    @Test("CoverGallery has no separate, dead selection state", .enabled(if: SourceTree.isAvailable))
    func coverGallerySelectionIsGone() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/CoverGallery.swift")
        #expect(!source.contains("var selection"))
        #expect(!source.contains("_selection ="))
    }

    // MARK: P18 — one answer for the native title

    /// Fails on the old code: the byline read a trait-derived guess
    /// (`titles` filtered for `"native"`) that could diverge from the API's
    /// own `native_title` field, which the "Also known as" sheet already
    /// used. Both now read `series.nativeTitle`.
    @Test("The byline's native title is the API field, not a trait-derived guess")
    func bylineUsesTheAPINativeTitleField() {
        // A `titles` array with no "native"-trait entry at all — the old
        // `nativeTitle(of:)` would have found nothing here and dropped the
        // native half of the byline even though the record states one.
        let series = SeriesFactory.make(
            id: 1, title: "Regressed",
            titles: [SeriesTitle(language: "en", traits: ["official"], title: "Regressed", isPrimary: true)],
            authors: ["Author One"]
        )
        let withNativeField = Series(
            id: series.id, state: series.state, mergedWith: nil, titles: series.titles,
            cover: series.cover, description: nil, authors: series.authors, artists: nil,
            status: nil, rating: nil, type: nil, contentRating: nil, totalChapters: nil,
            finalVolume: nil, publishers: nil, anime: nil, source: nil,
            nativeTitle: "리그레스"
        )
        #expect(DetailHero.byline(for: withNativeField) == "리그레스 · Author One")
        // No native_title at all: the author still shows, alone.
        #expect(DetailHero.byline(for: series) == "Author One")
    }

    // MARK: P9 — the gallery no longer strands a page behind AsyncImage

    /// Fails on the old code: `AsyncImage(url:` was the gallery's page
    /// loader, the exact shape `PortraitImage`'s own doc comment names as
    /// the bug — it cancels on scroll-out and remembers `.failure` for the
    /// view's identity, so a page that lost the network race in a fast
    /// swipe stayed the "photo" glyph for the life of the screen. It now
    /// goes through `CoverStore`, the same retry-on-reappear path
    /// `CoverImage`/`PortraitImage` already use.
    @Test("The gallery page loader is CoverStore, not AsyncImage", .enabled(if: SourceTree.isAvailable))
    func galleryPagesUseCoverStore() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/CoverGallery.swift")
        #expect(!source.contains("AsyncImage(url:"))
        #expect(source.contains("CoverStore.shared.image(for: url)"))
        #expect(source.contains("CoverStore.shared.cached(url)"))
    }

    // MARK: P12 — the publisher-page link reaches 44pt

    @Test("The publisher-page button carries a real tap target", .enabled(if: SourceTree.isAvailable))
    func publisherPageHasATapTarget() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailEditions.swift")
        #expect(source.contains("Text(\"Publisher page\")"))
        // Only one `.tapTarget()` in the file today, and it belongs to this
        // button — see the comment above it in source.
        #expect(source.contains(".tapTarget()"))
    }
}
