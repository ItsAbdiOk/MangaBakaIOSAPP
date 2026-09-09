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
                dnaSection
                MixResults(model: model, path: $path)
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
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
            Text("Pick series you love. The mix is blended from them — no account needed.")
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
        VStack(alignment: .leading, spacing: 0) {
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
            tagFilter
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// Tags to require in the blend, with the mockup's AND/OR mode.
    ///
    /// Only offered once a blend has run: before that there is no DNA to pick
    /// from, and a blank tag field on a screen with no results is a control
    /// with nothing to control.
    @ViewBuilder
    private var tagFilter: some View {
        if !model.dna.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Eyebrow(text: "Require tags")
                    Spacer(minLength: 0)
                    if model.filters.tags.count > 1 {
                        Button { toggleTagMode() } label: {
                            Text(model.filters.tagMode == "and" ? "ALL" : "ANY")
                                .typeTabLabel()
                                .tracking(0.6)
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Palette.surfaceChip, in: RoundedRectangle(
                                    cornerRadius: 7, style: .continuous
                                ))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Palette.borderPill, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            model.filters.tagMode == "and"
                                ? "Requiring all tags. Switch to any."
                                : "Requiring any tag. Switch to all."
                        )
                    }
                }

                // Drawn from the blend's own DNA, so every chip is a tag this
                // blend actually contains rather than a guess at the taxonomy.
                FlowLayout {
                    ForEach(model.dna.strands) { strand in
                        chip(
                            strand.name,
                            isSelected: model.filters.tags.contains(strand.name)
                        ) {
                            toggleTag(strand.name)
                        }
                    }
                }
            }
            .padding(.top, Metrics.gapCovers)
        }
    }

    private func toggleTag(_ name: String) {
        if let index = model.filters.tags.firstIndex(of: name) {
            model.filters.tags.remove(at: index)
        } else {
            model.filters.tags.append(name)
        }
        // Two or more tags need a rule for combining them; one does not.
        if model.filters.tags.count > 1, model.filters.tagMode == nil {
            model.filters.tagMode = "and"
        }
        Task { await model.run() }
    }

    private func toggleTagMode() {
        model.filters.tagMode = model.filters.tagMode == "and" ? "or" : "and"
        Task { await model.run() }
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

    // MARK: Blend DNA

    /// What the blend is made of, and the only steering the API allows.
    @ViewBuilder
    private var dnaSection: some View {
        if !model.dna.isEmpty {
            BlendDNAView(
                dna: model.dna,
                excluded: model.excludedTags,
                excludedStrands: model.excludedStrands,
                moves: model.moves,
                isEdited: model.isDNAEdited,
                onToggle: { tagId in Task { await model.toggleStrand(tagId) } },
                onReset: { Task { await model.resetDNA() } }
            )
            .padding(.horizontal, Metrics.gutter)
        }
    }

}
