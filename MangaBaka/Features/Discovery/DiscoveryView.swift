import SwiftUI

/// Deliberately plain. Structure and states are correct; the visual design is
/// intentionally unstyled so it can be replaced wholesale later without
/// touching the model or networking layers.
struct DiscoveryView: View {
    @State private var model: DiscoveryModel

    init(model: DiscoveryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Rising")
        }
        .task {
            if case .idle = model.state { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(series):
            if series.isEmpty {
                ContentUnavailableView(
                    "Nothing rising right now",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Check back a little later.")
                )
            } else {
                grid(series)
            }

        case let .failed(message, stale):
            if stale.isEmpty {
                ContentUnavailableView {
                    Label("Can't load right now", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            } else {
                // A failure with cached content shows the content, not an error
                // page. The banner explains why it may be out of date.
                VStack(spacing: 0) {
                    Text(message)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.quaternary)
                    grid(stale)
                }
            }
        }
    }

    private func grid(_ series: [Series]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 12)],
                spacing: 16
            ) {
                ForEach(series) { item in
                    SeriesCard(series: item)
                }
            }
            .padding(16)
        }
        .refreshable { await model.load() }
    }
}

private struct SeriesCard: View {
    let series: Series
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            // A series can legitimately have no titles at all, so this is not
            // a force-unwrap waiting to happen.
            Text(series.displayTitle ?? "Untitled series")
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
    }

    private var cover: some View {
        // Reserve the intrinsic aspect ratio before the image arrives so the
        // grid does not reflow mid-scroll. 2:3 is the common manga cover ratio
        // and is used only when the API omits dimensions.
        let ratio = series.cover.aspectRatio ?? (2.0 / 3.0)
        return AsyncImage(
            url: series.cover.url(forHeight: 250, scale: displayScale)
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
