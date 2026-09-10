import SwiftUI

/// Settings, including entering a personal access token.
///
/// The token is a stopgap until OAuth exists: a PAT never expires and is not
/// scoped, so this screen says that plainly rather than presenting it as the
/// normal way to sign in.
struct SettingsView: View {
    let validate: (String) async -> TokenCheck
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore
    let blockedTags: BlockedTagsStore
    let history: HistoryStore

    @State private var entry = ""
    @State private var status: TokenStatus = .idle
    @State private var storedTokenExists = TokenStore().read() != nil
    private let store = TokenStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Settings")
                    .typeScreenTitle()
                    .foregroundStyle(Palette.textPrimary)

                accountSection
                FormatSection(formats: formats)
                contentSection
                blockedSection
                HistorySection(history: history)
                AttributionSection()
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task {
            if storedTokenExists, case .idle = status { await check() }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Account")

            switch status {
            case let .signedIn(name):
                HStack(spacing: 10) {
                    Circle().fill(Palette.positive).frame(width: 6, height: 6)
                    Text(name.map { "Signed in as \($0)" } ?? "Signed in")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                }
                Button("Remove token", role: .destructive) {
                    store.clear()
                    storedTokenExists = false
                    entry = ""
                    status = .idle
                }
                .typeRowTitle()
                .foregroundStyle(Palette.accent)

            default:
                Text("""
                Paste a personal access token to see your own library and \
                recommendations. It is stored in this device's Keychain, never \
                in the app itself.
                """)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)

                SecureField("mb-…", text: $entry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.field)
                    .background(Palette.surfaceField, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))

                if let message = status.message {
                    Text(message)
                        .typeSmallMeta()
                        .foregroundStyle(
                            // A rejection is the reader's problem to fix; an
                            // unreachable server is not, and colouring both in
                            // the accent reads as two errors.
                            status.isRejection ? Palette.accent : Palette.textTertiary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if status == .checking {
                            ProgressView().tint(Palette.onAccent)
                        } else {
                            Text("Save token").typeCTA()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaDetail)
                    // onAccent is a near-black brown that only works ON the
                    // accent fill. On the disabled grey it was black on black —
                    // invisible rather than dimmed.
                    .foregroundStyle(
                        TokenStore.looksValid(entry) ? Palette.onAccent : Palette.textTertiary
                    )
                    .background(
                        TokenStore.looksValid(entry) ? Palette.accent : Palette.surfaceChip,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!TokenStore.looksValid(entry) || status == .checking)

                Text("""
                A token never expires and is not limited in what it can do, so \
                treat it like a password. Proper sign-in replaces this later.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
            }
        }
    }

    /// The opt-in for stronger content.
    ///
    /// Deliberately plain about what changes rather than a switch buried in a
    /// list: the default excludes explicit material, so turning it on should be
    /// a decision rather than an accident.
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Content")

            Text(contentExplanation)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)

            VStack(spacing: 0) {
                ForEach(ContentPreferences.Rating.allCases, id: \.rawValue) { rating in
                    ratingRow(rating)
                    if rating != ContentPreferences.Rating.allCases.last {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)

            Text(contentCacheNote)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
        }
    }

    private var contentExplanation: String {
        "By default you see everything rated safe or suggestive. "
            + "Turn these on to include stronger material in feeds, search and the stack."
    }

    private var contentCacheNote: String {
        "Changing this clears downloaded feeds, because they were fetched "
            + "under the previous setting."
    }

    private func ratingRow(_ rating: ContentPreferences.Rating) -> some View {
        let isOn = content.preferences.allowed.contains(rating)
        let isLocked = rating == .safe
        // A Button rather than a bare Toggle. SwiftUI's Toggle here would only
        // respond to a drag across the switch, never to an ordinary tap —
        // verified repeatedly on device, with the drag working at the exact
        // coordinate the tap failed at. Rather than keep guessing at whose
        // gesture was winning, the whole row is the control, and the switch
        // beside it is presentation.
        return Button {
            guard !isLocked else { return }
            Task { await content.set(rating, allowed: !isOn) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rating.title)
                        .typeRowTitle()
                        .foregroundStyle(isLocked ? Palette.textTertiary : Palette.textPrimary)
                    if isLocked {
                        Text("Always included")
                            .typeGridMeta()
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SwitchIndicator(isOn: isOn, isLocked: isLocked)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            // minHeight rather than height: these rows hold two lines of scaled
            // text, and a fixed height made one row's caption overlap the next
            // row's title at accessibility sizes.
            .frame(minHeight: Metrics.ctaSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityLabel("\(rating.title) content")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// What the reader has hidden by theme rather than by rating.
    ///
    /// Blocking happens in Browse, where the tags are. This is where someone
    /// looks when they want to know what they have hidden from themselves — a
    /// list they cannot find is indistinguishable from a broken app.
    @ViewBuilder
    private var blockedSection: some View {
        if !blockedTags.blocked.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Blocked tags")
                Text("""
                Hidden everywhere, whatever a series is rated. Unblock from the \
                tag list in Browse.
                """)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: 7) {
                    ForEach(blockedTags.blocked.tags) { tag in
                        Button {
                            Task { await blockedTags.toggle(id: tag.id, name: tag.name) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(tag.name).typeChip()
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Palette.surfaceChip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Unblock \(tag.name)")
                    }
                }
            }
        }
    }

    private func save() async {
        status = .checking
        guard store.write(entry) else {
            status = .failed("Could not save to the Keychain.")
            return
        }
        storedTokenExists = true
        await check()
        if case .failed = status {
            // A token MangaBaka rejected is worse than none: it would make
            // every authenticated call fail quietly. Only an actual rejection
            // gets here — an unreachable server leaves the token alone, because
            // deleting a credential over a dropped connection is a way to lose
            // someone's account access for them.
            store.clear()
            storedTokenExists = false
        }
    }

    private func check() async {
        status = .checking
        switch await validate(entry) {
        case let .accepted(name):
            status = .signedIn(name)
            entry = ""
        case .rejected:
            status = .failed("That token was not accepted by MangaBaka.")
        case let .unknown(reason):
            // Not a verdict on the token. Saying so matters twice over: the
            // reader is not told their token is bad when it is not, and `save`
            // does not delete it.
            status = .unverified(reason)
        }
    }
}
