import SwiftUI

/// The filters above a blend: type, minimum rating, required tags, and the
/// control that saves the lot as a lens.
///
/// Split out of `MixView` for the lint's body-length ceiling. The seam is real:
/// everything here narrows the blend, and everything left behind is the blend
/// itself.
///
/// Mix has a strip where Search has a sheet, which is why the save control had
/// to be brought here rather than inherited. One control in the place that owns
/// filters was always the rule; there are simply two such places.
extension MixView {
    var filterStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout {
                ForEach(Self.typeOptions, id: \.self) { type in
                    chip(type.capitalized, isSelected: model.filters.types.contains(type)) {
                        toggleType(type)
                    }
                }
            }
            // The same control the search filters use. Mix had its own row of
            // capsules offering Any/7/8/9 — a different shape and a different
            // set from the sheet, for the same parameter on the same API.
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Minimum rating")
                Spacer(minLength: 8)
                Text(RatingSegments.label(for: model.filters.minimumRating))
                    .typeChip()
                    .foregroundStyle(Palette.accent)
            }
            .padding(.top, Metrics.gapCovers)
            RatingSegments(minimum: $model.filters.minimumRating)
                .padding(.top, 10)
            tagFilter

            if lenses != nil {
                HStack(spacing: 10) {
                    SaveLensButton(query: model.filters) {
                        isNamingLens = true
                    }
                    Text("Saves these filters as a lens, on Search.")
                        .typeFootnote()
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Metrics.gapCovers)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        // One place, not one per control. The type and tag chips called
        // the blend themselves and the rating segments and the tag picker
        // sheet did not — both write `model.filters` and neither re-blended,
        // so the grid showed 6.1-rated series under a control reading 8+, and
        // a tag picked in the sheet came back selected over results that had
        // never required it (item 45). Debounced in the model, on the same
        // timer the strand chips use, so a run of taps is still one request
        // and a strand tap beside a chip tap is not two (F28).
        .onChange(of: model.filters) { model.filtersDidChange() }
    }

    /// Tags to require in the blend. The mockup's AND/OR mode is gone — see
    /// the comment where the toggle used to sit.
    ///
    /// **Offered before the first blend as well as after.** It used to appear
    /// only once a blend had run, on the reasoning that there was no DNA to
    /// pick from — which was true of the chips and not of the feature. A reader
    /// who wants "these three, but it has to have Regression" had to blend
    /// once, discard the answer and blend again. The DNA chips still need a
    /// blend; the picker never did.
    @ViewBuilder
    var tagFilter: some View {
        if !model.dna.isEmpty || !model.filters.tags.isEmpty || catalogue != nil {
            VStack(alignment: .leading, spacing: 10) {
                // The ALL/ANY toggle that used to sit here is gone, and the
                // measurement it was removed on has been re-taken. The
                // 2026-09-13 reading compared `tag=Isekai&tag=Regression`
                // with and without `tag_mode=or` — but `/v1/series/mix`
                // ignores a tag *name* outright, so that pair of requests was
                // the same unfiltered blend twice and measured nothing about
                // `tag_mode`. Re-measured 2026-09-14 with ids, which the
                // endpoint does honour: `tag=94&tag=1180` answers the same
                // ids with `tag_mode=or`, with `=and`, and with neither. The
                // conclusion stands on the new reading — a control whose two
                // states send the same request is not a control — and
                // `SearchQuery` sends `tag_mode=and` regardless of what
                // `tagMode` holds in any case (see its doc comment).
                // `TagPickerSheet.pickedTagMode` made the same call.
                Eyebrow(text: "Require tags")

                // Drawn from the blend's own DNA, so every chip is a tag this
                // blend actually contains rather than a guess at the taxonomy.
                // Anything chosen from the picker before a blend sits alongside
                // them, which is why the two lists are merged rather than
                // switched between.
                FlowLayout {
                    ForEach(pickedBeyondDNA, id: \.self) { tag in
                        chip(tag, isSelected: true) { toggleTag(tag) }
                    }
                    ForEach(model.dna.strands) { strand in
                        chip(
                            strand.name,
                            isSelected: model.filters.tags.contains(strand.name)
                        ) {
                            toggleTag(strand.name)
                        }
                    }

                    if catalogue != nil {
                        Button { isPickingTags = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .typeSymbol(size: 10, weight: .bold)
                                    .foregroundStyle(Palette.accent)
                                Text("Add tags").typeChip()
                            }
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: Metrics.headerPill)
                            .overlay(Capsule().strokeBorder(
                                Palette.borderDashed,
                                style: StrokeStyle(lineWidth: 0.5, dash: [3])
                            ))
                            .contentShape(Capsule())
                            .tapTarget()
                        }
                        .buttonStyle(.press)
                    }
                }
            }
            .padding(.top, Metrics.gapCovers)
        }
    }

    /// Tags the reader chose from the picker that the current blend's DNA does
    /// not already offer a chip for.
    ///
    /// Without this, a tag picked before the first blend vanished from the
    /// screen the moment a blend returned a DNA that did not mention it — while
    /// still filtering the results.
    var pickedBeyondDNA: [String] {
        let strands = Set(model.dna.strands.map(\.name))
        return model.filters.tags.filter { !strands.contains($0) }
    }

    func toggleTag(_ name: String) {
        if let index = model.filters.tags.firstIndex(of: name) {
            model.filters.tags.remove(at: index)
        } else {
            model.filters.tags.append(name)
        }
        // No `tagMode` write: `SearchQuery` sends `tag_mode=and` whatever the
        // field holds, so this was a write nobody read.
    }

    func toggleType(_ type: String) {
        if let index = model.filters.types.firstIndex(of: type) {
            model.filters.types.remove(at: index)
        } else {
            model.filters.types.append(type)
        }
    }

    func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .typeChip()
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .frame(minHeight: Metrics.headerPill)
                .background(
                    isSelected ? Palette.accent : Palette.surfaceChip,
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: isSelected ? 0 : 0.5))
                .tapTarget()
                .animation(Motion.reduced(Motion.snappy), value: isSelected)
        }
        .haptic(Haptics.selection, on: isSelected)
    }

    // MARK: Blend

}
