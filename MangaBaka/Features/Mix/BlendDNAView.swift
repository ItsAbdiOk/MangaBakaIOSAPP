import SwiftUI

/// The blend's DNA: ten weighted tags, each one switchable.
///
/// **Include and exclude are the only controls the API has.** `/v1/series/mix`
/// takes `tag` and `tag_not` and has no weight or boost parameter, so there is
/// no slider here and there should never be one. The weights re-derive
/// server-side after every edit, which is why the change summary underneath is
/// the reward for touching anything.
struct BlendDNAView: View {
    let dna: BlendDNA
    let excluded: Set<Int>
    /// Strands switched off. They are gone from `dna` — the API stops
    /// returning an excluded tag — so they are carried separately and shown
    /// struck through, or the control would only work in one direction.
    let excludedStrands: [BlendDNA.Strand]
    let moves: [BlendDNA.Move]
    let isEdited: Bool
    let onToggle: (Int) -> Void
    let onReset: () -> Void

    /// Shared between every chip so a re-blend moves the ones that survive
    /// rather than removing and re-inserting them in a new order.
    @Namespace private var chipTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Blend DNA")
                .padding(.horizontal, 2)

            FlowLayout(spacing: 7) {
                ForEach(dna.strands) { strand in
                    strandChip(strand)
                }
                ForEach(excludedStrands) { strand in
                    strandChip(strand)
                }
            }
            .padding(.top, 10)
            // Re-blending changes which strands are present and how they're
            // ordered; `matchedGeometryEffect` on each chip (below) plus this
            // spring is what turns that into chips sliding to new positions
            // rather than the whole row cutting to a new one.
            .animation(
                Motion.reduced(Motion.settle),
                value: (dna.strands.map(\.tagId) + excludedStrands.map(\.tagId))
            )

            changeSummary
                .padding(.top, 16)

            Text("""
            Include and exclude are the only controls the API has — there is no \
            weight parameter, so there is no slider. Weights re-derive after \
            every edit.
            """)
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
            .padding(.horizontal, 2)
        }
    }

    /// Sized by weight, because the whole point is that some strands matter
    /// more. The range is deliberately narrow: real weights run about 0.16 down
    /// to 0.065, so scaling aggressively would make the tenth tag unreadable.
    private func strandChip(_ strand: BlendDNA.Strand) -> some View {
        let isOff = excluded.contains(strand.tagId)
        let share = dna.heaviestWeight > 0 ? strand.weight / dna.heaviestWeight : 1

        return Button { onToggle(strand.tagId) } label: {
            HStack(spacing: 7) {
                Text(strand.name)
                    .strikethrough(isOff)
                Text(Self.percent(strand.weight))
                    .typeGridMeta()
                    .opacity(0.55)
            }
            .scaledFont(
                size: 12 + 2 * share,
                weight: share > 0.75 ? .semibold : .regular,
                relativeTo: .footnote
            )
            .foregroundStyle(isOff ? Palette.textQuaternary : Palette.textBody)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(isOff ? Palette.surfaceInset : Palette.surfaceChip, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isOff ? Palette.hairline : Palette.border,
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .matchedGeometryEffect(id: strand.tagId, in: chipTransition)
        .accessibilityLabel("\(strand.name), \(Self.percent(strand.weight)) of the blend")
        .accessibilityValue(isOff ? "Excluded" : "Included")
        .accessibilityHint(isOff ? "Double tap to include" : "Double tap to exclude")
    }

    /// `nonisolated static` so `BlendDNATests` can call it directly.
    ///
    /// `weight` comes straight off the wire (`/v1/series/mix`'s `dna[].weight`,
    /// `BlendDNA.swift:15`). `JSONDecoder` rejects NaN/Inf, but a finite value
    /// at or past roughly ±9.2×10¹⁸ still traps a bare `Int(Double)` — a
    /// malformed answer would crash this row rather than misrender it (gap
    /// 1(g), FAILURES-SUMMARY.md). `Int(wholeOrClamped:)` is the same fix used
    /// at the other 26 sites in that family.
    nonisolated static func percent(_ weight: Double) -> String {
        "\(Int(wholeOrClamped: (weight * 100).rounded()))%"
    }

    /// What the last edit did. Absent on a first blend, because there is
    /// nothing to compare against and inventing movement would be worse than
    /// showing none.
    @ViewBuilder
    private var changeSummary: some View {
        if isEdited || !moves.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: moves.isEmpty ? "Edited" : "What changed")
                    .foregroundStyle(Palette.accent)

                Text(headline)
                    .typeSubsectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                if !moves.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(moves.prefix(4)) { move in
                            HStack(spacing: 9) {
                                Text(move.name)
                                    .typeInstruction()
                                    .foregroundStyle(Palette.textBody)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Self.percent(move.from))
                                    .typeSmallMeta()
                                    .foregroundStyle(Palette.textMuted)
                                Image(systemName: "arrow.right")
                                    .typeSymbol(size: 9, weight: .semibold)
                                    .foregroundStyle(Palette.accent)
                                Text(Self.percent(move.to))
                                    .typeSmallMeta()
                                    .foregroundStyle(Palette.accent)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 12)
                }

                if isEdited {
                    Button(action: onReset) {
                        Text("Start over")
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Metrics.ctaSecondary)
                            .background(Palette.surface, in: RoundedRectangle(
                                cornerRadius: 14, style: .continuous
                            ))
                            .hairlineBorder(Palette.borderPill, radius: 14)
                    }
                    .buttonStyle(.press)
                    .padding(.top, 14)
                }
            }
            .padding(15)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: 18, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: 18)
        }
    }

    /// Which strand ids entered, left, or moved between two chip orderings.
    ///
    /// Pure so the reorder a re-blend produces has a test without rendering
    /// `FlowLayout`/`matchedGeometryEffect` (this project has no
    /// ViewInspector) — `moved` is what actually decides whether the spring
    /// above has anything to animate.
    struct Diff: Equatable {
        let entered: Set<Int>
        let left: Set<Int>
        let moved: Set<Int>
    }

    nonisolated static func diff(from old: [Int], to new: [Int]) -> Diff {
        let oldSet = Set(old)
        let newSet = Set(new)
        let entered = newSet.subtracting(oldSet)
        let left = oldSet.subtracting(newSet)
        // "Moved" is a change in order among the survivors, not a change of
        // absolute index: dropping the second of three shifts the third's
        // index without it having moved past anything.
        let oldSurvivors = old.filter(newSet.contains)
        let newSurvivors = new.filter(oldSet.contains)
        var moved: Set<Int> = []
        for id in newSurvivors where oldSurvivors.firstIndex(of: id) != newSurvivors.firstIndex(of: id) {
            moved.insert(id)
        }
        return Diff(entered: entered, left: left, moved: moved)
    }

    private var headline: String {
        guard isEdited else { return "Blended from your seeds" }
        let count = excluded.count
        let tags = count == 1 ? "one tag" : "\(count) tags"
        return moves.isEmpty
            ? "Excluding \(tags). The rest re-derived."
            : "Excluding \(tags) — the blend shifted underneath."
    }
}
