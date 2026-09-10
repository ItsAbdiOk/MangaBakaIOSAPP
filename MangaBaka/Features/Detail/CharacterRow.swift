import SwiftUI

/// The cast, as portraits between the synopsis and the tags.
///
/// Deliberately quiet: circular portraits and a name, no roles printed. The
/// main characters lead, so the ordering carries the role information without
/// a row of "SUPPORTING" labels doing it out loud.
struct CharacterRow: View {
    let characters: [SeriesCharacter]
    let isLoading: Bool

    /// Big enough to recognise a face, small enough that four or five fit
    /// across a phone.
    private static let portrait: CGFloat = 72
    /// A rounded square, not a circle. A circle takes the corners off a
    /// portrait, and on this artwork the corners are where the hair, the ears
    /// and the chin are — every face lost something to it.
    private static let radius: CGFloat = 16

    var body: some View {
        if isLoading {
            placeholders
        } else if !characters.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text("Characters")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(characters) { character in
                            portraitCell(character)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func portraitCell(_ character: SeriesCharacter) -> some View {
        VStack(spacing: 7) {
            AsyncImage(url: character.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Palette.imagePlaceholder
            }
            // Top-aligned, because these portraits are taller than they are
            // wide and the face is at the top of them. Centring the crop —
            // which is what a plain fill does — trades the head for the torso.
            .frame(width: Self.portrait, height: Self.portrait, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 0.5)
            )

            Text(character.name)
                .typeGridMeta()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.portrait + 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            character.isMain ? "\(character.name), main character" : character.name
        )
    }

    /// Shown while Shikimori is answering. A row that appears late pushes the
    /// tags and everything under them down the page as the reader is reading,
    /// so the space is reserved rather than filled in afterwards.
    private var placeholders: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Characters")
                .typeDetailSectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Metrics.gutter)

            HStack(spacing: Metrics.gapCovers) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .fill(Palette.imagePlaceholder)
                        .frame(width: Self.portrait, height: Self.portrait)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .accessibilityHidden(true)
    }
}
