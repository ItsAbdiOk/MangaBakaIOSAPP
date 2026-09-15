import SwiftUI

/// One volume, and the editions of it.
///
/// Split out of `VolumesSection.swift` on 2026-09-15 to stay under the
/// project's file-length ceiling once the volume detail grew a blurb, a
/// trim size, an "Extra" chip, a part-of-volume note and a catalogue note —
/// no behavior changed in the split itself.
struct VolumeSheet: View {
    let volume: SeriesWork.Volume
    /// The series' own description, so the blurb below can skip repeating
    /// it verbatim — wired from `SeriesDetailView+Store` through
    /// `VolumesSection`. Nil (a preview, an older caller) shows the blurb
    /// regardless.
    var seriesDescription: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Bumped per ISBN copy, for the haptic; see `Haptics`.
    @State private var copies = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ForEach(volume.editions) { edition in
                        editionCard(edition, label: volume.editionLabels[edition.id])
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Palette.ground)
            .navigationTitle(volume.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
    }

    /// The volume's own blurb, unless it is word-for-word the series'
    /// description — see `seriesDescription`'s doc comment for why that
    /// comparison so often has nothing to compare against yet.
    private var blurb: String? {
        guard let text = volume.blurb, !text.isEmpty else { return nil }
        if let seriesDescription, text == seriesDescription { return nil }
        return text
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(
                cover: volume.cover ?? Cover.empty,
                width: Metrics.coverSeedWidth,
                radius: Metrics.radiusSeed,
                accessibilityText: volume.label
            )
            VStack(alignment: .leading, spacing: 6) {
                if volume.isExtra {
                    Text("Extra")
                        .typeChip()
                        .foregroundStyle(Palette.textMuted)
                }
                if let subTitle = volume.subTitle {
                    Text(subTitle)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let blurb {
                    Text(blurb)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let partOfVolumeLabel = volume.partOfVolumeLabel {
                    Text(partOfVolumeLabel)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                if let date = volume.date {
                    // `.timeZone(.gmt)`: `date` is UTC midnight (S2) — the
                    // device zone would print 31 December for a 1 January
                    // release west of UTC.
                    Text(date.formatted(VolumesSection.utcDayMonthYear))
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                if volume.pages != nil || volume.trimLine != nil {
                    HStack(spacing: 8) {
                        if let pages = volume.pages {
                            Text("\(pages.formatted()) pages")
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                        }
                        if let trimLine = volume.trimLine {
                            Text(trimLine)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One edition. The ISBN is shown because it is the only thing that tells
    /// a paperback from a hardcover when the covers and titles are identical —
    /// and because it is what a reader takes to a bookshop.
    ///
    /// `label` comes from `SeriesWork.Volume.editionLabels`: without a price,
    /// it replaces the repeated "Price not listed" headline (three identical
    /// cards for Hunter x Hunter vol. 8 was the bug report); with a price,
    /// it sits on the meta line instead so the price still leads.
    /// The price when there is one; otherwise the label that tells this
    /// edition from its siblings, so three cards never read the same.
    private func headline(_ edition: SeriesWork, label: String?) -> some View {
        Text(edition.price ?? label ?? "Price not listed")
            .typeDetailSectionHeader()
            .foregroundStyle(edition.price == nil ? Palette.textMuted : Palette.textPrimary)
    }

    private func editionCard(_ edition: SeriesWork, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                headline(edition, label: label)
                Spacer(minLength: 8)
                if let pages = edition.pages {
                    Text("\(pages.formatted()) pp")
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            if edition.price != nil, let label {
                Text(label)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }

            if let note = edition.note {
                Text(note)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }

            if let isbn = edition.isbn {
                isbnButton(isbn)
            }

            if let link = edition.buyLink {
                buyButton(link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
    }

    /// Copies the ISBN to the pasteboard — the form a reader takes to a
    /// bookshop, and the only thing that tells two otherwise-identical
    /// editions apart.
    private func isbnButton(_ isbn: String) -> some View {
        Button {
            UIPasteboard.general.string = isbn
            copies += 1
        } label: {
            HStack(spacing: 6) {
                Text("ISBN \(isbn)")
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(minHeight: Metrics.tapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .haptic(Haptics.copied, onEach: copies)
        .accessibilityLabel("ISBN \(isbn)")
        .accessibilityHint("Copies the ISBN")
    }

    private func buyButton(_ link: URL) -> some View {
        Button { openURL(link) } label: {
            HStack(spacing: 6) {
                Text("Buy from the publisher")
                    .typeCTA()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityHint("Opens the publisher's page in the browser")
    }
}
