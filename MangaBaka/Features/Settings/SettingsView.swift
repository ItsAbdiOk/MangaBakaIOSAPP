import SwiftUI

/// The Keychain operations `SettingsView` needs, seamed behind a protocol so
/// a save failure (gap 118) can be driven from a test double — the real
/// Keychain cannot be made to refuse a write on demand the way a network
/// stub can be made to answer any status code.
protocol TokenPersisting: Sendable {
    func read() -> String?
    @discardableResult func write(_ token: String) -> Bool
    @discardableResult func clear() -> Bool
}

extension TokenStore: TokenPersisting {}

extension APIError {
    /// A short phrase for the account card's cramped "not checked yet" line,
    /// where `userFacingMessage`'s full paragraph — written to stand alone
    /// on a whole failure screen — read like a mismatched sentence bolted on
    /// after "Saved on this phone but not checked yet:" (gap 119: "You're
    /// offline. Showing what was downloaded. Nothing new can load until
    /// you're back." is feed wording, not a reason clause).
    ///
    /// Not on `APIError` itself — that type belongs to batch 0, already
    /// shipped — so this lives with its one caller instead of widening a
    /// type other work depends on.
    var shortReason: String {
        switch self {
        case .offline: "you're offline"
        case .rateLimited: "MangaBaka asked for a pause"
        case .cancelled: "that check didn't finish"
        case .server, .decoding, .transport: "of a server problem"
        }
    }
}

/// Settings, including entering a personal access token.
///
/// The token is a stopgap until OAuth exists: a PAT never expires and is not
/// scoped, so this screen says that plainly rather than presenting it as the
/// normal way to sign in.
struct SettingsView: View {
    /// Checks the token already in the Keychain, not the field: `save()`
    /// writes first, then calls this.
    let validate: () async -> TokenCheck
    let content: ContentPreferencesStore
    /// The reader's real library, and a read of it that costs nothing
    /// because the session already walked it (item 20). Threaded through to
    /// `LibraryTransferSection`, which used to build its own.
    let library: any LibraryProviding
    let loadExisting: () async -> [LibraryEntry]
    let formats: FormatPreferencesStore
    let blockedTags: BlockedTagsStore
    let catalogue: CatalogueService
    var focusAccount = false
    let reminders: ReleaseReminders
    var publisherFollows: PublisherFollows = PublisherFollows()
    let onRemindersChanged: () async -> Void
    let history: HistoryStore
    let taste: TasteProfile
    /// Called when the signed-in account changes, so data learned from the
    /// previous one is forgotten. A token is a person, not a setting.
    let onAccountChanged: () async -> Void
    @Binding var titleRevision: Int

    @State private var entry = ""
    @State private var status: TokenStatus = .idle
    @State private var storedTokenExists: Bool
    /// The rating awaiting confirmation, set while the opt-in alert is up.
    @State private var pendingOptIn: ContentPreferences.Rating?
    private let store: any TokenPersisting
    private let defaults: UserDefaults
    /// Gap 121: re-checking on every appearance meant a 429 hit at exactly
    /// the wrong moment flipped a genuinely connected card to "Not checked
    /// yet" — a check that failed to run is not the same fact as a token
    /// that stopped working, and the card could not tell them apart. A check
    /// less than an hour old is trusted rather than repeated.
    private static let lastCheckedNameKey = "settings.tokenCheck.name"
    private static let lastCheckedAtKey = "settings.tokenCheck.at"
    private static let recheckInterval: TimeInterval = 60 * 60

    init(
        validate: @escaping () async -> TokenCheck,
        content: ContentPreferencesStore,
        library: any LibraryProviding,
        loadExisting: @escaping () async -> [LibraryEntry],
        formats: FormatPreferencesStore,
        blockedTags: BlockedTagsStore,
        catalogue: CatalogueService,
        focusAccount: Bool = false,
        reminders: ReleaseReminders,
        publisherFollows: PublisherFollows = PublisherFollows(),
        onRemindersChanged: @escaping () async -> Void,
        history: HistoryStore,
        taste: TasteProfile,
        onAccountChanged: @escaping () async -> Void,
        titleRevision: Binding<Int>,
        store: any TokenPersisting = TokenStore(),
        defaults: UserDefaults = .standard
    ) {
        self.validate = validate
        self.content = content
        self.library = library
        self.loadExisting = loadExisting
        self.formats = formats
        self.blockedTags = blockedTags
        self.catalogue = catalogue
        self.focusAccount = focusAccount
        self.reminders = reminders
        self.publisherFollows = publisherFollows
        self.onRemindersChanged = onRemindersChanged
        self.history = history
        self.taste = taste
        self.onAccountChanged = onAccountChanged
        self._titleRevision = titleRevision
        self.store = store
        self.defaults = defaults
        // Item 104: this was `State(initialValue: store.read() != nil)`, a
        // `SecItemCopyMatching` (~1 ms of IPC) that ran on every `RootView`
        // body pass while Settings was pushed — the `navigationDestination`
        // closure rebuilds the view each time even though `@State` keeps the
        // first value, so the Keychain was asked and the answer thrown away.
        // Read once, in the `.task` below, before its own guard.
        self._storedTokenExists = State(initialValue: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Settings")
                    .typeScreenTitle()
                    .foregroundStyle(Palette.textPrimary)

                // `.arrives(index:)` per section, per the motion brief — a
                // settings screen assembling rather than snapping in whole.
                // `Motion.arrival` caps its own stagger at 6 steps, so the
                // eleven sections here do not make the last ones wait
                // seconds; they simply share the sixth step's delay with
                // everything past it.
                accountSection.arrives(index: 0)
                TitleSection(revision: $titleRevision).arrives(index: 1)
                FormatSection(formats: formats).arrives(index: 2)
                contentSection.arrives(index: 3)
                BlockedTagsSection(blockedTags: blockedTags, catalogue: catalogue).arrives(index: 4)
                RemindersSection(
                    reminders: reminders, onChange: onRemindersChanged, publisherFollows: publisherFollows
                )
                .arrives(index: 5)
                HistorySection(history: history).arrives(index: 6)
                LibraryTransferSection(library: library, loadExisting: loadExisting)
                    .arrives(index: 7)
                DataUseSection(taste: taste).arrives(index: 8)
                TranslationSection().arrives(index: 9)
                AttributionSection().arrives(index: 10)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        // The same top edge and screen name as every other pushed screen
        // from this tab; Settings was the one with neither, so it rendered a
        // different edge to its siblings and had no accessible name.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Show \(pendingOptIn?.title.lowercased() ?? "this") content?",
            isPresented: Binding(
                get: { pendingOptIn != nil },
                set: { if !$0 { pendingOptIn = nil } }
            ),
            presenting: pendingOptIn
        ) { rating in
            Button("Cancel", role: .cancel) { pendingOptIn = nil }
            Button("Show it") {
                Task { await content.set(rating, allowed: true) }
                pendingOptIn = nil
            }
        } message: { _ in
            Text(optInWarning)
        }
        .task {
            // Before the guard: this is the one read of the Keychain (item
            // 104), and the guard below is what it decides.
            storedTokenExists = store.read() != nil
            guard storedTokenExists, case .idle = status else { return }
            // Gap 121: a check less than an hour old is trusted rather than
            // repeated on every appearance of this screen — each push
            // rebuilds `SettingsView` fresh, so without this every visit
            // re-asked MangaBaka, and a 429 landing at exactly that moment
            // flipped "Connected" to "Not checked yet" for a token that had
            // done nothing wrong.
            if let cached = recentlyCheckedName() {
                status = .signedIn(cached.isEmpty ? nil : cached)
                return
            }
            await check()
        }
    }

    /// The name from the last check, if that check happened inside
    /// `recheckInterval`. Nil forces an actual re-check — including the
    /// first one ever, since `lastCheckedAtKey` is absent then.
    private func recentlyCheckedName() -> String? {
        let lastCheckedAt = defaults.double(forKey: Self.lastCheckedAtKey)
        guard lastCheckedAt > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - lastCheckedAt
        guard age >= 0, age < Self.recheckInterval else { return nil }
        return defaults.string(forKey: Self.lastCheckedNameKey) ?? ""
    }

    private func rememberCheck(name: String?) {
        defaults.set(name ?? "", forKey: Self.lastCheckedNameKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedAtKey)
    }

    /// Forgets the last check, both halves of it.
    ///
    /// Item 103: "Remove token" and a rejection each cleared
    /// `lastCheckedAtKey` and left `lastCheckedNameKey` behind, so the
    /// previous account's display name survived the one operation whose own
    /// comment says the list exists to be complete. Two keys are written
    /// together, so they are removed together — in one place, not two.
    private func forgetCheck() {
        defaults.removeObject(forKey: Self.lastCheckedNameKey)
        defaults.removeObject(forKey: Self.lastCheckedAtKey)
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
                    forgetCheck()
                    // The third way to change account, and the one that called
                    // none of this. Removing a token and entering a different
                    // one left the previous person's taste ledger, profile id
                    // and library snapshot on disk — the same bug the save
                    // path was fixed for, in the path nobody wired.
                    await onAccountChanged()
                },
                onReplace: { status = .idle },
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

    /// Why turning this on is a decision rather than a preference. Named as
    /// plainly as the setting itself: someone deciding this is owed the actual
    /// consequence, not a euphemism.
    private var optInWarning: String {
        """
        This adds sexual content to your feeds, search and recommendations \
        throughout the app. Only turn it on if you are 18 or over. You can \
        turn it off again at any time.
        """
    }

    private func ratingRow(_ rating: ContentPreferences.Rating) -> some View {
        let isOn = content.preferences.allowed.contains(rating)
        let isLocked = rating == .safe

        return Button {
            guard !isLocked else { return }
            // Confirmed on the way in, never on the way out: a reader turning
            // adult content off is not a decision anyone should be asked to
            // reconsider, and `requiresOptIn` describes the switch, not the tap.
            if !isOn, rating.requiresOptIn {
                pendingOptIn = rating
            } else {
                Task { await content.set(rating, allowed: !isOn) }
            }
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
        .buttonStyle(.press)
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
            // Gap 118: this used to be `.failed`, the same state MangaBaka
            // itself answers a rejected token with — so a Keychain write
            // refusal (storage full, the item locked by another process)
            // read as "That token was not accepted by MangaBaka" and sent
            // the reader to generate a new one for a problem no new token
            // could fix. `.notStored` says what actually happened: the
            // token never left this phone.
            status = .notStored
            return
        }
        storedTokenExists = true
        // Before validating, not after: the token on disk has already changed,
        // so anything still cached from the previous account is already about
        // the wrong person.
        await onAccountChanged()
        await check()
        if case .failed = status {
            // A token MangaBaka rejected is worse than none: it would make
            // every authenticated call fail quietly. Only an actual rejection
            // gets here — an unreachable server leaves the token alone, because
            // deleting a credential over a dropped connection is a way to lose
            // someone's account access for them.
            store.clear()
            storedTokenExists = false
            await onAccountChanged()
        }
    }

    private func check() async {
        status = .checking
        switch await validate() {
        case let .accepted(name):
            status = .signedIn(name)
            entry = ""
            rememberCheck(name: name)
        case .rejected:
            status = .failed("That token was not accepted by MangaBaka.")
            forgetCheck()
        case let .unknown(reason):
            // Not a verdict on the token. Saying so matters twice over: the
            // reader is not told their token is bad when it is not, and `save`
            // does not delete it.
            status = .unverified(reason)
        }
    }
}
