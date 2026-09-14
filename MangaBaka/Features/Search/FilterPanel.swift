import SwiftUI

/// Type, status, sort, year, rating and offline filters, plus the way in to
/// tags, genres and publishers — the controls `FilterSheet` used to own
/// outright.
///
/// Pulled into its own view on 2026-09-13 so the same controls can sit
/// inline on Search's idle screen (Abdi: "I like the Filter sheet... keep
/// that on the main search page") as well as in the sheet reached from
/// "Filters" mid-search. One view, two hosts — `FilterSheet` now wraps this
/// in a sheet's chrome and nothing else.
///
/// **Tags, genres and publishers are a row of three buttons, not laid out.**
/// The idle screen used to embed the full tag row (`FilterSheet`'s old
/// `tagRow`) and, before this pass, three hard-coded preset lenses above it —
/// laying out every tag, every preset and the publisher line on the one
/// screen meant to make searching feel simple. A reader who wants to browse
/// by genre or tag can still get there in one tap; they no longer see the
/// whole vocabulary before they have typed anything.
struct FilterPanel: View {
    @Binding var query: SearchQuery
    /// Saving a lens happens here, in the panel that owns filters, so every
    /// host gets it without it being designed twice. Absent where a caller
    /// has nowhere to put a lens.
    var onSaveLens: (() -> Void)?
    /// The tag and genre catalogue. Absent where a caller has none to offer,
    /// in which case the Tags/Genres/Publishers row is not drawn at all.
    var catalogue: CatalogueService?
    /// "Browse offline" — answer from the bundled index and send zero
    /// requests. Absent where a caller has nowhere to read or set it.
    var preferOffline: Binding<Bool>?
    /// A live count for the "Show results" button's label, e.g. "Show 1,284
    /// results". Absent disables the count preview but not the button itself
    /// — `canShow(query:)` alone gates whether it can be tapped.
    var previewCount: ((SearchQuery) async -> Int?)?
    /// The same count answered from the bundled index, for when "Browse
    /// offline" is on. Absent means no count at all in that mode — never a
    /// fallback to `previewCount`, because the toggle's own copy promises
    /// "no requests" and a preview nobody asked for was still one request
    /// per settled chip (review 2026-09-13, UX#2). See `countSource(...)`.
    var offlineCount: ((SearchQuery) async -> Int?)?
    /// Runs the one request "Show results" stands for. Never fired by a chip
    /// or a picker on its own — see `canShow(query:)`'s doc comment.
    let onShowResults: () -> Void
    /// What the count debounce sleeps against. Injected so a test can move
    /// time rather than sleep through it (item 129). A defaulted stored
    /// property, so every existing call site is unchanged.
    ///
    /// Spelled with its module because this one does not: `MangaBaka` has its
    /// own `Clock` protocol (`Core/Persistence/Clock.swift`, a source of
    /// "now" for cache expiry), and an unqualified `Clock` resolves to that.
    var clock: any _Concurrency.Clock<Duration> = ContinuousClock()

    @State private var isPickingTags = false
    @State private var isPickingGenres = false
    @State private var isPickingPublisher = false
    @State private var genres: [Genre] = []
    @State private var resultCount: Int?
    @State private var countTask: Task<Void, Never>?
    /// The filters "Clear all" threw away, kept so they can be put back.
    @State private var cleared: SearchQuery?

    /// How long the panel waits after the last filter change before asking
    /// for a count. A guess: 350 ms arrived as a literal in 0e7d068
    /// (2026-09-10) with no derivation, and sits 50 ms above `SearchModel`'s
    /// typed debounce for no stated reason (review 2026-09-13, E F10/E
    /// F12/T#8). Not changed here — a different guess is still a guess.
    /// Named so a test can read it and so it is one number, not a literal.
    /// A preview is not latency-sensitive; since the count now goes out at
    /// `.background` (`LensCounts.count`) the value gates how often a
    /// slot is *queued*, not whether a reader can still search.
    nonisolated static let countDebounce = Duration.milliseconds(350)

    /// See `countSource(query:preferOffline:hasNetworkCounter:hasOfflineCounter:)`.
    enum CountSource: Equatable { case none, offline, network }

    private let types = ["manga", "novel", "manhwa", "manhua", "oel", "other"]
    private let statuses = ["releasing", "completed", "hiatus", "cancelled", "upcoming"]
    private let sorts = SortOrder.all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Type") {
                FlowLayout {
                    ForEach(types, id: \.self) { type in
                        chip(type, isOn: query.types.contains(type)) { toggle(&query.types, type) }
                    }
                }
            }
            .arrives(index: 0)

            section("Status") {
                FlowLayout {
                    ForEach(statuses, id: \.self) { status in
                        chip(status, isOn: query.statuses.contains(status)) {
                            toggle(&query.statuses, status)
                        }
                    }
                }
            }
            .arrives(index: 1)

            section("Sort") {
                FlowLayout {
                    ForEach(sorts, id: \.value) { sort in
                        chip(sort.label, isOn: query.sort == sort.value) {
                            query.sort = query.sort == sort.value ? nil : sort.value
                        }
                    }
                }
            }
            .arrives(index: 2)

            ratingSection
                .arrives(index: 3)

            yearSection
                .arrives(index: 4)

            if catalogue != nil {
                pickerRow
                    .arrives(index: 5)
            }

            if let preferOffline {
                section("Offline") {
                    Toggle(isOn: preferOffline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Browse offline")
                                .typeRowTitle()
                                .foregroundStyle(Palette.textPrimary)
                            Text("""
                            Filters the bundled top 20,000 series with no requests. \
                            Covers load when you're back online.
                            """)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Palette.accent)
                }
                .arrives(index: 6)
            }

            actions
        }
        .onChange(of: query) { _, new in scheduleCount(for: new) }
        // Flipping "Browse offline" changes where the count comes from
        // without changing the query, so it needs its own trigger.
        .onChange(of: preferOffline?.wrappedValue) { _, _ in scheduleCount(for: query) }
        .task { scheduleCount(for: query) }
        .sheet(isPresented: $isPickingTags) {
            if let catalogue {
                TagPickerSheet(catalogue: catalogue, selected: $query.tags, mode: $query.tagMode)
            }
        }
        .sheet(isPresented: $isPickingGenres) {
            if let catalogue {
                GenrePickerSheet(catalogue: catalogue, genres: $genres, selected: $query.genres)
            }
        }
        .sheet(isPresented: $isPickingPublisher) {
            if let catalogue {
                PublisherPickerSheet(catalogue: catalogue) { publisher in
                    query.publisher = publisher.name
                    isPickingPublisher = false
                }
            }
        }
    }

}

/// Split out of the struct body to stay under the lint's `type_body_length`
/// ceiling — not a widening of who is meant to touch these, same as
/// `TagPickerSheet`'s own split into an extension for the same reason.
extension FilterPanel {
    // MARK: - Tags / Genres / Publishers

    /// Three compact doors out, instead of the vocabulary laid out in full:
    /// a tag and a genre are two vocabularies on the wire (`tag=` against
    /// `genre=`; `SearchQuery.genres` has the 6-14% measurement), so each
    /// button counts its own array — until 2026-09-13 both wrote into
    /// `query.tags` and the badges had to guess which was which from a
    /// fetch. A publisher narrows by who released it.
    private var pickerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Narrow by")
            HStack(spacing: Metrics.gapChips) {
                pickerButton("Tags", count: query.tags.count) { isPickingTags = true }
                pickerButton("Genres", count: query.genres.count) {
                    isPickingGenres = true
                    if genres.isEmpty { Task { await loadGenres() } }
                }
                pickerButton("Publishers", count: query.publisher == nil ? 0 : 1) {
                    isPickingPublisher = true
                }
            }
        }
        .task { if genres.isEmpty { await loadGenres() } }
    }

    private func pickerButton(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).typeChip()
                if count > 0 {
                    Text("\(count)")
                        .typeFootnote()
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 18)
                        .background(Palette.accent, in: Capsule())
                        .countsNotCuts()
                }
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.headerPill)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
            .tapTarget()
        }
        .buttonStyle(.press)
    }

    private func loadGenres() async {
        guard let catalogue else { return }
        genres = await catalogue.genres().value ?? []
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: Metrics.gapChips) {
                if let onSaveLens {
                    SaveLensButton(query: query) { onSaveLens() }
                }

                // Reversible in place, rather than gone. See `FilterSheet`'s
                // original doc comment on this button — unchanged behaviour,
                // just relocated.
                Button {
                    if let cleared {
                        query = cleared
                        self.cleared = nil
                    } else {
                        cleared = query
                        query = SearchQuery()
                    }
                } label: {
                    Text(cleared == nil ? "Clear all" : "Undo clear")
                        .typeCTA()
                        .foregroundStyle(Palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.ctaSecondary)
                        .background(Palette.surfaceChip)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                }
                .disabled(cleared == nil && query.isEmpty)
            }

            // A disabled control is a different control, not a live one that
            // ignores taps: with nothing to show the button used to keep its
            // accent fill and simply not respond, which the live walk logged
            // as "Show results stopped responding after scrolling"
            // (docs/reviews/search/live-walk-2.md, third attempt, B). Same
            // rule as Mix's Blend button.
            let canShow = Self.canShow(query: query)
            Button(action: onShowResults) {
                Text(showResultsLabel)
                    .typeCTA()
                    .foregroundStyle(canShow ? Palette.onAccent : Palette.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaSecondary)
                    .background(canShow ? Palette.accent : Palette.surfaceChip)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                    .countsNotCuts()
            }
            .disabled(!canShow)

            if onSaveLens != nil, let footnote = Self.lensFootnote(for: query) {
                Text(footnote)
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var showResultsLabel: String {
        guard let resultCount else { return "Show results" }
        return "Show \(resultCount.formatted()) results"
    }

    /// Whether "Show results" can be tapped at all. `nonisolated static` and
    /// pure so it is testable without a live panel — a filter query that
    /// narrows nothing is not worth the request.
    nonisolated static func canShow(query: SearchQuery) -> Bool {
        !query.isEmpty
    }

    /// Where the "Show N results" number comes from for a given query and
    /// offline setting. `nonisolated static` and pure so the rule is testable
    /// without a live panel — the view's `scheduleCount` only acts on it.
    ///
    /// Offline wins outright and never falls through: with the toggle on and
    /// no offline counter supplied, the answer is `.none`, not the network.
    /// Before 2026-09-13 the panel read only `canShow` and `previewCount`,
    /// so the toggle that promised "no requests" still sent one count per
    /// settled filter change (review UX#2).
    nonisolated static func countSource(
        query: SearchQuery, preferOffline: Bool, hasNetworkCounter: Bool, hasOfflineCounter: Bool
    ) -> CountSource {
        guard canShow(query: query) else { return .none }
        if preferOffline { return hasOfflineCounter ? .offline : .none }
        return hasNetworkCounter ? .network : .none
    }

    /// Debounced, so seven chip taps in a row ask the network once, not
    /// seven times — the same shared-rate-limit reasoning as
    /// `PublisherBrowser.schedule()`. This is a *preview* only: it never
    /// fires the actual search `onShowResults` does.
    private func scheduleCount(for query: SearchQuery) {
        countTask?.cancel()
        let source = Self.countSource(
            query: query,
            preferOffline: preferOffline?.wrappedValue ?? false,
            hasNetworkCounter: previewCount != nil,
            hasOfflineCounter: offlineCount != nil
        )
        let counter: ((SearchQuery) async -> Int?)? = switch source {
        case .none: nil
        case .offline: offlineCount
        case .network: previewCount
        }
        guard let counter else {
            resultCount = nil
            return
        }
        // Copied out rather than read through `self` inside the task: this is
        // a struct, and the closure should capture the clock, not the view.
        let clock = clock
        countTask = Task {
            try? await clock.sleep(for: Self.countDebounce)
            guard !Task.isCancelled else { return }
            let total = await counter(query)
            guard !Task.isCancelled else { return }
            resultCount = total
        }
    }

    /// The line under the actions explaining the bookmark. Nil while no
    /// filter is set: a first-time reader with nothing chosen used to meet
    /// "saves this as a lens" before the screen had shown them a lens or a
    /// filter (review 2026-09-13, UX#8). The greyed bookmark's own
    /// accessibility hint ("Set a filter first") already covers that state.
    nonisolated static func lensFootnote(for query: SearchQuery) -> String? {
        guard !query.isEmpty else { return nil }
        return "The bookmark saves these filters as a lens."
    }

    /// What the "Filters" button on the results screen should wear: the
    /// number of filters narrowing the results besides the typed text, or
    /// nil for none. Without it a Type chip that outlived a cleared query
    /// filtered the grid with no visible cue (live walk 2026-09-13, `43` vs
    /// `44-filters-check-manga-persist.png`). Text and sort are not filters
    /// here — `activeFilterCount`'s own rule, reused rather than restated.
    nonisolated static func filterBadge(for query: SearchQuery) -> String? {
        let count = query.activeFilterCount
        return count > 0 ? "\(count)" : nil
    }

    // MARK: - Shared controls

    /// An eyebrow, not a subsection header: the mockup draws "Status" at
    /// 11px semibold, tracked and uppercase, under a 20px "Filters" — and
    /// until 2026-09-13 these seven labels and the idle screen's three
    /// sections were all `typeSubsectionHeader()`, ten headers at one
    /// weight with nothing to say which seven belonged to "Filters"
    /// (review UX#7).
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(text: title)
            content()
        }
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // "OEL", not "Oel" — the same rule the series page uses.
            Text(DetailHero.typeLabel(label) ?? label.capitalized)
                .typeChip()
                .foregroundStyle(isOn ? Palette.onAccent : Palette.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: Metrics.headerPill)
                .background(isOn ? Palette.accent : Palette.surfaceChip)
                .clipShape(Capsule())
                .tapTarget()
                .animation(Motion.reduced(Motion.snappy), value: isOn)
        }
        .buttonStyle(.press)
        .haptic(Haptics.selection, on: isOn)
    }

    /// The mockup names the current value beside the heading in the accent,
    /// so the control says what it is set to without the reader parsing five
    /// segments to find the lit one.
    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Minimum rating")
                Spacer(minLength: 8)
                Text(RatingSegments.label(for: query.minimumRating))
                    .typeChip()
                    .foregroundStyle(Palette.accent)
            }
            RatingSegments(minimum: $query.minimumRating)
        }
    }

    /// First-publication-year range. Plain number fields rather than a
    /// slider or wheel — the mockup Abdi will send later replaces this, and
    /// two fields say exactly what they mean without inventing a control.
    /// Sent live since 2026-09-13: see `SearchQuery.yearFrom`'s doc comment.
    private var yearSection: some View {
        section("Year") {
            HStack(spacing: Metrics.gapChips) {
                yearField("From", value: $query.yearFrom)
                yearField("To", value: $query.yearTo)
            }
        }
    }

    private func yearField(_ placeholder: String, value: Binding<Int?>) -> some View {
        TextField(placeholder, text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0.filter(\.isNumber)) }
        ))
        .keyboardType(.numberPad)
        .typeChip()
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: Metrics.headerPill)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceChip)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
    }
}

/// The count capsule the "Filters" button wears while a filter is active —
/// the same capsule the panel's Tags/Genres/Publishers buttons already use,
/// so one filter reads the same way at both doors. Lives here, beside the
/// rule that computes it (`FilterPanel.filterBadge(for:)`), rather than in
/// `SearchView`, so the panel stays the one owner of what "a filter" is.
struct FilterCountBadge: View {
    let query: SearchQuery

    var body: some View {
        if let badge = FilterPanel.filterBadge(for: query) {
            Text(badge)
                .typeFootnote()
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(Palette.accent, in: Capsule())
                .countsNotCuts()
                .accessibilityLabel("\(badge) active")
        }
    }
}

/// Add-or-remove for a chip's value; shared by the panel's chips and
/// `GenrePickerSheet`'s (in `FilterPickerSheets.swift`), which used to carry
/// a copy each. Internal, not private, only for that second caller.
func toggle(_ collection: inout [String], _ value: String) {
    if let index = collection.firstIndex(of: value) {
        collection.remove(at: index)
    } else {
        collection.append(value)
    }
}
