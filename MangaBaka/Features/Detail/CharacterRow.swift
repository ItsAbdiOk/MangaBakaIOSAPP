import SwiftUI

/// The cast, as portraits between the synopsis and the tags.
///
/// Deliberately quiet: circular portraits and a name, no roles printed. The
/// main characters lead, so the ordering carries the role information without
/// a row of "SUPPORTING" labels doing it out loud.
struct CharacterRow: View {
    let characters: [SeriesCharacter]
    let isLoading: Bool

    /// The portrait the reader tapped, presented as a profile sheet.
    ///
    /// Held here rather than in `SeriesDetailView`: the row is the only thing
    /// that knows which portrait was tapped, and the page has no other use
    /// for it.
    @State private var opened: SeriesCharacter?

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
                            cell(character)
                                .arrives()
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
            .sheet(item: $opened) { CharacterProfileView(character: $0) }
        }
    }

    /// Tappable only when AniList issued the id, because only then is there a
    /// profile to open: the cast falls back to Shikimori when AniList is
    /// down, and the two number their characters independently — asking
    /// AniList about a Shikimori id returns a real profile for the wrong
    /// person rather than failing. See `CharacterProfileRequest`.
    ///
    /// A portrait that does nothing is better than one that opens a stranger,
    /// and better than one that opens an apology: on a Shikimori day the row
    /// simply is not tappable, which reads as "these are just pictures".
    @ViewBuilder
    private func cell(_ character: SeriesCharacter) -> some View {
        if CharacterProfileRequest.aniListID(for: character) == nil {
            portraitCell(character)
        } else {
            Button { opened = character } label: { portraitCell(character) }
                .buttonStyle(.press)
                .accessibilityHint("Opens this character's profile")
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
        .copyableArtwork(character.imageURL, noun: "portrait")
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
