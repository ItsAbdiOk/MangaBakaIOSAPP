import SwiftUI

/// What the reader's library says about them.
struct TasteView: View {
    @State private var model: TasteModel
    private let entries: [LibraryEntry]

    init(model: TasteModel, entries: [LibraryEntry]) {
        _model = State(initialValue: model)
        self.entries = entries
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.isLoading && !model.hasAnything {
                    ProgressView()
                        .tint(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    affinitySection
                    ratingSection
                    shapeSection
                    provenance
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle("Your taste")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(entries: entries) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your taste")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            Text("Counted from your own library. Nothing here is guessed at.")
                .typeSubtitle()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    /// MangaBaka's own affinity scores.
    ///
    /// A short list by nature: the endpoint returns three for a 937-series
    /// library, and its documented `limit` parameter returns zero rows when
    /// sent. So this is designed for a handful of strong signals rather than a
    /// long tail.
    @ViewBuilder
    private var affinitySection: some View {
        if !model.affinities.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Strongest affinities")
                    .padding(.bottom, 12)
                ForEach(model.affinities) { affinity in
                    affinityRow(affinity)
                }
                Text("""
                MangaBaka works these out from your library. It returns a \
                handful, not a ranking of everything.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    private func affinityRow(_ affinity: TopGenre) -> some View {
        let strongest = model.affinities.map { $0.affinityScore ?? 0 }.max() ?? 1
        let share = strongest > 0 ? (affinity.affinityScore ?? 0) / strongest : 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(affinity.tagName)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The raw score, not a percentage: it is unbounded and calling
                // it a percentage would be inventing a scale.
                Text(String(format: "%.0f", affinity.affinityScore ?? 0))
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textTertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceChip)
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: max(proxy.size.width * share, 3))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var ratingSection: some View {
        if let line = model.ratingLine {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "How you rate")
                    .padding(.bottom, 12)
                RatingHistogram(buckets: model.ratingHistogram)
                Text(line)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    @ViewBuilder
    private var shapeSection: some View {
        if let shape = model.shapeLine {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "The shape of it")
                    .padding(.bottom, 12)
                Text(shape)
                    .typeSubsectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(model.shelfCounts, id: \.state) { shelf in
                        HStack {
                            Text(shelf.state.title)
                                .typeInstruction()
                                .foregroundStyle(Palette.textSecondary)
                            Spacer(minLength: 10)
                            Text(shelf.count.formatted())
                                .typeInstruction()
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Palette.hairline).frame(height: 0.5)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 12)
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    private var provenance: some View {
        Text("""
        Affinities come from MangaBaka. The rest is counted from your own \
        library on this device — no profiling, and nothing sent anywhere.
        """)
        .typeFootnote()
        .foregroundStyle(Palette.textQuaternary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
        .padding(.top, 20)
    }
}

/// Five bars, one per rating step.
struct RatingHistogram: View {
    let buckets: [Int]

    private var peak: Int { max(buckets.max() ?? 1, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { index, count in
                VStack(spacing: 6) {
                    Text(count.formatted())
                        .typeFootnote()
                        .foregroundStyle(Palette.textTertiary)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(count == peak ? Palette.accent : Palette.surfaceActive)
                        .frame(height: max(CGFloat(count) / CGFloat(peak) * 58, 4))
                    Text("\(index + 1)")
                        .typeGridMeta()
                        .foregroundStyle(Palette.textQuaternary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(index + 1) star\(index == 0 ? "" : "s"), \(count)")
            }
        }
        .frame(height: 92, alignment: .bottom)
    }
}
