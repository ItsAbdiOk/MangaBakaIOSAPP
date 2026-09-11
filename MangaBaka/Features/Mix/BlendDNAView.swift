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
                Text(percent(strand.weight))
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
        .accessibilityLabel("\(strand.name), \(percent(strand.weight)) of the blend")
        .accessibilityValue(isOff ? "Excluded" : "Included")
        .accessibilityHint(isOff ? "Double tap to include" : "Double tap to exclude")
    }

    private func percent(_ weight: Double) -> String {
        "\(Int((weight * 100).rounded()))%"
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
                                Text(percent(move.from))
                                    .typeSmallMeta()
                                    .foregroundStyle(Palette.textMuted)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                                Text(percent(move.to))
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
                            .frame(height: Metrics.ctaSecondary)
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

    private var headline: String {
        guard isEdited else { return "Blended from your seeds" }
        let count = excluded.count
        let tags = count == 1 ? "one tag" : "\(count) tags"
        return moves.isEmpty
            ? "Excluding \(tags). The rest re-derived."
            : "Excluding \(tags) — the blend shifted underneath."
    }
}
