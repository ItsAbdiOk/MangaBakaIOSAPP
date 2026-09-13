import SwiftUI

/// The blend's output: a count line with a reshuffle, and a grid of covers each
/// carrying the reason it matched.
///
/// Its own file because MixView was at the lint's body-length ceiling.
struct MixResults: View {
    let model: MixModel
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    /// What the section actually shows, decided in one pure place so the
    /// branching can be tested without ViewInspector (this project has none).
    ///
    /// `.grid` wins whenever there is a previous blend to show, even mid
    /// re-run or mid failure — a re-blend used to replace the grid outright
    /// with a bare spinner, and the count line and covers popped back in
    /// once it finished (gap 43, FAILURES-SUMMARY.md M6). Only a blend that
    /// has never produced a result falls through to `.loading`/`.failure`.
    enum ResultsState: Equatable {
        case grid(dimmed: Bool)
        case failure(APIError)
        case loading
        case empty(String)
        /// Nothing to show yet: no seeds picked, no blend ever run.
        case idle
    }

    nonisolated static func state(
        isRunning: Bool,
        resultsEmpty: Bool,
        failure: APIError?,
        message: String?
    ) -> ResultsState {
        if !resultsEmpty { return .grid(dimmed: isRunning) }
        if let failure { return .failure(failure) }
        if isRunning { return .loading }
        if let message { return .empty(message) }
        return .idle
    }

    var body: some View {
        switch Self.state(
            isRunning: model.isRunning,
            resultsEmpty: model.results.isEmpty,
            failure: model.failure,
            message: model.message
        ) {
        case .loading:
            HStack {
                Spacer()
                ProgressView().tint(Palette.textTertiary)
                Spacer()
            }
            .padding(.top, Metrics.sectionGap)
        case let .failure(error):
            FailureState(error: error, retry: { await model.run() })
                .padding(.top, Metrics.sectionGap)
        case let .empty(message):
            Text(message)
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, Metrics.gutter)
        case .idle:
            EmptyView()
        case let .grid(dimmed):
            grid(dimmed: dimmed)
        }
    }

    private func grid(dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(model.results.count) in the blend")
                    .typeSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if dimmed {
                    // The re-run itself, said in the header row rather than
                    // over the grid it would otherwise replace — a StaleBar's
                    // wording for a blend, not a fetch.
                    HStack(spacing: 6) {
                        ProgressView().tint(Palette.textTertiary)
                        Text("Re-blending…")
                            .typeInstruction()
                            .foregroundStyle(Palette.textMuted)
                    }
                } else {
                    Button { Task { await model.run() } } label: {
                        Text("Reshuffle")
                            .typeInstruction()
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.press)
                }
            }
            .padding(.horizontal, Metrics.gutter + 2)
            .padding(.bottom, 12)

            // `CoverGrid` carries the screen gutter itself; the count line
            // above keeps its own.
            CoverGrid(items: model.results) { _, recommendation, layout in
                Button {
                    zoomRoute?.source = ZoomRoute.id("mix", recommendation.series.id)
                    zoomRoute?.neighbours = model.results.map(\.series)
                    path.append(recommendation.series)
                } label: {
                    card(recommendation, width: layout.cardWidth)
                }
                .buttonStyle(.press)
                .zoomSource("mix", recommendation.series.id)
            }
        }
        // 0.6, not the 0.45 a plain disabled fade would use: a re-blend
        // keeps the previous grid readable while it dims, since it is still
        // the best answer the reader has until the new one lands.
        .opacity(dimmed ? 0.6 : 1)
        .transition(.blurReplace)
        .animation(Motion.reduced(Motion.glide), value: dimmed)
        .disabled(dimmed)
    }

    /// The mockup puts the reason in the accent under each cover, where a
    /// rating would normally sit — in a blend, why it matched IS the metadata.
    private func card(_ recommendation: Recommendation, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(
                cover: recommendation.series.cover,
                width: width,
                radius: Metrics.radiusCoverGrid,
                accessibilityText: recommendation.series.displayTitle ?? "Untitled series"
            )
            Text(recommendation.series.displayTitle ?? "Untitled series")
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            if let reason = recommendation.reason {
                Text(reason)
                    .typeGridMeta()
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [recommendation.series.displayTitle ?? "Untitled series", recommendation.reason]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
    }
}
