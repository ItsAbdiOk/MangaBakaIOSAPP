import SwiftUI

/// The mockup's credits table: a label on the left, its value on the right,
/// hairline between rows.
///
/// Everything here was already on the screen somewhere — the publisher as a
/// chip, the content rating nowhere at all — but scattered. As a table it
/// answers the questions a reader actually arrives with in one place.
///
/// A row whose value the API did not give is omitted, never shown as "Unknown"
/// — including the anime adaptation, which used to be stated unconditionally.
/// A series whose payload carries no `anime` field has said nothing about one,
/// and "None listed" is a claim, not a shrug.
struct DetailCredits: View {
    let series: Series

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Rows the reader has opened. Publishers is the one that needs it — a
    /// popular series lists fifteen of them and the row became four lines of
    /// small print in the middle of the table.
    @State private var expandedRows: Set<String> = []

    struct Row: Identifiable {
        let id: String
        let value: String
        /// Long, list-shaped values that are worth a tap to see in full. A
        /// single publisher or a content rating has nothing to expand, and a
        /// row that responds to a tap by doing nothing is worse than one that
        /// does not respond at all.
        var isExpandable = false
    }

    private func isExpanded(_ row: Row) -> Bool { expandedRows.contains(row.id) }

    private func toggle(_ row: Row) {
        if expandedRows.contains(row.id) {
            expandedRows.remove(row.id)
        } else {
            expandedRows.insert(row.id)
        }
    }

    var rows: [Row] {
        var out: [Row] = []
        if let authors = series.authors, !authors.isEmpty {
            out.append(Row(id: "Story & art", value: authors.joined(separator: ", ")))
        }
        if let artists = series.artists, !artists.isEmpty,
           artists != series.authors {
            out.append(Row(id: "Art", value: artists.joined(separator: ", ")))
        }
        if let publishers = series.publishers, !publishers.isEmpty {
            out.append(Row(
                id: publishers.count == 1 ? "Publisher" : "Publishers",
                value: publishers.map(\.name).joined(separator: ", "),
                isExpandable: publishers.count > 1
            ))
        }
        if let contentRating = series.contentRating {
            out.append(Row(id: "Content rating", value: contentRating.capitalized))
        }
        // `exists` is the answer; the object being present is not. Checking
        // only for nil printed "Yes" for The Greatest Estate Developer, whose
        // API row is {"exists": false} — verified against the live endpoint on
        // 2026-09-10. The row is omitted when the field is absent altogether,
        // because a series fetched through a shape that does not carry it has
        // told us nothing, and "None listed" is a claim.
        if let anime = series.anime {
            out.append(Row(id: "Anime adaptation", value: anime.exists == true ? "Yes" : "None listed"))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // Label and value share a row until they cannot. At
                // accessibility sizes both halves are wide enough to overlap
                // in the middle, and "Anime adaptation" printed straight
                // through "None listed".
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.id)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                            Text(row.value)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(isExpanded(row) ? nil : 1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(row.id)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                            Spacer(minLength: 0)
                            Text(row.value)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(isExpanded(row) ? nil : 1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard row.isExpandable else { return }
                    Motion.run(.snappy(duration: 0.2)) { toggle(row) }
                }
                .padding(.vertical, 12)
                .background(Palette.surface)
                .overlay(alignment: .bottom) {
                    if index < rows.count - 1 {
                        Rectangle().fill(Palette.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        .hairlineBorder(Palette.hairline, radius: Metrics.radiusCard)
        .padding(.horizontal, Metrics.gutter)
    }
}

/// The mockup's tag row: every tag the series carries, each one a way into a
/// search for it. The app showed type, status and rating as chips here and no
/// tags at all, so the most obvious onward path on the page — "more like this,
/// specifically this part of it" — was missing.
struct DetailTags: View {
    let tags: [String]
    /// The reader's own tag affinities, lowercased. Empty means no profile, in
    /// which case the API's order stands.
    var favoured: Set<String> = []
    let onOpen: (String) -> Void

    @State private var isExpanded = false

    /// The mockup draws three tags. Real series carry far more — Solo Leveling
    /// has 43 — and rendering them all turned the page into a wall of chips
    /// eight rows deep that pushed everything below it off the screen. Twelve
    /// is roughly four rows, which reads as a summary rather than a dump, and
    /// the rest are one tap away.
    static let collapsedLimit = 12

    /// The reader's own interests first, then the API's order.
    ///
    /// This is what makes the cap defensible. Without it the twelve shown are
    /// whichever the API listed first, so a reader who reads fantasy and action
    /// can have both sitting behind "+104 more" on a series that is exactly
    /// what they like.
    var ordered: [String] {
        TagOrdering.favouredFirst(tags, favoured: favoured)
    }

    var visible: [String] {
        isExpanded ? ordered : Array(ordered.prefix(Self.collapsedLimit))
    }

    var hiddenCount: Int { max(0, tags.count - Self.collapsedLimit) }

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: Metrics.gapChips) {
                ForEach(visible, id: \.self) { tag in
                    let isMine = TagOrdering.isFavoured(tag, favoured: favoured)
                    Button { onOpen(tag) } label: {
                        Text(tag)
                            .typeChip()
                            // Marked, not shouted: the ordering already does
                            // the work, and a row of accent chips would read as
                            // selection rather than affinity.
                            .foregroundStyle(isMine ? Palette.accent : Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                            .frame(minHeight: Metrics.headerPill)
                            .background(Palette.surfaceChip, in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                isMine ? Palette.accent.opacity(0.45) : Palette.border,
                                lineWidth: 0.5
                            ))
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel(isMine ? "\(tag), one of your interests" : tag)
                    .accessibilityHint("Search for this tag")
                }
                if hiddenCount > 0, !isExpanded {
                    Button { isExpanded = true } label: {
                        Text("+\(hiddenCount) more")
                            .typeChip()
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: Metrics.headerPill)
                            .background(Palette.surfaceChip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Show \(hiddenCount) more tags")
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }
}
