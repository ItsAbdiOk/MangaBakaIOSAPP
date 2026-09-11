import SwiftUI

/// The volumes a series has actually been published in.
///
/// A row of spines, because that is how a collection is looked at. Each one
/// carries its number and the year it arrived, and opens a sheet with the
/// things you would want before buying: what it costs, how long it is, its
/// ISBN, and where the publisher sells it.
///
/// **Editions are gathered, not listed.** Solo Leveling volume 1 exists twice
/// in the API — paperback at $9.99 and hardcover at $20, told apart only by
/// their ISBNs. Twenty-five entries for thirteen volumes reads as a bug; the
/// grouping happens in `SeriesWork.volumes(from:)` and the sheet is where the
/// two editions become visible, which is where the difference matters.
struct VolumesSection: View {
    let volumes: [SeriesWork.Volume]

    @State private var opened: SeriesWork.Volume?

    var body: some View {
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Volumes")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(volumes.count)")
                        .typeChip()
                        .foregroundStyle(Palette.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(volumes) { volume in
                            Button { opened = volume } label: {
                                spine(volume)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
            .sheet(item: $opened) { volume in
                VolumeSheet(volume: volume)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(Metrics.radiusSheet)
            }
        }
    }

    private func spine(_ volume: SeriesWork.Volume) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverImage(
                cover: volume.cover ?? Cover.empty,
                width: Metrics.coverSeedWidth,
                radius: Metrics.radiusSeed,
                accessibilityText: volume.label
            )
            Text(volume.label)
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
            if let year = volume.date.map({ Calendar.current.component(.year, from: $0) }) {
                Text(String(year))
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(width: Metrics.coverSeedWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(volume))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityLabel(_ volume: SeriesWork.Volume) -> String {
        var parts = [volume.label]
        if let date = volume.date {
            parts.append(date.formatted(.dateTime.month(.wide).year()))
        }
        if volume.editions.count > 1 {
            parts.append("\(volume.editions.count) editions")
        }
        return parts.joined(separator: ", ")
    }
}

/// One volume, and the editions of it.
struct VolumeSheet: View {
    let volume: SeriesWork.Volume

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ForEach(volume.editions) { edition in
                        editionCard(edition)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(
                cover: volume.cover ?? Cover.empty,
                width: Metrics.coverSeedWidth,
                radius: Metrics.radiusSeed,
                accessibilityText: volume.label
            )
            VStack(alignment: .leading, spacing: 6) {
                if let subTitle = volume.subTitle {
                    Text(subTitle)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let date = volume.date {
                    Text(date.formatted(.dateTime.day().month(.wide).year()))
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                if let pages = volume.pages {
                    Text("\(pages.formatted()) pages")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One edition. The ISBN is shown because it is the only thing that tells
    /// a paperback from a hardcover when the covers and titles are identical —
    /// and because it is what a reader takes to a bookshop.
    private func editionCard(_ edition: SeriesWork) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(edition.price ?? "Price not listed")
                    .typeDetailSectionHeader()
                    .foregroundStyle(edition.price == nil ? Palette.textMuted : Palette.textPrimary)
                Spacer(minLength: 8)
                if let pages = edition.pages {
                    Text("\(pages.formatted()) pp")
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }

            if let isbn = edition.isbn {
                Button {
                    UIPasteboard.general.string = isbn
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                .buttonStyle(.plain)
                .accessibilityLabel("ISBN \(isbn)")
                .accessibilityHint("Copies the ISBN")
            }

            if let link = edition.buyLink {
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
                .buttonStyle(.plain)
                .accessibilityHint("Opens the publisher's page in the browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
    }
}
