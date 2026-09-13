import SwiftUI

/// Search: the system field on the search tab, scopes for type, tokens for
/// the picked tags/genres/publisher, and the rest of the filters in a sheet.
///
/// The field is `.searchable` on a navigation bar, since 2026-09-13 (UX#6).
/// It was a `TextField` in a rounded box inside the scroll view, with a
/// hand-built clear button, because the four tab roots drew no navigation
/// bar (`ScrollEdge`). Search is the one tab iOS 26 redesigned around
/// (`Tab(role: .search)`, `RootView`): with the system field, tapping the
/// tab morphs the bar into the field, a picked tag is a token the reader can
/// see and remove, Recent is a suggestion list that vanishes on the first
/// keystroke, and Cancel restores the idle panel — none of which the
/// hand-rolled field had, and the field itself no longer scrolls away under
/// the results (R F5).
struct SearchView: View {
    @Bindable var model: SearchModel
    @Binding var path: [Series]
    // Not `private`: `resultsGrid` reaches this from `SearchEmptyState.swift`
    // (moved there for the lint's type-length ceiling, alongside the empty
    // state it sits next to), and `private` is file-scoped in Swift.
    @Environment(\.zoomRoute) var zoomRoute
    @Environment(ToastCentre.self) var toasts: ToastCentre?
    /// Opens the genre and tag browser.
    let onBrowse: () -> Void
    let lenses: SearchLensStore
    let counts: LensCounts
    let catalogue: CatalogueService
    let recents: RecentSearches
    /// Where a result's "Save" and "Mark read" write (R F3). Nil where a
    /// caller has no library to offer, and the menu shows only "Open".
    var library: (any LibraryProviding)?

    @State private var isNamingLens = false
    @State private var showFilters = false
    /// The system field's presented state. Bound so Cancel can be seen:
    /// the platform empties the text itself, and the model drops the
    /// tokens with it and returns to idle (`SearchModel.cancelSearch`).
    @State private var isSearchPresented = false
    /// Reset to the top on every new answer generation (R F5): a long grid
    /// followed by a short one left the offset wherever the clamp put it.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                // A heading and two links. Kept on one row until they no
                // longer fit: squeezed by both links, "30 results" broke into
                // "30" / "result" / "s" at the largest text size.
                //
                // The heading is absent while the screen is idle: the idle
                // screen carries its own section headers, and a standing
                // "Saved lenses" title sat above a Presets section even when
                // the reader had saved none — announcing a thing that was not
                // there.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if model.hasAsked { headingText }
                        Spacer(minLength: 0)
                        headerActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if model.hasAsked { headingText }
                        headerActions
                    }
                }
                .padding(.horizontal, Metrics.gutter + 2)

                content
                    // Typing swaps skeleton/results/empty/failure for one
                    // another; blur-replacing them inside one spring means a
                    // new query never flashes to a blank screen between the
                    // two — see `ContentKind`.
                    .animation(Motion.reduced(Motion.settle), value: contentKind)
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scrollPosition)
        .background(Palette.ground)
        // No `.scrollEdge()`: the navigation bar draws the edge itself, which
        // is what that modifier stands in for on the three bar-less tabs.
        .navigationTitle("Search")
        .modifier(SearchField(
            model: model, recents: recents, isPresented: $isSearchPresented
        ))
        .onChange(of: model.query.text) { _, _ in model.queryDidChange() }
        .onChange(of: model.generation) { _, _ in
            scrollPosition.scrollTo(edge: .top)
        }
        // The end of the results, felt — and, since R F10, also said, by the
        // "That's all N" line under the grid. Not while a new search is
        // resetting `hasMore` for its own first page, and not when the walk
        // gave up early: that line says "more may exist", and a haptic
        // saying "that's all" under it would lie.
        .sensoryFeedback(Haptics.settled, trigger: model.hasMore) { old, new in
            old && !new && !model.results.isEmpty && !model.isSearching && !model.stoppedEarly
        }
        .sheet(isPresented: $isNamingLens) {
            SaveLensSheet(query: model.query) { name in
                // Saving used to close the sheet with nothing confirming it
                // landed (gap 55) — the reader had no way to tell "saved"
                // from "the tap missed". `save` reports whether it actually
                // did (it refuses an empty query or name), so the toast says
                // which — matching the house wording for a one-word write
                // confirmation (`RootView+Session.swift:291`,
                // `LibraryEditSheet.swift:266`).
                if lenses.save(name: name, query: model.query) {
                    toasts?.show("Lens saved")
                    // A lens saved while the idle screen's own count walk is
                    // still running used to be dropped rather than queued
                    // behind it (gap 53) — asking again here enqueues it, and
                    // `LensCounts.load` now drains a shared queue rather than
                    // a fixed snapshot, so it is picked up before the walk
                    // ends rather than only on the idle screen's next
                    // appearance.
                    counts.load(lenses.own)
                } else {
                    toasts?.show("Couldn't save that lens", kind: .failure)
                }
            }
            .presentationDetents([.height(420)])
            .presentationCornerRadius(Metrics.radiusSheet)
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet(
                query: $model.query,
                onApply: {
                    Task { model.cancelPendingDebounce(); await model.search() }
                },
                onSaveLens: { isNamingLens = true },
                catalogue: catalogue,
                preferOffline: $model.preferOffline,
                previewCount: previewCount,
                offlineCount: model.offlineCount
            )
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(Metrics.radiusSheet)
        }
    }

    @ViewBuilder
    private var headingText: some View {
        // Nil while a new search is in flight, so a heading over the
        // incoming skeleton cannot claim the previous query's count (gap 50:
        // "SearchView.swift:194" used to hold "12 shown" above a grid that
        // was about to show something else entirely).
        if let heading {
            Text(heading)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .countsNotCuts()
                .animation(Motion.reduced(Motion.snappy), value: heading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Two actions of different weight, drawn differently, and the door to
    /// the rest of the filters once results are up.
    ///
    /// Browse and Surprise me were three same-weight accent links — with the
    /// recents "Clear" below — which told the reader nothing about which one
    /// to reach for. Browse opens a whole other surface and is the one worth
    /// finding, so it takes a chip; "Surprise me" reorders the results you
    /// already have and stays a plain link. Every control here hits at
    /// `Metrics.tapTarget`: the pills are drawn at `headerPill` and were
    /// 30pt targets, fourteen under the platform minimum (R F8).
    private var headerActions: some View {
        HStack(spacing: 12) {
            Button(action: onBrowse) {
                Text("Browse")
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 13)
                    .frame(minHeight: Metrics.headerPill)
                    .background(Palette.accentTint, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.4), lineWidth: 0.5))
                    .tapTarget()
            }
            .buttonStyle(.press)
            SurpriseMeButton(isSearching: isWorking) {
                Task { await model.surpriseMe() }
            }
            // Redundant while the idle page shows the same panel inline
            // (Abdi, 2026-09-13); it returns once results are on screen.
            if contentKind != .idle {
                Button {
                    showFilters = true
                } label: {
                    // The badge is the only sign, on this screen, that a
                    // status or rating from the panel is still narrowing
                    // the grid (LW §1: "Manga silently survives") — a type
                    // shows in the scope bar and a tag in the field, but
                    // the panel's own filters show nowhere else.
                    HStack(spacing: 6) {
                        Text("Filters")
                            .typeInstruction()
                            .foregroundStyle(Palette.textPrimary)
                        FilterCountBadge(query: model.query)
                    }
                    .padding(.horizontal, 13)
                    .frame(minHeight: Metrics.headerPill)
                    .background(Palette.surfaceChip, in: Capsule())
                    .tapTarget()
                }
                .buttonStyle(.press)
                .transition(.blurReplace)
            }
        }
        .fixedSize()
    }

    /// "411 results · Score" once anything is asked for, nil before that and
    /// while a new search is in flight.
    private var heading: String? {
        SearchHeading.text(
            hasAsked: model.hasAsked,
            isSearching: isWorking,
            shown: model.results.count,
            total: model.total,
            sortLabel: SortOrder.label(for: model.query.sort)
        )
    }

    // `ContentKind`, its pure decision function, and the computed property
    // that reads it off `model` all live in `SearchEmptyState.swift` — moved
    // there for the lint's type-length ceiling on this file, next to the
    // other `SearchView` logic already split out for the same reason.

    @ViewBuilder
    private var content: some View {
        switch contentKind {
        case .idle:
            SearchIdleView(
                lenses: lenses,
                counts: counts,
                query: $model.query,
                catalogue: catalogue,
                preferOffline: $model.preferOffline,
                onRun: { lens in
                    Task { await model.apply(lens.query) }
                },
                onSaveLens: { isNamingLens = true },
                onShowResults: {
                    recents.record(model.query.text ?? "")
                    Task { model.cancelPendingDebounce(); await model.search() }
                },
                previewCount: previewCount,
                offlineCount: model.offlineCount
            )
        case .skeleton:
            // The shape of the answer, not a spinner: the grid the results
            // will fill, shimmering, so nothing jumps when they land.
            CoverSkeletonGrid()
                .transition(.blurReplace)
        case .failure:
            // Nothing to show and the ask failed outright — a full failure
            // screen (gap 7). Search is the one screen decision 4 names for
            // an automatic retry: it is the one place the reader is sitting
            // there waiting on exactly this answer, unlike a background row
            // elsewhere that ticks without retrying itself.
            if let failure = model.failure {
                FailureState(
                    error: failure,
                    retry: { await model.search() },
                    autoRetry: true
                )
                .transition(.blurReplace)
            }
        case .empty:
            emptyState
                .transition(.blurReplace)
        case .results:
            grid
                .opacity(isWorking ? Self.dimmedWhileWorking : 1)
                .animation(Motion.reduced(Motion.snappy), value: isWorking)
                .transition(.blurReplace)
        }
    }

    // Internal, not private: the empty state lives in its own file for the
    // lint's ceiling. See SearchEmptyState.swift.
    var displayedQuery: String {
        let text = (model.query.text ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "these filters" : "\u{201C}\(text)\u{201D}"
    }
}

// The results grid and its helpers, in an extension of the same file for
// the lint's type-length ceiling — `private` is file-scoped, so nothing
// widens.
private extension SearchView {
    /// A request out, or a debounce about to send one.
    var isWorking: Bool { model.isSearching || model.isPending }

    /// The "Show N results" label's number. The model answers for the query
    /// it just searched — the sheet opened over results used to spend a
    /// `limit=1` request asking for a total the search response had
    /// already carried (E F1). Anything else is one background-priority
    /// count through `LensCounts`.
    func previewCount(_ query: SearchQuery) async -> Int? {
        if let known = model.knownTotal(for: query) { return known }
        return await counts.count(query)
    }

    /// Kept on screen while the next answer is on its way, at this opacity
    /// — a guess at "clearly busy, still readable"; the skeleton only ever
    /// replaces an empty grid now (R F1).
    static let dimmedWhileWorking = 0.55

    var grid: some View {
        VStack(spacing: 0) {
            // A failure that still has content to show is not a blocking
            // failure — the last good results stay on screen, under a bar
            // naming why they might be stale, rather than the grid vanishing
            // out from under the reader on every throttled keystroke (gap 7).
            Group {
                if let failure = model.failure {
                    // With a deadline the bar counts down itself and names
                    // the query the grid still shows, so it is never
                    // anonymous under a 429 (R F9).
                    StaleBar(
                        headline: failure.headline,
                        detail: failure.rateLimitDeadline == nil
                            ? failure.userFacingMessage
                            : StaleBar.stillShowing(displayedQuery),
                        deadline: failure.rateLimitDeadline,
                        retry: { await model.search() }
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if case let .offlineIndex(builtDate) = model.origin {
                    // No retry closure: retrying is what the reader already
                    // did by switching "Browse offline" off, or what
                    // happens on its own the next time a search succeeds
                    // against the network.
                    StaleBar(
                        headline: "From the offline index (built \(OfflineIndexDateLabel.short(builtDate)))",
                        detail: "Top 20,000 series, covers load when you're back."
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Motion.reduced(Motion.settle), value: model.failure)
            resultsGrid
            if model.isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let pageFailure = model.pageFailure {
                // A page-2+ request that failed outright used to read as the
                // end of the results (gap 15) — this says otherwise and
                // offers to try that same page again.
                InlineFailure(error: pageFailure) { await model.loadMore() }
                    .padding(.vertical, 16)
            } else if model.stoppedEarly {
                // Gave up after too many filtered-empty pages in a row —
                // not the same as reaching the real end (gap 51), and looked
                // identical to it until now.
                Text("Stopped early — more of this may exist further in.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else if !model.hasMore, !isWorking {
                // The real end, said rather than only felt: the haptic above
                // is nothing to a reader with haptics off or on VoiceOver,
                // and "page 2 quietly never came" looked the same (R F10).
                Text("That's all \(model.results.count)")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
    }
}

/// The rule behind `SearchView.heading`, pulled out of the view entirely so it
/// is testable without a live `SearchView` (this project has no
/// ViewInspector) — gap 50.
enum SearchHeading {
    /// "N results" from the API's own total; "N shown" only when the answer
    /// carried none (the offline index). "shown" used to be the only form,
    /// covering for the total being decoded and thrown away (E F1, R F13) —
    /// "24 results" then "47 results" as the reader scrolled was the same
    /// query reporting different totals, so the loaded count was never
    /// called "results". Nil until something is asked (a filter chosen on
    /// the idle panel is not an ask, and "0 shown" sat over it — UX#13),
    /// nil over the empty state for the same reason, and nil while
    /// `isSearching`: the count on screen at that instant still describes
    /// the query the reader just left, not the one about to answer.
    static func text(
        hasAsked: Bool, isSearching: Bool, shown: Int, total: Int?, sortLabel: String?
    ) -> String? {
        guard hasAsked, !isSearching, shown > 0 else { return nil }
        let text = total.map { "\($0.formatted()) results" } ?? "\(shown) shown"
        guard let sortLabel else { return text }
        return "\(text) · \(sortLabel)"
    }
}

/// "2026-09-13" to "13 Sep", for the offline-index `StaleBar` line. Its own
/// enum, not a private method on `SearchView`, for the same reason
/// `SearchHeading` is: this project has no ViewInspector, so a view-only
/// function cannot be driven from a test at all.
enum OfflineIndexDateLabel {
    /// Falls back to the raw string when it does not parse as `yyyy-MM-dd` —
    /// an unparsed date on screen is still more useful than none at all.
    static func short(_ isoDate: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: isoDate) else { return isoDate }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// "Surprise me" reads as live even while disabled during a search (gap 52).
///
/// Its own small view, rather than a plain `Button` inline, because the text
/// deliberately sets its own colour (`Palette.textSecondary`, to sit a step
/// quieter than "Browse") — and `PressStyle`'s own disabled colour, set on
/// `configuration.label` from the outside, is overridden by a label's own
/// more specific `.foregroundStyle` further in (see `PressStyle`'s doc
/// comment). A label with no opinion dims automatically; one with an opinion,
/// like this one, has to read `isEnabled` itself.
private struct SurpriseMeButton: View {
    let isSearching: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    private var isActuallyEnabled: Bool { isEnabled && !isSearching }

    var body: some View {
        Button(action: action) {
            Text("Surprise me")
                .typeInstruction()
                .foregroundStyle(isActuallyEnabled ? Palette.textSecondary : Palette.textQuaternary)
                .tapTarget()
        }
        .buttonStyle(.press)
        .disabled(!isActuallyEnabled)
    }
}
