import SwiftUI
import Translation

/// A character's full profile: portrait, names, the facts the source tracks,
/// and a cleaned description — from AniList, or from Shikimori when AniList
/// issued this character's id (see `CharacterProfileRequest`).
///
/// ```swift
/// .sheet(item: $tappedCharacter) { character in
///     CharacterProfileView(character: character)
/// }
/// ```
///
/// **Shikimori's description is Russian.** It is translated on-device before
/// this view ever shows it, and if translation is unavailable, still
/// downloading, or fails, the description is dropped rather than shown in
/// Russian — see `beginShowing` and `translateIfNeeded`. Nothing else about
/// the profile waits on that: the portrait, names and facts render as soon as
/// Shikimori answers.
struct CharacterProfileView: View {
    let character: SeriesCharacter
    /// Injectable for previews and tests; defaults to a real client in the app.
    var aniList: AniListClient = AniListClient()
    /// Injectable for previews and tests; defaults to a real client in the app.
    var shikimori: ShikimoriClient = ShikimoriClient()

    @State private var state: LoadState = .loading
    /// Set once a Shikimori profile with a real description has loaded, and
    /// consumed the first time `.translationTask` hands back a session.
    /// Holding the description here, not the whole profile, means a second
    /// translation attempt (a config change) can never re-translate an
    /// already-translated result.
    @State private var pendingTranslation: CharacterDescription?
    @State private var translationConfiguration: TranslationSession.Configuration?
    /// Set when a Shikimori profile had a description but this device could
    /// not translate it — an already-installed language pack is the only
    /// path that does not risk the crash `TranslationGate` documents, so a
    /// reader without one used to simply never see a description with
    /// nothing saying why (gap 60).
    @State private var descriptionNote: String?
    @Environment(\.dismiss) private var dismiss

    /// Russian is the only source language this view ever asks the
    /// Translation framework about — Shikimori's site language, verified
    /// live on 2026-09-12 against every description fetched during this work.
    /// Shared with `TranslationSection`, which offers the download this view
    /// cannot, via `TranslationGate` so the two screens cannot drift onto
    /// different language pairs.
    private static let sourceLanguage = TranslationGate.sourceLanguage
    private static let targetLanguage = TranslationGate.targetLanguage
    /// How long a translation is allowed to run before the profile is shown
    /// without its description. A guess: long enough for an already-installed
    /// language pack to translate a short paragraph, short enough that a
    /// reader who declines the system's download prompt is not left staring
    /// at a spinner for it.
    private static let translationTimeout: TimeInterval = 10

    enum LoadState {
        case loading
        case loaded(CharacterProfile)
        case failed(APIError)
        /// Neither source issued this character's id. Not reachable today —
        /// `CharacterSource` has exactly two cases and both now have a
        /// profile path — kept because `CharacterProfileRequest` returning
        /// nil for both is a real possibility the type system allows, and
        /// this view should not force-unwrap its way past it.
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
        .translationTask(translationConfiguration) { session in
            await translateIfNeeded(session: session)
        }
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
            CharacterProfileContent(profile: profile, descriptionNote: descriptionNote)
        }
    }

    /// Gap 82: the copy this replaced ("Nothing knows this character by this
    /// id.") read as a debug message rather than words written for a reader.
    /// Not reachable today — `CharacterSource` has exactly two cases and both
    /// now have a profile path — but the state the type system still allows
    /// deserves real wording rather than none.
    private var unavailableState: some View {
        EmptyState(
            title: "No profile",
            message: "This character isn't linked to a profile on AniList or Shikimori."
        )
        .padding(.top, 40)
    }

    private func load() async {
        state = .loading
        descriptionNote = nil
        if let aniListID = CharacterProfileRequest.aniListID(for: character) {
            do {
                state = .loaded(try await aniList.characterProfile(characterID: aniListID))
            } catch {
                state = .failed(error)
            }
            return
        }
        if let shikimoriID = CharacterProfileRequest.shikimoriID(for: character) {
            do {
                await beginShowing(try await shikimori.characterProfile(characterID: shikimoriID))
            } catch {
                state = .failed(error)
            }
            return
        }
        state = .unavailable
    }

    /// Shows everything about a freshly-loaded profile except a description
    /// that still needs translating — the portrait and facts have nothing to
    /// wait on, and Abdi's rule ("just make sure shikimori is being
    /// translated before the user sees it") only concerns the description.
    private func beginShowing(_ profile: CharacterProfile) async {
        guard profile.requiresTranslation, let description = profile.description, !description.isEmpty else {
            state = .loaded(profile)
            return
        }
        state = .loaded(profile.withDescription(nil))

        // Checked before ever setting `translationConfiguration`, because
        // `.translationTask` raising the system download prompt from inside
        // this sheet is what killed TestFlight build 64. Only an already
        // installed pack translates without any system UI — see
        // `TranslationGate`, which carries the crash report's reasoning.
        let availability = await LanguageAvailability().status(
            from: Self.sourceLanguage, to: Self.targetLanguage
        )
        guard TranslationGate.allows(availability) else {
            // Gap 60: this used to return here in silence — the description
            // simply never appeared, with nothing telling a reader Shikimori
            // actually had one. Asking for a session anyway is what raises
            // the system download prompt `TranslationGate`'s doc comment
            // traces to a crash, so the description stays dropped either
            // way; the difference is only whether the reader is told why.
            descriptionNote = """
            This character's description is in Russian, and this device \
            hasn't downloaded the language pack needed to translate it.
            """
            return
        }

        pendingTranslation = description
        translationConfiguration = TranslationSession.Configuration(
            source: Self.sourceLanguage, target: Self.targetLanguage
        )
    }

    /// Runs once a translation session is ready — which, per Apple's own
    /// framework, may itself be after the system has prompted the reader to
    /// download the ru→en language pack. If that never resolves, times out,
    /// or the session refuses, the description stays dropped: showing the
    /// Russian original is the one outcome ruled out, and there is no
    /// "view original" escape hatch.
    private func translateIfNeeded(session: TranslationSession) async {
        guard let description = pendingTranslation, case let .loaded(profile) = state else { return }
        pendingTranslation = nil

        // Awaited directly, with no watchdog task. An earlier version raced
        // a timeout task against the translation, but the closure had to
        // capture the `TranslationSession` SwiftUI hands this view — which is
        // non-Sendable, so sending it into a `Task` is a hard error under
        // Swift 6.
        //
        // Nothing is lost. `beginShowing` has already put the profile on
        // screen without its description, so a translation that never
        // finishes and one that times out produce exactly the same thing the
        // reader sees: the portrait, the names and the facts, and no
        // description. Nothing is blocked waiting on this.
        do {
            let translated = try await CharacterDescriptionTranslator.translate(
                description, using: SystemDescriptionTranslator(session: session)
            )
            state = .loaded(profile.withDescription(translated))
        } catch {
            // Left as `profile.withDescription(nil)`, already showing.
        }
    }
}

/// The loaded profile's body, split out so `CharacterProfileView` only holds
/// loading state and this only holds spoiler-reveal state.
private struct CharacterProfileContent: View {
    let profile: CharacterProfile
    /// Why there is no description below the facts, when there should have
    /// been one — see `CharacterProfileView.descriptionNote`.
    var descriptionNote: String?
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
            } else if let descriptionNote {
                Text(descriptionNote)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.gutter)
            }
            if let siteURL = profile.siteURL {
                sourceLink(siteURL, source: profile.source)
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

    /// "View on AniList" or "View on Shikimori" — whichever source actually
    /// answered this profile, since both now can.
    private func sourceLink(_ url: URL, source: CharacterSource) -> some View {
        let name = source == .aniList ? "AniList" : "Shikimori"
        return Link(destination: url) {
            HStack(spacing: 5) {
                Text("View on \(name)")
                    .typeCTA()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)
        }
        .accessibilityLabel("Open this character's \(name) page")
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
            case let .italic(string):
                var part = AttributedString(string)
                part.inlinePresentationIntent = .emphasized
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
