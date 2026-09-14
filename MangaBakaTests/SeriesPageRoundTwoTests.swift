import Foundation
import SwiftUI
import Testing
@testable import MangaBaka

/// Round 2, lane E — the series page. One suite per finding, each naming the
/// item it belongs to.
///
/// Several of these are source-text pins rather than behavioural tests, and
/// say so. The project has no ViewInspector, so a rule that lives only in a
/// SwiftUI `body` — which `@State` a view reads, which stack a row uses,
/// which closure a retry button calls — cannot be driven from a test at all.
/// A source pin is weaker than an assertion on a value and is used only where
/// there is no value to assert on; every finding with a pure function behind
/// it gets a real test instead.

/// Item 25: `/images` failing was recorded in `coversFailure` and read
/// nowhere. A throttled reader saw a series with no cover fan, pixel-identical
/// to one that genuinely has no extra covers, and no line on the page said so.
@Suite("A failed cover fetch reaches the page's stale bar")
struct DetailCoversFailureTests {
    /// Expected to fail before the fix with a compile error — `pageFailure`
    /// had three parameters and no `coversFailure:` at all, which is the
    /// whole finding: the value existed and nothing could read it.
    @Test("A covers failure alone is the page failure")
    func coversFailureSurfaces() {
        #expect(
            SeriesDetailView.pageFailure(
                extras: SeriesExtras(), similarOrigin: .network, alsoOrigin: .network,
                coversFailure: .offline
            ) == .offline
        )
    }

    @Test("extras.failure still wins over it")
    func extrasWins() {
        var extras = SeriesExtras()
        extras.failure = .rateLimited(until: nil)
        #expect(
            SeriesDetailView.pageFailure(
                extras: extras, similarOrigin: .network, alsoOrigin: .network,
                coversFailure: .offline
            ) == .rateLimited(until: nil)
        )
    }

    /// A stale feed is the weakest of the four legs: a cached answer is still
    /// an answer, where a failed `/images` is not.
    @Test("A covers failure outranks a merely stale feed")
    func coversOutranksStale() {
        #expect(
            SeriesDetailView.pageFailure(
                extras: SeriesExtras(), similarOrigin: .staleAfter(.server(status: 503, message: "")),
                alsoOrigin: .network, coversFailure: .offline
            ) == .offline
        )
    }
}

/// Item 57: the Open Library gap-fill pass used to commit every cover it found
/// only after the last ISBN answered, in dictionary order, uncapped — so a
/// 40-volume series with no publisher art shimmered every spine for two
/// minutes (40 x `OpenLibraryCovers.minimumInterval`), found nothing, and
/// committed nothing at all if the reader popped the page.
@Suite("Open Library answers land per volume, not per pass")
struct OpenLibraryProgressTests {
    /// Expected to fail before the fix: `OpenLibraryProgress` did not exist —
    /// the state was one `MissingVolumeCover.SourceState` for the whole
    /// section, so no volume could be answered while another was still out.
    @Test("A volume that has answered is answered while its neighbours are out")
    func perVolume() {
        var progress = OpenLibraryProgress(pass: .loading)
        progress.byNumber[1] = .answered
        progress.byNumber[2] = .loading
        #expect(progress.state(for: 1) == .answered)
        #expect(progress.state(for: 2) == .loading)
    }

    /// The caption is the reason this state exists at all, so the two are
    /// tested together: an answered volume may be told nobody has a cover, a
    /// volume still out may not.
    @Test("Only an answered volume is told there is no cover")
    func captionFollowsTheVolume() {
        var progress = OpenLibraryProgress(pass: .loading)
        progress.byNumber[1] = .answered
        progress.byNumber[2] = .loading
        #expect(
            MissingVolumeCover.caption(apple: .answered, openLibrary: progress.state(for: 1)) != nil
        )
        #expect(
            MissingVolumeCover.caption(apple: .answered, openLibrary: progress.state(for: 2)) == nil
        )
    }

    /// A volume with no number of its own ("Other editions") has nothing to
    /// key on, and a volume with no ISBN was never in `byNumber` — both take
    /// the pass's own state, which is as settled as they will get.
    @Test("An unkeyed volume falls back to the pass")
    func fallsBackToThePass() {
        let progress = OpenLibraryProgress(pass: .answered)
        #expect(progress.state(for: nil) == .answered)
        #expect(progress.state(for: 99) == .answered)
    }

    /// The cap is the point: past it nothing is asked, so nothing may be
    /// claimed. `notAsked` is written explicitly for the tail rather than left
    /// to fall through to `pass`, which ends the run as `.answered`.
    @Test("Past the cap a volume stays unasked even once the pass is done")
    func tailIsNotClaimed() {
        var progress = OpenLibraryProgress(pass: .answered)
        progress.byNumber[40] = .notAsked
        #expect(progress.state(for: 40) == .notAsked)
        #expect(
            MissingVolumeCover.caption(apple: .answered, openLibrary: progress.state(for: 40)) == nil
        )
    }

    @Test("The cap is twelve, and is labelled a guess in the source", .enabled(if: SourceTree.isAvailable))
    @MainActor
    func capIsTwelve() throws {
        #expect(SeriesDetailView.openLibraryPassLimit == 12)
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        #expect(source.contains("A GUESS. Open Library is spaced"))
    }
}

/// The offline half of item 57's sibling: an unreachable source is not an
/// answer. "No cover from the publisher" is a claim about the publisher, and
/// telling it to a reader whose request never left the phone is simply false.
///
/// **Not yet reachable in production.** `OpenLibraryCovers.coverURL` still
/// answers `URL?`, which collapses "404, nobody has one" and "the request
/// failed" into the same nil, so nothing sets `.unreachable` yet — the
/// three-valued client is one edit in `Core/Volumes/OpenLibraryCovers.swift`,
/// named in this round's report. The rule is pinned here so the wiring has
/// something to satisfy.
@Suite("An unreachable source is not an answer")
struct MissingVolumeCoverUnreachableTests {
    @Test("Unreachable says nothing, the way loading and unasked do")
    func unreachableIsSilent() {
        #expect(MissingVolumeCover.caption(apple: .answered, openLibrary: .unreachable) == nil)
        #expect(
            MissingVolumeCover.accessibilityText(apple: .answered, openLibrary: .unreachable)
                == "cover not available"
        )
    }

    @Test("An answered source still says it")
    func answeredStillSpeaks() {
        #expect(MissingVolumeCover.caption(apple: .answered, openLibrary: .answered) != nil)
    }
}

/// Items 26, 40, 54, 55, 56, 58, 121 and 122 — the rules that live in a
/// SwiftUI `body` or in a `@State` declaration, where there is no value to
/// assert on. Pinned as source text, which is what this project already does
/// for the same reason (`AppleBooksTests.replaces`, `SourceTree`).
/// Gated: every test below reaches the checkout through `detail(_:)`, which
/// `SourceTestGuardTests` cannot see through — the guard looks for
/// `SourceTree.read` in the test's own text and a helper hides it. Ungated
/// these pass on a Mac and fail on a build machine, the shape that cost
/// builds 16 and 21.
@Suite("Series page rules with nowhere else to live", .enabled(if: SourceTree.isAvailable))
struct SeriesPageSourceRuleTests {
    private func detail(_ file: String) throws -> String {
        try SourceTree.read("MangaBaka/Features/Detail/\(file)")
    }

    /// Item 26: the page-level `StaleBar` names a MangaBaka-side failure, and
    /// its retry used to re-run the whole `load()` — cast, cadence, Apple,
    /// Google, Open Library, the release feeds and the categories, up to nine
    /// third-party requests, several behind 3 s spacers, for a failure none of
    /// them caused.
    @Test("The stale bar retries only the page's own load")
    func staleBarRetriesCoreOnly() throws {
        let source = try detail("SeriesDetailView.swift")
        #expect(source.contains("retry: { await loadCore() }"))
        #expect(!source.contains("retry: { await load() }"))
    }

    /// Item 40: `ReleaseScheduleService.cadence(for:)` returns
    /// `.failed(.cancelled)` deliberately, so the one caller that can tell a
    /// live page from a dead one decides. A live page has nothing to say about
    /// a request nobody is waiting for — `APIError.cancelled` must never be an
    /// `InlineFailure` reading "cancelled".
    @Test("A cancelled cadence ask is not written on screen as a failure")
    func cancelledCadenceIsSilent() throws {
        #expect(try detail("SeriesDetailView+Releases.swift").contains("case .failed(.cancelled):"))
    }

    /// Item 54: the offset was `@State` on the page root, written every scroll
    /// frame, so a Markdown parse, `TagGrouping.groups` over up to 146 tags,
    /// two cover sorts and ~11 `Series.filling` copies re-ran inside an 8.3 ms
    /// budget at 120 Hz. Its readers are the backdrop and the bar title.
    @Test("Scroll offset is held in a tracker, not in the page's own State")
    func scrollOffsetIsNotPageState() throws {
        let source = try detail("SeriesDetailView.swift")
        #expect(source.contains("@State private var scroll = ScrollTracker()"))
        #expect(!source.contains("@State private var scrollOffset"))
        // The three per-frame computations it used to force, now cached.
        #expect(source.contains("private func refreshDerived()"))
        #expect(source.contains("var shown: Series { filled ?? series }"))
        #expect(source.contains("groups: tagGroups,"))
        // One scroll observer on the ScrollView, not a second one inside the
        // bar-title modifier reporting the same number.
        #expect(!(try detail("DetailBarTitle.swift").contains(".onScrollGeometryChange(")))
    }

    /// Item 55: `height` was declared, documented ("blurring a full-page image
    /// costs more the taller it is") and never read, so a 72 pt Gaussian ran
    /// over the whole scroll view on a 1.6x-scaled layer and was re-offset
    /// every frame. The doc and the code now agree.
    @Test("The backdrop applies its own height, and moves a flattened bitmap")
    func backdropAppliesHeight() throws {
        let source = try detail("DetailBackdrop.swift")
        #expect(source.contains("let washHeight = min(height, proxy.size.height)"))
        #expect(source.contains("height: washHeight, alignment: .top"))
        // Flattened before `.offset`, so the parallax moves one finished
        // bitmap rather than re-running blur, saturation and gradient.
        #expect(source.contains(".compositingGroup()\n            .offset(y: Self.parallaxOffset"))
    }

    /// Item 56: `position` started nil and was assigned in `onAppear`, so
    /// `items[0]`'s `SeriesDetailView.task` fired its nine-request `loadCore`
    /// at `userInitiated` for a series the reader never opened.
    @Test("The pager opens on the tapped series, not on the row's first one")
    func pagerSeedsInInit() throws {
        let source = try detail("SeriesPager.swift")
        #expect(source.contains("_position = State(initialValue: selected.id)"))
        #expect(!source.contains(".onAppear { position = selected.id }"))
    }

    /// Item 58: an eager `HStack` starts a `CoverStore` fetch for every card
    /// in the first frame, and `CoverStore` deliberately never cancels — for a
    /// 20-name cast, three ~20-card rows and a 30-volume shelf that is ~110
    /// CDN requests in the first second, all of which outlive a pop.
    @Test("Every horizontal cover row on the page is lazy")
    func rowsAreLazy() throws {
        // `HStack(alignment: .top, spacing: Metrics.gapCovers)` is the shape
        // all five cover rows share, and "LazyHStack(…" contains it — so
        // every occurrence being a lazy one is exactly "no eager row left".
        let row = "HStack(alignment: .top, spacing: Metrics.gapCovers)"
        for file in ["VolumesSection.swift", "CharacterRow.swift", "DetailOnwardRows.swift"] {
            let source = try detail(file)
            let rows = source.components(separatedBy: row).count - 1
            let lazyRows = source.components(separatedBy: "Lazy" + row).count - 1
            #expect(rows > 0, "\(file) has no cover row to check")
            #expect(rows == lazyRows, "\(file) still has an eager cover row")
        }
    }

    /// Item 121: `AsyncImage` cancels on scroll-out and remembers the failure
    /// per view identity — the two behaviours `CoverStore` was written to fix.
    /// A portrait that lost that race stayed a grey square until the sheet was
    /// dismissed.
    @Test("No portrait on the series page is still an AsyncImage")
    func portraitsUseTheCoverStore() throws {
        for file in ["CharacterRow.swift", "CharacterProfileView.swift"] {
            #expect(!(try detail(file).contains("AsyncImage(url:")), "\(file) still uses AsyncImage")
        }
        #expect(try detail("PortraitImage.swift").contains("CoverStore.shared.image(for: url)"))
    }

    /// Item 122: `zoomRoute.neighbours` was never cleared and a push from
    /// inside a page set `source` only, so tapping a related series that
    /// happened to also be in the originating row wrapped it in *that* row's
    /// pager and swiping stepped through the wrong list.
    @Test("A push from an onward row carries that row's own neighbours")
    func onwardPushesResetNeighbours() throws {
        let source = try detail("DetailOnwardRows.swift")
        #expect(source.components(separatedBy: "zoomRoute?.source =").count == 4)
        #expect(source.components(separatedBy: "zoomRoute?.neighbours =").count == 4)
    }

    /// Item 120: `pages` was computed, read inside
    /// `ForEach(Array(pages.enumerated()))` and again by `backdrop`, which
    /// re-runs on every frame of a drag. Both its inputs are `init` arguments.
    @Test("The gallery's page list is built once, in init")
    func galleryPagesAreStored() throws {
        let source = try detail("CoverGallery.swift")
        #expect(source.contains("private let pages: [(caption: String?, cover: Cover)]"))
    }

    /// Item 120: the hero laid out four full columns — three off-screen
    /// measurers, each carrying its own `.sheet` presenter — on every pass, to
    /// read three numbers that only change when the series, the width or the
    /// type size does.
    @Test("The hero measures once per series, width and type size")
    func heroMeasuresOnce() throws {
        let source = try detail("DetailHero.swift")
        #expect(source.contains("if columnWidth > 0, measuredFor != key {"))
    }

    /// Item 76: the paragraph telling a future agent to add
    /// `OfflineCatalogue.titles(for:)` outlived the method landing.
    @Test("The stale Requires paragraph is gone")
    func staleRequiresParagraphIsGone() throws {
        #expect(!(try detail("SeriesDetailView+Store.swift").contains("**Requires `func titles")))
    }

    /// Item 120: both are file-backed actors — `EmbeddingIndex` loads 7.3 MB —
    /// and a defaulted parameter meant a caller that forgot one silently
    /// allocated a second copy per series page.
    @Test("The two file-backed actors are not defaulted")
    func fileBackedActorsAreInjected() throws {
        let source = try detail("SeriesDetailView.swift")
        #expect(source.contains("var embeddingIndex: EmbeddingIndex\n"))
        #expect(source.contains("var offlineCatalogue: OfflineCatalogue\n"))
    }
}

/// Item 123: `selected` was a `@Binding` whose one call site passed
/// `.constant(series)`, so `selected = match` wrote into a constant, every
/// settle was silently dropped, and `recentlyViewed` only ever recorded the
/// series that was pushed — never one swiped to.
///
/// This was a pair of source pins, one of them a negative pin on the string
/// "@Binding var selected: Series". The doc comment written to explain the
/// fix quotes that very string, so the pin tripped on its own explanation.
/// Behaviour instead: the caller's closure is stored and reaches the caller.
/// `onSettle` is what `SeriesPager.onChange(of: position)` calls; that the
/// call site passes one is asserted in `RootViewSessionTests` below.
@Suite("A settle is an event the caller handles")
@MainActor
struct SeriesPagerSettleTests {
    @Test("The pager hands a settled series back to whoever pushed it")
    func settleReachesTheCaller() throws {
        let first = SeriesFactory.make(id: 1, title: "One")
        let second = SeriesFactory.make(id: 2, title: "Two")
        let recorded = Recorder()

        let pager = SeriesPager(items: [first, second], selected: first) { settled in
            recorded.ids.append(settled.id)
        } content: { _ in
            EmptyView()
        }

        let onSettle = try #require(pager.onSettle, "a caller's closure must be stored, not dropped")
        onSettle(second)
        #expect(recorded.ids == [2], "the settled series, not the one the push named")
    }

    /// The default exists so the single-neighbour call sites keep compiling
    /// unchanged; it must be absence, not a closure that quietly does nothing.
    @Test("A caller that does not care passes nothing")
    func noCallerNoClosure() {
        let only = SeriesFactory.make(id: 1, title: "One")
        let pager = SeriesPager(items: [only], selected: only) { _ in EmptyView() }
        #expect(pager.onSettle == nil)
    }

    /// `@unchecked Sendable` because `SeriesPager.onSettle` is a plain
    /// `(Series) -> Void` with no isolation, so a `@MainActor` box could not
    /// be captured by it. Nothing here is concurrent: the test calls the
    /// closure itself, on one thread.
    private final class Recorder: @unchecked Sendable {
        var ids: [Int] = []
    }
}

/// The other half of item 123: a stored closure nobody passes records nothing.
@Suite("The series page wires the settle to recently-viewed", .enabled(if: SourceTree.isAvailable))
struct RootViewSessionTests {
    @Test("The shell hands SeriesPager an onSettle that records")
    func shellPassesOnSettle() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        #expect(SourceTree.containsRun(source, "onSettle: { current in"))
        #expect(SourceTree.containsRun(source, "await session.recentlyViewed.record(current)"))
        // No negative pin on the old `selected: .constant(...)` spelling: the
        // comment right above that call explains the fix by quoting it, which
        // is exactly how the pin this suite replaces broke. That the pager has
        // no binding at all is covered by `SeriesPagerSettleTests`, where it
        // is a fact about the type rather than about the file's prose.
    }
}
