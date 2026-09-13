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
    /// The series' own cover, for `MissingVolumeCover` — a spine whose store
    /// sent no artwork at all.
    var seriesCover: Cover = .empty
    /// Covers `OpenLibraryCovers` found for a shelf number with none of its
    /// own, keyed by volume number — see
    /// `SeriesDetailView+Store.loadOpenLibraryCovers`.
    var openLibraryCovers: [Int: URL] = [:]
    /// Whether the `OpenLibraryCovers` gap-fill pass has been asked at all,
    /// still out, or done for this shelf — see `VolumesSection`'s own
    /// `openLibraryStatus` doc, which explains why this is one flag for the
    /// whole row rather than per spine. Drives `MissingVolumeCover.caption`.
    var openLibraryStatus: MissingVolumeCover.SourceState = .notAsked

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
                        ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                            Button {
                                if let url = volume.link { openURL(url) }
                            } label: {
                                spine(volume)
                            }
                            .buttonStyle(.press(haptic: .selection))
                            .disabled(volume.link == nil)
                            .arrives(index: index)
                            .enterScale()
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
    ///
    /// Gap 66: the "on Apple Books" half used to be dropped — "15 of 27" read
    /// as the series being incomplete, when it is this one store that is.
    var countLine: String {
        if let expected, !Self.covers(volumes, through: expected) {
            return "\(volumes.count) of \(expected) on \(sourceStoreName)"
        }
        return "\(volumes.count)"
    }

    /// The store this count is short against — Apple's own, unless the shelf
    /// is the Japanese fallback, which is Apple's Japanese storefront either
    /// way.
    private var sourceStoreName: String {
        edition == .japanese ? "the Japanese Apple Books" : "Apple Books"
    }

    /// Whether the shelf holds every number from 1 to `expected` — a count
    /// alone can't tell "1-15" from "1-14 and 30": both are 15 volumes, but
    /// only one of them is the series (S12, 2026-09-13).
    nonisolated static func covers(_ volumes: [ShelfVolume], through expected: Int) -> Bool {
        guard expected > 0 else { return true }
        let have = Set(volumes.map(\.number))
        return (1...expected).allSatisfy(have.contains)
    }

    /// "Apple & Google Books" when both put a volume on the shelf, with
    /// "& Open Library" appended when a spine on it is showing a cover that
    /// store never sent — naming Open Library is not a courtesy any more
    /// than naming Google is; both ask for it. The Japanese note keeps its
    /// own wording, since that shelf is Apple's alone.
    private var sourceLabel: String {
        if edition == .japanese { return "Japanese edition · Apple Books" }
        return VolumeShelf.attribution(for: volumes, openLibraryUsed: usesOpenLibraryCover)
            ?? "Apple Books"
    }

    /// Whether any spine on this shelf is drawing an Open Library cover
    /// rather than the store's own — see `resolvedCover`.
    private var usesOpenLibraryCover: Bool {
        volumes.contains { $0.cover.raw == nil && openLibraryCovers[$0.number] != nil }
    }

    /// The spine's artwork: the store's own, or an Open Library fill for it
    /// when the store sent none — never a fill for a spine that already has
    /// art of its own.
    private func resolvedCover(_ volume: ShelfVolume) -> Cover? {
        if volume.cover.raw != nil { return volume.cover }
        guard let url = openLibraryCovers[volume.number] else { return nil }
        return Cover(raw: url, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil)
    }

    @ViewBuilder
    private func volumeCover(_ volume: ShelfVolume) -> some View {
        switch MissingVolumeCover.choice(for: resolvedCover(volume)) {
        case let .artwork(cover):
            CoverImage(
                cover: cover, width: Metrics.coverSeedWidth, radius: Metrics.radiusSeed,
                accessibilityText: "Volume \(volume.number)"
            )
        case .seriesCover:
            MissingVolumeCover(
                seriesCover: seriesCover, width: Metrics.coverSeedWidth,
                // `.answered`: this row only ever renders once Apple has
                // already answered with volumes — that's what makes `shelf`
                // non-empty in the first place.
                apple: .answered, openLibrary: openLibraryStatus, numberLabel: "\(volume.number)"
            )
        }
    }

    private func spine(_ volume: ShelfVolume) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            volumeCover(volume)
            // Gap 65: with no link at all, this button did nothing on tap and
            // looked exactly like every spine that opens the store — the
            // `PressStyle` `.press` gives every button the same highlight
            // regardless of whether `disabled(volume.link == nil)` above ever
            // fires. Dimmed here, at the one call site that actually knows
            // which spines have nowhere to go, rather than widening
            // `PressStyle` itself for a case only this row has today.
            Text("Vol. \(volume.number)")
                .typeCardTitle()
                .foregroundStyle(volume.link == nil ? Palette.textMuted : Palette.textPrimary)
            // Apple's price beside the cover: what it costs is the first
            // thing a reader deciding whether to buy wants to know.
            if edition == nil, let price = volume.formattedPrice {
                Text(price)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(width: Metrics.coverSeedWidth, alignment: .leading)
        .opacity(volume.link == nil ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                "Volume \(volume.number)",
                // The spine's own accessibility element (`children: .ignore`
                // above) means `MissingVolumeCover`'s label is never read —
                // this is the one place VoiceOver is told the box is a
                // stand-in, not the store's own art. Says the same thing the
                // on-screen caption does — see `VolumesSection`'s matching
                // accessibility label.
                resolvedCover(volume) == nil
                    ? MissingVolumeCover.accessibilityText(apple: .answered, openLibrary: openLibraryStatus)
                    : nil,
                edition == nil ? volume.formattedPrice : nil
            ].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint(
            volume.link == nil ? ""
                : volume.source == .googleBooks ? "Opens it on Google Books" : "Opens it in Apple Books"
        )
        .accessibilityAddTraits(volume.link == nil ? [] : .isButton)
    }
}
