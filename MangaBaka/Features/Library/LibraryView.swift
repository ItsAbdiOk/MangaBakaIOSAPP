import SwiftUI

/// The reader's own library: shelves, what is in progress, and a way into the
/// release schedule.
struct LibraryView: View {
    @State private var model: LibraryModel
    @Binding private var path: [Series]
    private let scheduleSummary: String?
    private let onOpenSchedule: () -> Void
    private let onOpenShelf: (LibraryEntry.State) -> Void

    init(
        model: LibraryModel,
        path: Binding<[Series]>,
        scheduleSummary: String?,
        onOpenSchedule: @escaping () -> Void,
        onOpenShelf: @escaping (LibraryEntry.State) -> Void
    ) {
        _model = State(initialValue: model)
        _path = path
        self.scheduleSummary = scheduleSummary
        self.onOpenSchedule = onOpenSchedule
        self.onOpenShelf = onOpenShelf
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.isLoading && model.entries.isEmpty {
                    loading
                } else if !model.hasAccount {
                    noAccount
                } else {
                    scheduleCard
                    pickBackUp
                    shelfCards
                    if let shape = model.shapeLine {
                        Text(shape)
                            .typeFootnote()
                            .foregroundStyle(Palette.textQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                    }
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            Text(model.subtitle)
                .typeSubtitle()
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView().tint(Palette.textTertiary)
            Spacer()
        }
        .padding(.top, 80)
    }

    private var noAccount: some View {
        VStack(spacing: 0) {
            Text("No library yet")
                .typeSectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text("""
            Add a MangaBaka token in Settings and everything you track there \
            appears here.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
        .padding(.top, 90)
    }

    /// The way into the schedule, carrying its own summary so the card says
    /// something rather than just pointing.
    private var scheduleCard: some View {
        Button(action: onOpenSchedule) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Palette.surfacePill, in: RoundedRectangle(
                        cornerRadius: 11, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next chapters")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text(scheduleSummary ?? "Estimate when each one is due")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textQuaternary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 22)
    }

    @ViewBuilder
    private var pickBackUp: some View {
        let entries = model.inProgress
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Pick back up")
                        .typeSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(entries.count) in progress")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textFaint)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 11)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: Metrics.gapCovers) {
                        ForEach(entries) { entry in
                            if let series = entry.series {
                                progressCard(entry, series: series)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    /// A cover with a progress bar across its foot. `progress_chapter` against
    /// `total_chapters` is real for three quarters of a typical library.
    private func progressCard(_ entry: LibraryEntry, series: Series) -> some View {
        Button { path.append(series) } label: {
            VStack(alignment: .leading, spacing: 7) {
                CoverImage(
                    cover: series.cover,
                    width: Metrics.coverSavedStripWidth,
                    radius: Metrics.radiusCoverRow,
                    accessibilityText: series.displayTitle ?? "Untitled series"
                )
                .overlay(alignment: .bottom) {
                    if let fraction = fraction(entry, series: series) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5))
                                Rectangle()
                                    .fill(Palette.accent)
                                    .frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                Text(chapterLabel(entry))
                    .typeFootnote()
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(width: Metrics.coverSavedStripWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(series.displayTitle ?? "Untitled series"), \(chapterLabel(entry))"
        )
    }

    private func fraction(_ entry: LibraryEntry, series: Series) -> Double? {
        guard let read = entry.progressChapter, read > 0,
              let total = series.totalChapters, total > 0
        else { return nil }
        return min(read / total, 1)
    }

    private func chapterLabel(_ entry: LibraryEntry) -> String {
        guard let read = entry.progressChapter, read > 0 else { return "Not started" }
        return "ch \(Int(read))"
    }

    private var shelfCards: some View {
        VStack(spacing: Metrics.gapCovers) {
            ForEach(model.shelves) { shelf in
                Button { onOpenShelf(shelf.state) } label: {
                    ShelfCard(shelf: shelf)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.sectionGap)
    }
}

/// One shelf, as a card: name, count, a strip of covers, and a line saying what
/// the shelf actually is.
struct ShelfCard: View {
    let shelf: LibraryModel.Shelf

    /// Dropped is tinted a step brighter and its covers dimmed. It is the
    /// largest shelf on a real library — 46% — so it earns its own weight
    /// rather than being tucked away, but its covers are things the reader
    /// walked away from.
    private var isDropped: Bool { shelf.state == .dropped }

    private var countColour: Color {
        isDropped ? Palette.textEmphasis : Palette.textSecondary
    }

    private var shelfName: some View {
        Text(shelf.label)
            .typeSubsectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.textQuaternary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Side by side until they no longer fit. Squeezed, the name broke
            // mid-word — "Complete" over a lone "d" — because the count and
            // chevron took their width first.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    shelfName
                    Text(shelf.count.formatted())
                        .typeStatNumber()
                        .foregroundStyle(countColour)
                    chevron
                }
                VStack(alignment: .leading, spacing: 4) {
                    shelfName
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(shelf.count.formatted())
                            .typeStatNumber()
                            .foregroundStyle(countColour)
                        chevron
                    }
                }
            }

            HStack(spacing: 7) {
                ForEach(shelf.covers) { series in
                    CoverImage(
                        cover: series.cover,
                        width: 54,
                        radius: Metrics.radiusThumb,
                        accessibilityText: ""
                    )
                    .accessibilityHidden(true)
                    .opacity(isDropped ? 0.78 : 1)
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            Text(shelf.note)
                .typeFootnote()
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .background(
            isDropped ? Palette.surfaceChip : Palette.surfaceInset,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .hairlineBorder(Palette.border, radius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shelf.label), \(shelf.count) series")
    }
}
