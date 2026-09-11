import SwiftUI

/// The series' volumes on Apple Books: official covers, the price, and a
/// spine that opens the book to buy.
///
/// Shown in place of MangaBaka's own editions row when the store carries the
/// series, because it is the fuller set — ONE PIECE has 8 editions on
/// MangaBaka and 4 images, and over a hundred volumes on Apple Books — and
/// the covers are the publisher's. When the store carries fewer than the
/// series has (`expected`, MangaBaka's `final_volume`), the header says so
/// rather than pretending the shelf is complete.
struct AppleVolumesRow: View {
    let volumes: [AppleBooksVolume]
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
                    Text(edition == .japanese ? "Japanese edition · Apple Books" : "Apple Books")
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
                                if let url = volume.storeURL { openURL(url) }
                            } label: {
                                spine(volume)
                            }
                            .buttonStyle(.press)
                            .disabled(volume.storeURL == nil)
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

    private func spine(_ volume: AppleBooksVolume) -> some View {
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
        .accessibilityHint("Opens it in Apple Books")
        .accessibilityAddTraits(.isButton)
    }
}
