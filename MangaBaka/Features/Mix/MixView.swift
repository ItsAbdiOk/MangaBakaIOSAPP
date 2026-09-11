import SwiftUI

/// The Mix screen: pick a few series you love, tune what comes back, and
/// blend recommendations with the reason each one matched.
///
/// This is meant to feel like an instrument you tune rather than a form you
/// fill in, so seeds and filters sit above the fold and "Blend" is the only
/// button that matters.
struct MixView: View {
    // Internal rather than private so the filter strip can reach them. See
    // MixFilterStrip.swift — the split is the lint's doing, not a widening of
    // who is meant to touch these.
    @State var model: MixModel
    @State private var suggestedSeeds: [Series] = []
    @Binding private var path: [Series]
    /// The tag catalogue, so tags can be chosen before a blend has ever run.
    let catalogue: CatalogueService?
    /// Where a blend's filters are saved. Mix has a filter strip rather than
    /// the sheet Search uses, so the save control had to come to it — the
    /// alternative was Search being the only screen that can save a lens, which
    /// is not what "one control, in the place that owns filters" was supposed
    /// to mean.
    let lenses: SearchLensStore?

    @State var isPickingTags = false
    @State var isPickingSeed = false
    @State var isNamingLens = false

    static let typeOptions = ["manga", "novel", "manhwa", "manhua"]

    init(
        model: MixModel,
        path: Binding<[Series]>,
        catalogue: CatalogueService? = nil,
        lenses: SearchLensStore? = nil
    ) {
        _model = State(initialValue: model)
        _path = path
        self.catalogue = catalogue
        self.lenses = lenses
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
        .scrollEdge()
        .task {
            suggestedSeeds = await model.suggestedSeeds()
        }
        .sheet(isPresented: $isPickingTags) {
            if let catalogue {
                TagPickerSheet(
                    catalogue: catalogue,
                    selected: $model.filters.tags,
                    mode: $model.filters.tagMode
                )
            }
        }
        .sheet(isPresented: $isPickingSeed) {
            SeedPickerSheet(model: model, repository: model.repository)
                .presentationDetents([.large])
                .presentationCornerRadius(Metrics.radiusSheet)
        }
        .sheet(isPresented: $isNamingLens) {
            SaveLensSheet(query: model.filters) { name in
                lenses?.save(name: name, query: model.filters)
            }
            .presentationDetents([.height(420)])
            .presentationCornerRadius(Metrics.radiusSheet)
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
                        // The glyph alone was about 17pt square — the smallest
                        // control in the app, sitting on the corner of a cover
                        // where a miss taps the cover instead. The mark keeps
                        // its size; the target does not have to.
                        .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(series.displayTitle ?? "this seed")")
                .offset(x: 8, y: -8)
            }
    }

    private var emptySeedSlot: some View {
        Button { isPickingSeed = true } label: {
            RoundedRectangle(cornerRadius: Metrics.radiusSeed, style: .continuous)
                .strokeBorder(Palette.borderDashed, style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                .frame(
                    width: Metrics.coverSeedWidth,
                    height: max(Metrics.coverSeedWidth / Metrics.coverAspect, Metrics.tapTarget)
                )
                .overlay {
                    Image(systemName: "plus")
                        .foregroundStyle(Palette.textTertiary)
                }
                .contentShape(Rectangle())
        }
        // "plus" is what VoiceOver said, which is the glyph's name and not
        // what the control does.
        .accessibilityLabel("Add a seed")
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
            // A disabled control is a different control, not a faded live one.
            // `.opacity(0.4)` over the accent fill left accent-coloured text on
            // an accent-coloured ground, which Apple's audit reports as an
            // outright contrast failure — the button is least readable exactly
            // when the reader is trying to work out why they cannot press it.
            .foregroundStyle(isBlendReady ? Palette.onAccent : Palette.textMuted)
            .background(
                isBlendReady ? Palette.accent : Palette.surfaceChip,
                in: RoundedRectangle(cornerRadius: Metrics.radiusCard)
            )
        }
        .disabled(model.seeds.isEmpty || model.isRunning)
        .padding(.horizontal, Metrics.gutter)
    }

    /// Whether the blend can run. A blend needs at least one seed — the API
    /// rejects a seedless request outright rather than returning a default set.
    private var isBlendReady: Bool { !model.seeds.isEmpty }

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
