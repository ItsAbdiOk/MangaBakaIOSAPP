import SwiftUI

/// The series' volumes: official covers, Apple's price where there is one,
/// and a spine that opens the book.
///
/// Shown in place of MangaBaka's own editions row when a store carries the
/// series, because it is the fuller set — ONE PIECE has 8 editions on
/// MangaBaka and 4 images, and over a hundred volumes on Apple Books — and
/// the covers are the publisher's. When the shelf has fewer than the series
/// has (`expected`, MangaBaka's `final_volume`), the header says so rather
/// than pretending it is complete.
///
/// The shelf is Apple's volumes plus any number only Google has; see
/// `VolumeShelf.merge`. The header names whichever stores contributed, which
/// is also how Google's content gets the attribution their terms require.
struct AppleVolumesRow: View {
    let volumes: [ShelfVolume]
    /// The series' final volume number, when it has ended.
    let expected: Int?
    /// Set when the shelf is another store's edition; nil for the reader's own.
    var edition: Edition?

    enum Edition {
        /// From the Japanese store, because the reader's has nothing. Covers
        /// and a count; no price, since the reader cannot buy there.
        case japanese
    }

    @Environment(\.openURL) private var openURL

    var body: some View {
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Volumes")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Text(countLine)
                        .typeChip()
                        .foregroundStyle(Palette.textMuted)
                    Spacer(minLength: 0)
                    Text(sourceLabel)
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                .padding(.horizontal, Metrics.gutter)
                if edition == .japanese {
                    Text("Not sold in your store. Covers and volume count only.")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, Metrics.gutter)
                }

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(volumes) { volume in
                            Button {
                                if let url = volume.link { openURL(url) }
                            } label: {
                                spine(volume)
                            }
                            .buttonStyle(.press)
                            .disabled(volume.link == nil)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// "15" when the store has them all or the series has not ended;
    /// "15 of 27 on Apple Books" when it has and the store is behind.
    var countLine: String {
        if let expected, expected > volumes.count {
            return "\(volumes.count) of \(expected)"
        }
        return "\(volumes.count)"
    }

    /// "Apple & Google Books" when both put a volume on the shelf. The
    /// Japanese note keeps its own wording, since that shelf is Apple's alone.
    private var sourceLabel: String {
        if edition == .japanese { return "Japanese edition · Apple Books" }
        return VolumeShelf.attribution(for: volumes) ?? "Apple Books"
    }

    private func spine(_ volume: ShelfVolume) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverImage(
                cover: volume.cover,
                width: Metrics.coverSeedWidth,
                radius: Metrics.radiusSeed,
                accessibilityText: "Volume \(volume.number)"
            )
            Text("Vol. \(volume.number)")
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
            // Apple's price beside the cover: what it costs is the first
            // thing a reader deciding whether to buy wants to know.
            if edition == nil, let price = volume.formattedPrice {
                Text(price)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(width: Metrics.coverSeedWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ["Volume \(volume.number)", edition == nil ? volume.formattedPrice : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint(
            volume.source == .googleBooks ? "Opens it on Google Books" : "Opens it in Apple Books"
        )
        .accessibilityAddTraits(.isButton)
    }
}
