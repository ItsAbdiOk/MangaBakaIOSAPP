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
    /// Runs the one request "Show results" stands for. Never fired by a chip
    /// or a picker on its own — see `canShow(query:)`'s doc comment.
    let onShowResults: () -> Void

    @State private var isPickingTags = false
    @State private var isPickingGenres = false
    @State private var isPickingPublisher = false
    @State private var genres: [Genre] = []
    @State private var resultCount: Int?
    @State private var countTask: Task<Void, Never>?
    /// The filters "Clear all" threw away, kept so they can be put back.
    @State private var cleared: SearchQuery?

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
        .task { scheduleCount(for: query) }
        .sheet(isPresented: $isPickingTags) {
            if let catalogue {
                TagPickerSheet(catalogue: catalogue, selected: $query.tags, mode: $query.tagMode)
            }
        }
        .sheet(isPresented: $isPickingGenres) {
            if let catalogue {
                GenrePickerSheet(catalogue: catalogue, genres: $genres, selected: $query.tags)
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

    /// The values `catalogue.genres()` answered with, so a tag picked through
    /// "Genres" can be told apart from an ordinary tag in `query.tags` —
    /// both live in the same array, because a genre *is* a tag as far as the
    /// query is concerned (see `SearchModel.applyBrowse(genre:)`).
    private var genreValues: Set<String> { Set(genres.map(\.value)) }

    private var tagsOnlyCount: Int { query.tags.filter { !genreValues.contains($0) }.count }
    private var genresOnlyCount: Int { query.tags.filter { genreValues.contains($0) }.count }

    /// Three compact doors out, instead of the vocabulary laid out in full:
    /// tags and genres both narrow by name — genres are just the coarse,
    /// curated ones — and a publisher narrows by who released it.
    private var pickerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Narrow by")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: Metrics.gapChips) {
                pickerButton("Tags", count: tagsOnlyCount) { isPickingTags = true }
                pickerButton("Genres", count: genresOnlyCount) {
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
                    SaveLensButton(isEnabled: !query.isEmpty) { onSaveLens() }
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

            Button(action: onShowResults) {
                Text(showResultsLabel)
                    .typeCTA()
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaSecondary)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                    .countsNotCuts()
            }
            .disabled(!Self.canShow(query: query))

            if onSaveLens != nil {
                Text("The bookmark saves this as a lens. Greyed until a filter is set.")
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

    /// Debounced, so seven chip taps in a row ask the network once, not
    /// seven times — the same shared-rate-limit reasoning as
    /// `PublisherBrowser.schedule()`. This is a *preview* only: it never
    /// fires the actual search `onShowResults` does.
    private func scheduleCount(for query: SearchQuery) {
        countTask?.cancel()
        guard Self.canShow(query: query), let previewCount else {
            resultCount = nil
            return
        }
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let total = await previewCount(query)
            guard !Task.isCancelled else { return }
            resultCount = total
        }
    }

    // MARK: - Shared controls

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
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

    private func toggle(_ collection: inout [String], _ value: String) {
        if let index = collection.firstIndex(of: value) {
            collection.remove(at: index)
        } else {
            collection.append(value)
        }
    }

    /// The mockup names the current value beside the heading in the accent,
    /// so the control says what it is set to without the reader parsing five
    /// segments to find the lit one.
    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Minimum rating")
                    .typeSubsectionHeader()
                    .foregroundStyle(Palette.textPrimary)
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
    /// Offline-only today: see `SearchQuery.yearFrom`'s doc comment.
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

/// Picking a genre for the panel's "Genres" button — the same 46-item list
/// `BrowseView`'s genre chips draw from, presented as a sheet rather than a
/// whole screen since this is one filter among several being built, not a
/// destination in its own right.
private struct GenrePickerSheet: View {
    let catalogue: CatalogueService
    @Binding var genres: [Genre]
    @Binding var selected: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                FlowLayout(spacing: 8) {
                    ForEach(genres) { genre in
                        Button {
                            toggle(genre.value)
                        } label: {
                            Text(genre.label)
                                .typeChip()
                                .foregroundStyle(
                                    selected.contains(genre.value) ? Palette.onAccent : Palette.textSecondary
                                )
                                .padding(.horizontal, 13)
                                .frame(height: Metrics.headerPill)
                                .background(
                                    selected.contains(genre.value) ? Palette.accent : Palette.surfaceChip,
                                    in: Capsule()
                                )
                                .tapTarget()
                        }
                        .buttonStyle(.press)
                        .haptic(Haptics.selection, on: selected.contains(genre.value))
                    }
                }
                .padding(Metrics.gutter)
            }
            .background(Palette.ground)
            .navigationTitle("Genres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
        .task { if genres.isEmpty { genres = await catalogue.genres().value ?? [] } }
    }

    private func toggle(_ value: String) {
        if let index = selected.firstIndex(of: value) {
            selected.remove(at: index)
        } else {
            selected.append(value)
        }
    }
}

/// Picking a publisher for the panel's "Publishers" button — `PublisherBrowser`
/// wrapped in a sheet's chrome, the same reuse `TagPickerSheet` gets.
private struct PublisherPickerSheet: View {
    let catalogue: CatalogueService
    let onOpen: (PublisherRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PublisherBrowser(catalogue: catalogue, onOpen: onOpen)
                    .padding(.top, 12)
            }
            .background(Palette.ground)
            .navigationTitle("Publishers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
    }
}
