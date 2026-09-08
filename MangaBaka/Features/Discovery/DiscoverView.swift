import SwiftUI

/// The Discover screen: several horizontal cover rows under a large title.
struct DiscoverView: View {
    @State private var model: DiscoverModel
    @Binding private var path: [Series]

    init(model: DiscoverModel, path: Binding<[Series]>) {
        _model = State(initialValue: model)
        _path = path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header

                if model.isCompletelyEmpty {
                    emptyState
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
            }
            .padding(.top, 62)
            .padding(.bottom, 24)
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

    /// Grounded in the actual time of day rather than invented copy.
    private var todayLine: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<12: "Something to start the day"
        case 12..<18: "Worth an afternoon"
        case 18..<23: "Find something worth the night"
        default: "Still awake? So is the shelf"
        }
    }

    @ViewBuilder
    private func rowView(_ row: DiscoverModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: row.title)

            if let staleReason = row.staleReason {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Palette.positive)
                        .frame(width: 6, height: 6)
                    Text(staleReason)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(.horizontal, Metrics.gutter)
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
                    HStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(row.series) { series in
                            Button { path.append(series) } label: {
                                CoverCard(series: series)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
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
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(Palette.textTertiary)
            Text("Nothing to show yet")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text(model.failureReason ?? "Nothing is saved on this device yet.")
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await model.load(forceRefresh: true) } }
                .typeCTA()
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 18)
                .frame(height: Metrics.ctaSecondary)
                .background(Palette.accent, in: Capsule())
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 60)
    }
}
