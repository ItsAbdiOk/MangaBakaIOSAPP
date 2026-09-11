import SwiftUI

/// Where a series has actually been published, and how far along each release
/// is.
///
/// Answers a question nothing else in the app answers — *can I buy this in my
/// language, and is it finished?* — from data that was already being fetched
/// and thrown away.
struct DetailEditions: View {
    let editions: [SeriesEdition]

    /// Enough to answer the question without becoming a table. A popular series
    /// carries a dozen; the first few are the ones a reader is looking for,
    /// because they are sorted official-first.
    private static let collapsedLimit = 4

    @State private var isExpanded = false

    private var visible: [SeriesEdition] {
        isExpanded ? editions : Array(editions.prefix(Self.collapsedLimit))
    }

    var body: some View {
        if !editions.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Editions")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    if editions.count > Self.collapsedLimit {
                        Button {
                            Motion.run(.snappy(duration: 0.22)) { isExpanded.toggle() }
                        } label: {
                            Text(isExpanded ? "Less" : "+\(editions.count - Self.collapsedLimit)")
                                .typeChip()
                                .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, edition in
                        row(edition, isLast: index == visible.count - 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                .hairlineBorder(Palette.hairline, radius: Metrics.radiusCard)
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private func row(_ edition: SeriesEdition, isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(edition.headline)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = edition.detail {
                    Text(detail)
                        .typeFootnote()
                        .foregroundStyle(Palette.textQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            // Only shown when true. "Unofficial" is not a claim the API makes,
            // and printing it for a missing flag would label a scanlation the
            // API simply said nothing about.
            if edition.licensed == true {
                Text("Official")
                    .typeFootnote()
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surface)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Palette.hairline).frame(height: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
