import SwiftUI

/// The cast, as portraits between the synopsis and the tags.
///
/// Deliberately quiet: circular portraits and a name, no roles printed. The
/// main characters lead, so the ordering carries the role information without
/// a row of "SUPPORTING" labels doing it out loud.
struct CharacterRow: View {
    let characters: [SeriesCharacter]
    let isLoading: Bool
    /// Set only when every source that was asked failed outright — see
    /// `CharacterService.CharacterCast.failed`. Nil for "asked and found
    /// nobody", which stays silent; the row used to vanish for both alike
    /// (gap 17, FAILURES-SUMMARY.md).
    var failure: APIError?
    var retry: (() async -> Void)?
    /// The app's own tracker clients, handed on to the profile sheet.
    /// `CharacterProfileView` used to build a fresh `AniListClient` and
    /// `ShikimoriClient` per open — each with its own request spacing, its
    /// own `Retry-After` backoff and its own outage memory, none of it
    /// known to the `CharacterService` that had just fetched this cast from
    /// the same two hosts (review item 63, 2026-09-14; the same shape as the
    /// two `MangaUpdatesClient`s in C4). Optional only for previews and the
    /// row's tests, which have no service; the page always passes both.
    var aniList: AniListClient?
    var shikimori: ShikimoriClient?

    enum CastState: Equatable {
        case hidden
        case loading
        case failed(APIError)
        case list
    }

    /// A pure decision, testable without building the row: a cast that
    /// answered wins even over a stored failure (a retry that then loaded
    /// something real should show it, not the stale error).
    nonisolated static func state(
        characters: [SeriesCharacter], isLoading: Bool, failure: APIError?
    ) -> CastState {
        if isLoading { return .loading }
        if !characters.isEmpty { return .list }
        if let failure { return .failed(failure) }
        return .hidden
    }

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
        let state = Self.state(characters: characters, isLoading: isLoading, failure: failure)
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case .loading:
                placeholders
                    .transition(.blurReplace)
            case let .failed(error):
                VStack(alignment: .leading, spacing: 11) {
                    Text("Characters")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, Metrics.gutter)
                    InlineFailure(error: error, retry: retry)
                }
                .transition(.blurReplace)
            case .list:
                VStack(alignment: .leading, spacing: 11) {
                    Text("Characters")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, Metrics.gutter)

                    ScrollView(.horizontal) {
                        // Lazy: an eager stack started a portrait fetch for
                        // all twenty of a cast in the first frame, none of
                        // which is cancelled on a pop (item 58).
                        LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                            ForEach(characters) { character in
                                cell(character)
                                    .arrives()
                                    .enterScale()
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                }
                .sheet(item: $opened) { character in
                    CharacterProfileView(character: character, aniList: aniList, shikimori: shikimori)
                        .presentationBackground(.ultraThinMaterial)
                }
                .transition(.blurReplace)
            }
        }
        // The skeleton, a failure, and the real cast all swap under one
        // `Motion.settle` rather than popping — the row's own "content
        // arrived" moment, distinct from `.arrives()` on each portrait
        // (which fires once the row itself is already the branch on screen).
        .animation(Motion.reduced(Motion.settle), value: state)
    }

    /// Tappable whenever there is a profile to open — AniList's own, or now
    /// Shikimori's (see `ShikimoriClient.characterProfile` and
    /// `CharacterProfileRequest`). Both sources number their characters
    /// independently, so the id sent to either service always comes from
    /// `CharacterProfileRequest`, which only ever returns an id to the
    /// service that issued it — never AniList's endpoint asked with a
    /// Shikimori id, or the reverse.
    ///
    /// A portrait that does nothing is better than one that opens a stranger:
    /// `isProfileAvailable` is kept as its own check, rather than assumed
    /// true, so a future third source with no profile path still falls back
    /// to reading as "just a picture" instead of opening one.
    @ViewBuilder
    private func cell(_ character: SeriesCharacter) -> some View {
        if CharacterProfileRequest.isProfileAvailable(for: character) {
            Button { opened = character } label: { portraitCell(character) }
                .buttonStyle(.press)
                .accessibilityHint("Opens this character's profile")
        } else {
            portraitCell(character)
        }
    }

    private func portraitCell(_ character: SeriesCharacter) -> some View {
        VStack(spacing: 7) {
            // `PortraitImage`, not `AsyncImage`: a portrait that scrolled
            // out mid-load used to stay a grey square until the sheet was
            // dismissed — the documented reason `CoverStore` exists, and the
            // bug already fixed once for covers (item 121).
            PortraitImage(url: character.imageURL, size: Self.portrait)
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
