import SwiftUI

/// One shelf's contents.
///
/// Dropped gets extra filters, because it is the largest shelf on a real
/// library and the interesting questions about it are "which ones did I write a
/// note about" and "which did I bail on early" rather than "show me 429 covers".
struct ShelfDetailView: View {
    let shelf: LibraryModel.Shelf
    @Binding var path: [Series]
    /// Applies a change to the reader's real library. Returns a message on
    /// failure, nil on success.
    let onSave: (Int, LibraryChange) async -> String?

    @State private var filter: Filter = .all
    @State private var editing: LibraryEntry?
    @State private var searchText = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case hasNote
        case neverRated
        case leftEarly

        var id: String { rawValue }

        func label(_ count: Int) -> String {
            switch self {
            case .all: "All \(count)"
            case .hasNote: "Has a note \(count)"
            case .neverRated: "Never rated \(count)"
            case .leftEarly: "Left before ch 10 \(count)"
            }
        }

        func matches(_ entry: LibraryEntry) -> Bool {
            switch self {
            case .all: true
            case .hasNote: !(entry.note ?? "").isEmpty
            case .neverRated: entry.rating == nil
            case .leftEarly: (entry.progressChapter ?? 0) > 0 && (entry.progressChapter ?? 0) < 10
            }
        }
    }

    /// Only dropped carries the filters; on the others they would all read "all".
    private var showsFilters: Bool { shelf.state == .dropped }

    /// A shelf worth searching. Below this a reader can see the whole thing by
    /// scrolling, and a field that filters six rows is furniture.
    private var showsSearch: Bool { shelf.entries.count >= 12 }

    private var visible: [LibraryEntry] {
        let filtered = showsFilters ? shelf.entries.filter(filter.matches) : shelf.entries
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return filtered }
        return filtered.filter { entry in
            entry.series?.matches(needle) ?? false
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if showsSearch {
                    InlineSearchField(
                        prompt: "Search \(shelf.entries.count.formatted()) here",
                        text: $searchText
                    )
                    .padding(.bottom, 14)
                }
                if showsFilters { filterChips }
                if visible.isEmpty && !searchText.isEmpty {
                    Text("Nothing on this shelf matches")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.vertical, 20)
                }
                ForEach(visible) { entry in
                    if let series = entry.series {
                        LibraryRow(
                            entry: entry,
                            series: series,
                            onOpen: { path.append(series) },
                            onEdit: { editing = entry }
                        )
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle(shelf.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { entry in
            if let series = entry.series {
                LibraryEditSheet(entry: entry, series: series) { change in
                    await onSave(entry.seriesId, change)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shelf.label)
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            Text(shelf.note)
                .typeSubtitle()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 16)
    }

    /// Filters that would match nothing are dropped rather than shown reading
    /// zero. On a real library only one of 937 entries carries a note, so
    /// "Has a note 0" was a control that could never do anything.
    private var availableFilters: [Filter] {
        Filter.allCases.filter { option in
            option == .all || shelf.entries.contains(where: option.matches)
        }
    }

    private var filterChips: some View {
        FlowLayout(spacing: 7) {
            ForEach(availableFilters) { option in
                let count = shelf.entries.filter(option.matches).count
                Button { filter = option } label: {
                    Text(option.label(count))
                        .typeChip()
                        .foregroundStyle(
                            filter == option ? Palette.onAccent : Palette.textSecondary
                        )
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            filter == option ? Palette.accent : Palette.surfaceChip,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }
}

/// One library entry as a row: cover, title, where you left it, your rating,
/// and your note if you wrote one.
struct LibraryRow: View {
    let entry: LibraryEntry
    let series: Series
    let onOpen: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Metrics.gapCovers) {
                CoverImage(
                    cover: series.cover,
                    width: Metrics.coverUpcomingThumb,
                    radius: Metrics.radiusThumb,
                    accessibilityText: ""
                )
                // The row combines into one element carrying the title, so the
                // cover would only add a focus stop that says nothing.
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(series.displayTitle ?? "Untitled series")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(progressLine)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)

                    if let rating = entry.rating {
                        RatingPips(rating: rating)
                    }

                    if let note = entry.note, !note.isEmpty {
                        Text(note)
                            .typeFootnote()
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 13)
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.hairline).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // A row is a link to the series; editing is a separate, deliberate act
        // rather than something a stray tap can do to real data.
        .accessibilityAction(named: "Edit") { onEdit() }
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onEdit)
        }
    }

    private var progressLine: String { Self.progressLine(entry, series: series) }

    /// "left at 18/112 · 16%", or a plain state when there is no progress.
    ///
    /// A series with no chapter count still gets a number: an ongoing series
    /// has no denominator, and "left at ch 17" is more use than nothing.
    static func progressLine(_ entry: LibraryEntry, series: Series) -> String {
        guard let read = entry.progressChapter, read > 0 else {
            return entry.state.title
        }
        guard let total = series.totalChapters, total > 0 else {
            return "left at ch \(Int(read))"
        }
        // A reader can legitimately be past the recorded total: an ongoing
        // series' chapter count lags what has actually released, and the +1
        // button has no ceiling. "left at 205/201 · 102%" is the result, and
        // the progress bar beside it already clamps, so the two disagreed.
        guard read <= total else { return "left at ch \(Int(read))" }
        let percent = Int((read / total * 100).rounded())
        return "left at \(Int(read))/\(Int(total)) · \(percent)%"
    }
}

/// The reader's own rating, as five steps.
///
/// `rating` is a 0-100 field, but real ratings land on 20/40/60/80/100 — a
/// five-point scale in disguise. Rendering "80" would be technically true and
/// misleading about the scale it came from.
struct RatingPips: View {
    let rating: Double

    private var filled: Int { max(0, min(5, Int((rating / 20).rounded()))) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Palette.accent : Palette.surfaceActive)
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(filled) out of 5")
    }
}
