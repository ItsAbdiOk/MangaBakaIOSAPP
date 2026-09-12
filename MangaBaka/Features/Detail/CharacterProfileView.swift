import SwiftUI

/// A character's full AniList profile: portrait, names, the facts AniList
/// tracks, and a cleaned description.
///
/// **Entry point only — not wired up here.** `CharacterRow.swift` and
/// `SeriesDetailView.swift` are being edited elsewhere in parallel, so this
/// view is self-contained and ready to present as a sheet:
///
/// ```swift
/// .sheet(item: $tappedCharacter) { character in
///     CharacterProfileView(character: character)
/// }
/// ```
///
/// Whether the portrait should even be tappable for a Shikimori-sourced
/// character is a decision for whoever wires the tap — this view handles
/// that case gracefully either way (see `LoadState.unavailable`), so gating
/// the tap is an optional refinement, not a requirement.
struct CharacterProfileView: View {
    let character: SeriesCharacter
    /// Injectable for previews and tests; defaults to a real client in the app.
    var aniList: AniListClient = AniListClient()

    @State private var state: LoadState = .loading
    @Environment(\.dismiss) private var dismiss

    enum LoadState {
        case loading
        case loaded(CharacterProfile)
        case failed(APIError)
        /// The cast row answered from Shikimori, whose id cannot be used to
        /// ask AniList for anything — see `CharacterProfileRequest`. Not an
        /// error: nothing went wrong, there is simply no AniList profile for
        /// this character to show.
        case unavailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.top, Metrics.scrollTopInset)
                    .padding(.bottom, Metrics.scrollBottomInset)
            }
            .background(Palette.ground)
            .navigationTitle(character.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .padding(.top, 80)
        case let .failed(error):
            FailureState(error: error) { await load() }
        case .unavailable:
            unavailableState
        case let .loaded(profile):
            CharacterProfileContent(profile: profile)
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
            Text("No AniList profile")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text("""
            This character's cast entry came from a different tracker, \
            which doesn't carry a full profile.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 40)
        }
        .padding(.top, 60)
    }

    private func load() async {
        guard let aniListID = CharacterProfileRequest.aniListID(for: character) else {
            state = .unavailable
            return
        }
        do {
            state = .loaded(try await aniList.characterProfile(characterID: aniListID))
        } catch {
            state = .failed(error)
        }
    }
}

/// The loaded profile's body, split out so `CharacterProfileView` only holds
/// loading state and this only holds spoiler-reveal state.
private struct CharacterProfileContent: View {
    let profile: CharacterProfile
    /// Indices into `profile.description.blocks`. Once revealed a spoiler
    /// stays revealed, matching `DetailTagSections`' own spoiler chips —
    /// hiding it again after the reader chose to see it would be the
    /// surprising behaviour, not the safe one.
    @State private var revealedSpoilers: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.detailRowGap) {
            header
            if !profile.facts.isEmpty {
                factsTable
            }
            if let description = profile.description, !description.isEmpty {
                descriptionSection(description)
            }
            if let siteURL = profile.siteURL {
                aniListLink(siteURL)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AsyncImage(url: profile.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Palette.imagePlaceholder
            }
            .frame(width: 132, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 0.5)
            )
            .copyableArtwork(profile.imageURL, noun: "portrait")

            VStack(spacing: 4) {
                Text(profile.fullName)
                    .typeDetailHeroTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)

                if let native = profile.nativeName, !native.isEmpty {
                    Text(native)
                        .typeSubtitle()
                        .foregroundStyle(Palette.textSecondary)
                }
                if !profile.alternativeNames.isEmpty {
                    Text(profile.alternativeNames.joined(separator: " · "))
                        .typeFootnote()
                        .foregroundStyle(Palette.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.gutter)
    }

    /// The same label-left, value-right, hairline-between-rows table
    /// `DetailCredits` draws for a series — a character's facts are the same
    /// shape of question, so they get the same answer.
    private var factsTable: some View {
        VStack(spacing: 0) {
            ForEach(Array(profile.facts.enumerated()), id: \.offset) { index, fact in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(fact.label)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                    Spacer(minLength: 0)
                    Text(fact.value)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    if index < profile.facts.count - 1 {
                        Rectangle().fill(Palette.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        .hairlineBorder(Palette.hairline, radius: Metrics.radiusCard)
        .padding(.horizontal, Metrics.gutter)
    }

    @ViewBuilder
    private func descriptionSection(_ description: CharacterDescription) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("About")
                .typeDetailSectionHeader()
                .foregroundStyle(Palette.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(description.blocks.enumerated()), id: \.offset) { index, block in
                    if block.isSpoiler, !revealedSpoilers.contains(index) {
                        spoilerToggle(index)
                    } else {
                        Text(attributed(for: block.spans))
                            .typeBody()
                            .foregroundStyle(Palette.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// One chip per spoiler block, matching `DetailTagSections.spoilerToggle`
    /// exactly — same icon, same dashed capsule, same "reveal, don't hide
    /// again" behaviour — so a reader who has already learned what a spoiler
    /// chip does on the tags row recognises this one immediately.
    private func spoilerToggle(_ index: Int) -> some View {
        Button {
            Motion.run(.snappy(duration: 0.22)) { _ = revealedSpoilers.insert(index) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text("Spoiler")
                    .typeChip()
            }
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.headerPill)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.borderDashed, style: StrokeStyle(
                lineWidth: 0.5, dash: [3]
            )))
            .tapTarget()
        }
        .buttonStyle(.press)
        .accessibilityLabel("Spoiler, hidden")
        .accessibilityHint("Reveals it")
    }

    private func aniListLink(_ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Text("View on AniList")
                    .typeCTA()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)
        }
        .accessibilityLabel("Open this character's AniList page")
        .padding(.horizontal, Metrics.gutter)
    }

    /// Builds one `AttributedString` from a block's spans, bold and links
    /// included.
    ///
    /// One attributed string rather than concatenated `Text` values: `Text +
    /// Text` is deprecated from iOS 26 and this project treats warnings as
    /// errors, so the old form did not compile. It is also the better shape —
    /// `AttributedString`'s `.link` is the one way SwiftUI puts a real,
    /// tappable link in the middle of a sentence rather than on its own line,
    /// and bold as `inlinePresentationIntent` inherits whatever font the view
    /// is using instead of pinning one.
    private func attributed(for spans: [CharacterDescription.Span]) -> AttributedString {
        var out = AttributedString()
        for span in spans {
            switch span {
            case let .plain(string):
                out += AttributedString(string)
            case let .bold(string):
                var part = AttributedString(string)
                part.inlinePresentationIntent = .stronglyEmphasized
                out += part
            case let .link(linkText, url):
                var part = AttributedString(linkText)
                part.link = url
                part.foregroundColor = Palette.accent
                out += part
            }
        }
        return out
    }
}
