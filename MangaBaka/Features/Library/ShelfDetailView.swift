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
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

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

    /// Gap 114: an edit made from this screen (unrating the shelf's last
    /// unrated entry, say) can shrink `availableFilters` out from under the
    /// filter `@State` still points at — the chip for it disappears, but
    /// `filter` itself stays selected, and `visible` was left permanently
    /// empty with no chip left to tap back to "All". This is the pure rule;
    /// `body`'s `.onChange` keeps the `@State` itself in sync with it.
    nonisolated static func visibleFilter(selected: Filter, available: [Filter]) -> Filter {
        available.contains(selected) ? selected : .all
    }

    private var effectiveFilter: Filter { Self.visibleFilter(selected: filter, available: availableFilters) }

    private var visible: [LibraryEntry] {
        let filtered = showsFilters ? shelf.entries.filter(effectiveFilter.matches) : shelf.entries
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
                // Gap 113 (partial — the routing half of this belongs to
                // whatever pushed this screen, not to this view): a shelf
                // emptied by an edit made from here shows a real empty state
                // rather than a bare scroll view with nothing in it.
                if shelf.entries.isEmpty {
                    EmptyState(
                        title: "Nothing left on this shelf",
                        message: "Every series here has moved, or been edited off it."
                    )
                    .padding(.top, 40)
                } else if visible.isEmpty {
                    EmptyState(
                        title: "Nothing matches",
                        message: searchText.isEmpty
                            ? "No series here match this filter."
                            : "No series here match this search.",
                        actionTitle: "Clear",
                        actionWeight: .aside,
                        action: {
                            searchText = ""
                            filter = .all
                        }
                    )
                    .padding(.top, 20)
                }
                ForEach(visible) { entry in
                    LibraryRow(
                        entry: entry,
                        series: entry.series,
                        onOpen: {
                            guard let series = entry.series else {
                                toasts?.show("This entry didn't load fully. Try again later.", kind: .failure)
                                return
                            }
                            path.append(series)
                        },
                        onEdit: entry.series == nil ? nil : { editing = entry }
                    )
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        // Gap 114: keeps the actual selection in step with what the chips
        // can offer, rather than leaving `filter` pointed at a chip that
        // just disappeared.
        .onChange(of: availableFilters) { _, available in
            filter = Self.visibleFilter(selected: filter, available: available)
        }
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
                .buttonStyle(.press)
            }
        }
        .padding(.bottom, 14)
    }
}

/// Offers "Edit" only when there is something for it to open (gap 115).
private struct EditActionIfAvailable: ViewModifier {
    let onEdit: (() -> Void)?

    func body(content: Content) -> some View {
        if let onEdit {
            content
                .accessibilityAction(named: "Edit") { onEdit() }
                .contextMenu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                }
        } else {
            content
        }
    }
}

/// One library entry as a row: cover, title, where you left it, your rating,
/// and your note if you wrote one.
///
/// `series` is optional and `onEdit` nil where it is missing (gap 115): an
/// entry whose series never decoded has nothing for a detail page or an edit
/// sheet to show, so `onOpen` is expected to toast rather than navigate, and
/// no Edit action is offered at all rather than one that would open a sheet
/// with no title.
struct LibraryRow: View {
    let entry: LibraryEntry
    let series: Series?
    let onOpen: () -> Void
    let onEdit: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Metrics.gapCovers) {
                if let series {
                    CoverImage(
                        cover: series.cover,
                        width: Metrics.coverUpcomingThumb,
                        radius: Metrics.radiusThumb,
                        accessibilityText: ""
                    )
                    // The row combines into one element carrying the title, so
                    // the cover would only add a focus stop that says nothing.
                    .accessibilityHidden(true)
                } else {
                    RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous)
                        .fill(Palette.surface)
                        .frame(
                            width: Metrics.coverUpcomingThumb,
                            height: Metrics.coverUpcomingThumb / Metrics.coverAspect
                        )
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(series?.displayTitle ?? "Untitled series")
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
                            .foregroundStyle(Palette.textMuted)
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
        .buttonStyle(.press)
        .accessibilityElement(children: .combine)
        // A row is a link to the series; editing is a separate, deliberate act
        // rather than something a stray tap can do to real data.
        .modifier(EditActionIfAvailable(onEdit: onEdit))
    }

    private var progressLine: String {
        series.map { Self.progressLine(entry, series: $0) } ?? entry.state.title
    }

    /// "left at 18/112 · 16%", or a plain state when there is no progress.
    ///
    /// A series with no chapter count still gets a number: an ongoing series
    /// has no denominator, and "left at ch 17" is more use than nothing.
    nonisolated static func progressLine(_ entry: LibraryEntry, series: Series) -> String {
        guard let read = entry.progressChapter, read > 0 else {
            return entry.state.title
        }
        // L7: `Int(read)` truncated a half chapter to a whole one, unlike the
        // editor for the same entry. `LibraryEditSheet.chapterText` is the
        // one formatter for this now.
        guard let total = series.totalChapters, total > 0 else {
            return "left at ch \(LibraryEditSheet.chapterText(read))"
        }
        // A reader can legitimately be past the recorded total: an ongoing
        // series' chapter count lags what has actually released, and the +1
        // button has no ceiling. "left at 205/201 · 102%" is the result, and
        // the progress bar beside it already clamps, so the two disagreed.
        guard read <= total else { return "left at ch \(LibraryEditSheet.chapterText(read))" }
        let percent = Int(wholeOrClamped: (read / total * 100).rounded())
        return "left at \(LibraryEditSheet.chapterText(read))/\(Int(wholeOrClamped: total)) · \(percent)%"
    }
}

/// The reader's own rating, as five steps.
///
/// `rating` is a 0-100 field, but real ratings land on 20/40/60/80/100 — a
/// five-point scale in disguise. Rendering "80" would be technically true and
/// misleading about the scale it came from.
struct RatingPips: View {
    let rating: Double

    private var filled: Int { max(0, min(5, Int(wholeOrClamped: (rating / 20).rounded()))) }

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
