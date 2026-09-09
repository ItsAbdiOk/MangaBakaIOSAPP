import SwiftUI

/// The Discover screen: several horizontal cover rows under a large title.
struct DiscoverView: View {
    @State private var model: DiscoverModel
    @Binding private var path: [Series]
    private let onOpenStack: () -> Void

    init(model: DiscoverModel, path: Binding<[Series]>, onOpenStack: @escaping () -> Void) {
        _model = State(initialValue: model)
        _path = path
        self.onOpenStack = onOpenStack
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header
                openTheStack

                if model.isCompletelyEmpty {
                    emptyState
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .refreshable { await model.load(forceRefresh: true) }
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discover")
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
            Text(todayLine)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// "Tuesday · 1,284 series cached". Both halves are real: the weekday from
    /// the clock, the count from the database. The mockup's third clause
    /// ("nothing waiting on a spinner") is dropped — it is a claim about
    /// performance that the app cannot verify at render time.
    private var todayLine: String {
        let weekday = Date().formatted(.dateTime.weekday(.wide))
        guard model.cachedCount > 0 else { return weekday }
        return "\(weekday) · \(model.cachedCount.formatted()) series cached"
    }

    /// The mockup opens Discover with a shortcut into the stack.
    ///
    /// DEVIATION: its subtitle reads "N left in today's stack". Discover cannot
    /// know that without duplicating the stack's queue and reaction logic, and
    /// a wrong number is worse than a plain one, so this says what the control
    /// does instead.
    private var openTheStack: some View {
        Button { onOpenStack() } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Palette.accent, in: RoundedRectangle(
                        cornerRadius: 9, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open the stack")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text("Swipe covers to find something new")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background { Glass.floating(RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            )) }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func rowView(_ row: DiscoverModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader(title: row.title)
                Spacer(minLength: 0)
                Text(row.more)
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
                    .padding(.trailing, Metrics.gutter)
            }

            if let staleReason = row.staleReason {
                StaleBanner(message: staleReason)
            }

            if row.isLoading && row.series.isEmpty {
                skeletonRow
            } else if row.series.isEmpty {
                Text("Nothing here right now.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(row.series) { series in
                            Button { path.append(series) } label: {
                                CoverCard(series: series, meta: Self.meta(for: series))
                            }
                            .buttonStyle(.plain)
                            // Fetch when the reader reaches the run-up to the
                            // end, not the end itself: by the time the last
                            // card is visible it is already too late to load
                            // without a visible stall.
                            .onAppear {
                                guard shouldPrefetch(series, in: row) else { return }
                                Task { await model.loadMore(row.id) }
                            }
                        }

                        if row.isLoadingMore {
                            ProgressView()
                                .tint(Palette.textTertiary)
                                .frame(
                                    width: Metrics.coverRowWidth,
                                    height: Metrics.coverRowWidth / Metrics.coverAspect
                                )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// "Manhwa · 8.6". Each half only when the API supplied it.
    static func meta(for series: Series) -> String? {
        var parts: [String] = []
        if let type = series.type, !type.isEmpty { parts.append(type.capitalized) }
        if let rating = series.rating { parts.append(String(format: "%.1f", rating / 10)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How far from the end of a row to start fetching the next page.
    /// Four cards is roughly one screen width at the row's cover size.
    private static let prefetchDistance = 4

    private func shouldPrefetch(_ series: Series, in row: DiscoverModel.Row) -> Bool {
        guard row.canLoadMore,
              let index = row.series.firstIndex(where: { $0.id == series.id })
        else { return false }
        return index >= row.series.count - Self.prefetchDistance
    }

    private var skeletonRow: some View {
        HStack(spacing: Metrics.gapCovers) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous)
                    .fill(Palette.imagePlaceholder)
                    .frame(
                        width: Metrics.coverRowWidth,
                        height: Metrics.coverRowWidth / Metrics.coverAspect
                    )
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var emptyState: some View {
        FailureState(error: model.failure ?? .offline) {
            await model.load(forceRefresh: true)
        }
    }
}
