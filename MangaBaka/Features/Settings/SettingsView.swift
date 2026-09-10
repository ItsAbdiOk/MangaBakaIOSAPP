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
    let catalogue: CatalogueService
    var focusAccount = false
    let reminders: ReleaseReminders
    let onRemindersChanged: () async -> Void
    let history: HistoryStore
    let taste: TasteProfile
    @Binding var titleRevision: Int

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
                TitleSection(revision: $titleRevision)
                FormatSection(formats: formats)
                contentSection
                BlockedTagsSection(blockedTags: blockedTags, catalogue: catalogue)
                RemindersSection(reminders: reminders, onChange: onRemindersChanged)
                HistorySection(history: history)
                DataUseSection(taste: taste)
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
        SettingsSection(title: "Account", caption: nil) {
            AccountCard(
                status: status,
                hasStoredToken: storedTokenExists,
                entry: $entry,
                onSave: { await save() },
                onCheck: { await check() },
                onRemove: {
                    store.clear()
                    storedTokenExists = false
                    entry = ""
                    status = .idle
                },
                focusOnAppear: focusAccount
            )
        }
    }

    /// The opt-in for stronger content.
    ///
    /// The whole row is the control and the switch beside it is a picture.
    /// SwiftUI's real `Toggle` here only ever responded to a drag across the
    /// switch, never to an ordinary tap — verified repeatedly on device, with
    /// the drag working at the exact coordinate the tap had just failed at.
    /// Rather than keep guessing at whose gesture was winning, the row takes
    /// the tap. Worth revisiting if anyone finds the root cause.
    private var contentSection: some View {
        SettingsSection(title: "Content", caption: contentExplanation) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    ForEach(ContentPreferences.Rating.allCases, id: \.rawValue) { rating in
                        ratingRow(rating)
                        if rating != ContentPreferences.Rating.allCases.last {
                            SettingsDivider()
                        }
                    }
                }
                RefetchCallout(message: contentCacheNote)
            }
        }
    }

    private var contentExplanation: String {
        "By default you see everything rated safe or suggestive. "
            + "Turn these on to include stronger material in feeds, search and the stack."
    }

    private var contentCacheNote: String {
        "Changing this refetches your feeds. Cached copies were fetched under "
            + "the old filter, so they are discarded."
    }

    private func ratingRow(_ rating: ContentPreferences.Rating) -> some View {
        let isOn = content.preferences.allowed.contains(rating)
        let isLocked = rating == .safe

        return Button {
            guard !isLocked else { return }
            Task { await content.set(rating, allowed: !isOn) }
        } label: {
            SettingsRow(title: rating.title, caption: rating.caption) {
                // A rule, not a broken control. The row title stays at full
                // contrast: dimming the whole row is what made a deliberate
                // constraint look like a bug.
                if isLocked {
                    LockPill()
                } else {
                    SwitchIndicator(isOn: isOn)
                }
            }
        }
        .buttonStyle(.plain)
        // NOT `.disabled(isLocked)`. That was the cause of the dimmed row the
        // design board calls out by name: SwiftUI fades a disabled Button's
        // whole label, so the title went grey along with everything else and a
        // deliberate rule read as a broken control. The guard inside the action
        // is what makes the row inert; the lock pill is what says why.
        .accessibilityLabel("\(rating.title) content")
        .accessibilityValue(isLocked ? "Always on" : (isOn ? "On" : "Off"))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
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
