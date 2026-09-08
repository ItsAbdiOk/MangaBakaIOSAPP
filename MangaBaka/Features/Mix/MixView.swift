import SwiftUI

/// The Mix screen: pick a few series you love, tune what comes back, and
/// blend recommendations with the reason each one matched.
///
/// This is meant to feel like an instrument you tune rather than a form you
/// fill in, so seeds and filters sit above the fold and "Blend" is the only
/// button that matters.
struct MixView: View {
    @State private var model: MixModel
    @State private var suggestedSeeds: [Series] = []
    @Binding private var path: [Series]
    private let onPickSeed: () -> Void

    private static let ratingOptions: [(label: String, minimum: Int?)] = [
        ("Any", nil),
        ("7.0+", 70),
        ("8.0+", 80),
        ("9.0+", 90)
    ]

    private static let typeOptions = ["manga", "novel", "manhwa", "manhua"]

    init(model: MixModel, path: Binding<[Series]>, onPickSeed: @escaping () -> Void) {
        _model = State(initialValue: model)
        _path = path
        self.onPickSeed = onPickSeed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header
                seedRow
                if model.seeds.isEmpty {
                    suggestedSeedsSection
                }
                filterStrip
                blendButton
                resultsSection
            }
            .padding(.top, 62)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task {
            suggestedSeeds = await model.suggestedSeeds()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mix")
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
            Text("Blend a few series you love into new ones worth reading.")
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    // MARK: Seed row

    private var seedRow: some View {
        HStack(spacing: Metrics.gapCovers) {
            ForEach(model.seeds) { series in
                seedSlot(series)
            }
            ForEach(0..<(MixModel.maxSeeds - model.seeds.count), id: \.self) { _ in
                emptySeedSlot
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private func seedSlot(_ series: Series) -> some View {
        CoverImage(cover: series.cover, width: Metrics.coverSeedWidth, radius: Metrics.radiusSeed)
            .overlay(alignment: .topTrailing) {
                Button {
                    model.removeSeed(id: series.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textPrimary, Palette.ground)
                }
                .offset(x: -6, y: -6)
            }
    }

    private var emptySeedSlot: some View {
        Button(action: onPickSeed) {
            RoundedRectangle(cornerRadius: Metrics.radiusSeed, style: .continuous)
                .strokeBorder(Palette.borderDashed, style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                .frame(width: Metrics.coverSeedWidth, height: Metrics.coverSeedWidth / Metrics.coverAspect)
                .overlay {
                    Image(systemName: "plus")
                        .foregroundStyle(Palette.textTertiary)
                }
        }
    }

    // MARK: Suggested seeds

    private var suggestedSeedsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            if suggestedSeeds.isEmpty {
                SectionHeader(title: "From your shelf")
                Text("Nothing saved yet. Swipe a few series in the Stack first.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                SectionHeader(title: "From your shelf")
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.gapCovers) {
                        ForEach(suggestedSeeds) { series in
                            Button {
                                model.addSeed(series)
                            } label: {
                                CoverImage(
                                    cover: series.cover,
                                    width: Metrics.coverSeedWidth,
                                    radius: Metrics.radiusSeed
                                )
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Filters

    private var filterStrip: some View {
        FlowLayout {
            ForEach(Self.typeOptions, id: \.self) { type in
                chip(type.capitalized, isSelected: model.filters.types.contains(type)) {
                    toggleType(type)
                }
            }
            ForEach(Self.ratingOptions, id: \.label) { option in
                chip(option.label, isSelected: model.filters.minimumRating == option.minimum) {
                    model.filters.minimumRating = option.minimum
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private func toggleType(_ type: String) {
        if let index = model.filters.types.firstIndex(of: type) {
            model.filters.types.remove(at: index)
        } else {
            model.filters.types.append(type)
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .typeChip()
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .frame(height: Metrics.headerPill)
                .background(
                    isSelected ? Palette.accent : Palette.surfaceChip,
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: isSelected ? 0 : 0.5))
        }
    }

    // MARK: Blend

    private var blendButton: some View {
        Button {
            Task { await model.run() }
        } label: {
            Group {
                if model.isRunning {
                    ProgressView()
                        .tint(Palette.onAccent)
                } else {
                    Text("Blend")
                        .typeCTA()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.ctaPrimary)
            .foregroundStyle(Palette.onAccent)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: Metrics.radiusCard))
        }
        .disabled(model.seeds.isEmpty || model.isRunning)
        .opacity(model.seeds.isEmpty ? 0.4 : 1)
        .padding(.horizontal, Metrics.gutter)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        if model.isRunning {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Palette.textTertiary)
                Spacer()
            }
            .padding(.top, Metrics.sectionGap)
        } else if let message = model.message {
            Text(message)
                .typeSmallMeta()
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Metrics.gutter)
        } else if !model.results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Blend")
                ForEach(model.results) { recommendation in
                    resultRow(recommendation)
                }
            }
        }
    }

    private func resultRow(_ recommendation: Recommendation) -> some View {
        Button {
            path.append(recommendation.series)
        } label: {
            HStack(spacing: Metrics.gapCovers) {
                CoverImage(
                    cover: recommendation.series.cover,
                    width: Metrics.coverSavedStripWidth,
                    radius: Metrics.radiusThumb
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.series.displayTitle ?? "Untitled series")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                    if let reason = recommendation.reason {
                        Text(reason)
                            .typeSmallMeta()
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
