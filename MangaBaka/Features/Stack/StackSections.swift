import SwiftUI

/// SKIP and SAVE, shown on the card's corners as a drag commits.
struct StackBadge: View {
    let text: String
    let fill: Color
    let textColour: Color
    let bordered: Bool

    var body: some View {
        Text(text)
            .typeBadge()
            .foregroundStyle(textColour)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(
                cornerRadius: Metrics.radiusBadge, style: .continuous
            ))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: Metrics.radiusBadge, style: .continuous)
                        .strokeBorder(Palette.glassEdge, lineWidth: 0.5)
                }
            }
    }
}

/// The block beneath the stack card: title, meta, tags, and the recommender's
/// reason when it gave one.
///
/// Its own file because StackView was at the lint's body-length ceiling. Layout
/// values are the mockup's: 19pt title, 6pt to the meta line, 12pt to the tags,
/// 26pt side padding, centred.
struct StackCaption: View {
    let series: Series
    let reason: String?
    /// Shown when a save reached the local shelf but not the account.
    let warning: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(series.displayTitle ?? "Untitled series")
                .typeStackCardTitle()
                .foregroundStyle(Palette.textPrimary)

            // Each part renders only when the source supplied it. No single
            // endpoint carries all three: the v1 blend has the year and tags
            // but no rating count, v2 search has the count but no year, and the
            // personalised recommender has only the year. Verified 2026-09-09.
            if let meta = metaLine {
                Text(meta)
                    .typeInstruction()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.top, 6)
            }

            if let tags = series.tags, !tags.isEmpty {
                // DEVIATION: the mockup centres the chip row. FlowLayout
                // left-aligns, and it is used anyway because it caps an
                // over-wide item — a long tag name at large text sizes used to
                // hang off the screen edge. Overflow is a bug; alignment is a
                // preference.
                FlowLayout(spacing: 7) {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .typeSmallMeta()
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Palette.surfaceChip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                    }
                }
                .padding(.top, 12)
            }

            if let reason {
                Text(reason)
                    .typeFootnote()
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.top, 10)
            }

            // A save that did not reach the account is worth saying once. The
            // shelf still has it, so this is a note rather than an error.
            if let warning {
                Text(warning)
                    .typeFootnote()
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 26)
        .padding(.top, 6)
    }

    private var metaLine: String? { Self.metaLine(for: series) }

    /// "Manhwa · 2022 · 7.8 from 6.4k", minus whatever is absent.
    static func metaLine(for series: Series) -> String? {
        var parts: [String] = []
        if let type = series.type, !type.isEmpty { parts.append(type.capitalized) }
        if let year = series.year { parts.append(String(year)) }
        if let rating = series.rating {
            // The API's 0-100 shown on the 10-point scale the mockup uses.
            let score = String(format: "%.1f", rating / 10)
            if let count = series.ratingCount, count > 0 {
                parts.append("\(score) from \(Self.compact(count))")
            } else {
                parts.append(score)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func compact(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : String(count)
    }
}

/// The horizontal strip of saved covers under the stack's actions.
struct StackSavedStrip: View {
    let saved: [Series]
    @Binding var path: [Series]
    /// Opens the Library tab. "Shelf ›" was styled as a link — accent colour,
    /// chevron and all — and did nothing when tapped.
    let onOpenShelf: () -> Void

    private var shelfLink: some View {
        Button(action: onOpenShelf) {
            Text("Shelf ›")
                .typeInstruction()
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the shelf")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A row until the text is large, then stacked. Side by side at
            // accessibility sizes the two collapsed into "Saved from Shelf"
            // with the rest off the screen edge.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Saved from the stack")
                        .typeSubsectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 10)
                    shelfLink
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved from the stack")
                        .typeSubsectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    shelfLink
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 10)

            if saved.isEmpty {
                Text("Nothing saved yet. Skips are remembered too, and stay recoverable in the shelf.")
                    .typeInstruction()
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                Palette.borderDashed,
                                style: StrokeStyle(lineWidth: 0.5, dash: [4, 3])
                            )
                    }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(saved) { series in
                            Button { path.append(series) } label: {
                                CoverImage(
                                    cover: series.cover,
                                    width: Metrics.coverSavedStripWidth,
                                    radius: Metrics.radiusSavedThumb,
                                    accessibilityText: series.displayTitle ?? "Untitled series"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, Metrics.gutterStack)
        .padding(.top, 26)
    }
}
