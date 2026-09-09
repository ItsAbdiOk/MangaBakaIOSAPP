import SwiftUI

/// The mockup's credits table: a label on the left, its value on the right,
/// hairline between rows.
///
/// Everything here was already on the screen somewhere — the publisher as a
/// chip, the content rating nowhere at all — but scattered. As a table it
/// answers the questions a reader actually arrives with in one place.
///
/// A row whose value the API did not give is omitted, never shown as "Unknown".
/// The one exception is the anime adaptation, where "None listed" is a real
/// answer: the API says whether it knows of one, so silence would be
/// indistinguishable from a missing field.
struct DetailCredits: View {
    let series: Series

    struct Row: Identifiable {
        let id: String
        let value: String
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
            out.append(Row(id: publishers.count == 1 ? "Publisher" : "Publishers",
                           value: publishers.map(\.name).joined(separator: ", ")))
        }
        if let contentRating = series.contentRating {
            out.append(Row(id: "Content rating", value: contentRating.capitalized))
        }
        out.append(Row(id: "Anime adaptation", value: series.anime == nil ? "None listed" : "Yes"))
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(row.id)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textQuaternary)
                    Spacer(minLength: 0)
                    Text(row.value)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
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
    let onOpen: (String) -> Void

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: Metrics.gapChips) {
                ForEach(tags, id: \.self) { tag in
                    Button { onOpen(tag) } label: {
                        Text(tag)
                            .typeChip()
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                            .frame(minHeight: Metrics.headerPill)
                            .background(Palette.surfaceChip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Search for this tag")
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }
}
