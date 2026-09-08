import SwiftUI

/// Saved and skipped series. A skip is recoverable — discovery is worthless if
/// what you found is gone by morning, and that includes a mis-swipe.
struct ShelfView: View {
    let shelf: ShelfStore
    @Binding var path: [Series]

    @State private var saved: [Series] = []
    @State private var skipped: [Series] = []
    @State private var showSkipped = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Metrics.gapCovers),
        count: 3
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Shelf")
                    .typeScreenTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                if saved.isEmpty && skipped.isEmpty {
                    emptyState
                } else {
                    grid("Saved", saved)
                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            Button {
                                withAnimation(.snappy) { showSkipped.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Text("Skipped (\(skipped.count))")
                                        .typeSectionHeader()
                                        .foregroundStyle(Palette.textPrimary)
                                    Image(systemName: showSkipped ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.horizontal, Metrics.gutter)
                            }
                            .buttonStyle(.plain)

                            if showSkipped { gridBody(skipped) }
                        }
                    }
                }
            }
            .padding(.top, 62)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await reload() }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func grid(_ title: String, _ items: [Series]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: title)
                gridBody(items)
            }
        }
    }

    private func gridBody(_ items: [Series]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { series in
                Button { path.append(series) } label: {
                    CoverCard(
                        series: series,
                        width: 111,
                        radius: Metrics.radiusCoverGrid
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nothing saved yet")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text("Swipe right in the stack, and anything you keep lands here.")
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 70)
    }

    private func reload() async {
        saved = (try? await shelf.entries(.saved)) ?? []
        skipped = (try? await shelf.entries(.skipped)) ?? []
    }
}
