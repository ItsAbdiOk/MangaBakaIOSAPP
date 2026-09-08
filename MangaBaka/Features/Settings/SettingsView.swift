import SwiftUI

/// Settings, including entering a personal access token.
///
/// The token is a stopgap until OAuth exists: a PAT never expires and is not
/// scoped, so this screen says that plainly rather than presenting it as the
/// normal way to sign in.
struct SettingsView: View {
    let validate: (String) async -> String?

    @State private var entry = ""
    @State private var status: Status = .idle
    @State private var storedTokenExists = TokenStore().read() != nil
    private let store = TokenStore()

    enum Status: Equatable {
        case idle
        case checking
        case signedIn(String)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Settings")
                    .typeScreenTitle()
                    .foregroundStyle(Palette.textPrimary)

                accountSection
                attributionSection
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 62)
            .padding(.bottom, 24)
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
                    Text("Signed in as \(name)")
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

                if case let .failed(reason) = status {
                    Text(reason)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.accent)
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

    /// Required by the data licence, not decoration.
    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Data")
            Text("""
            Series data comes from MangaBaka, and through it from AniList, \
            Kitsu, MangaUpdates, MyAnimeList and Anime-Planet.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textSecondary)
            Text("""
            Licensed CC BY-NC-SA 4.0 — free for personal, non-commercial use \
            with attribution. This app is free and carries no ads or purchases.
            """)
            .typeFootnote()
            .foregroundStyle(Palette.textQuaternary)
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
            // A token that does not work is worse than none: it would make
            // every authenticated call fail quietly.
            store.clear()
            storedTokenExists = false
        }
    }

    private func check() async {
        status = .checking
        if let name = await validate(entry) {
            status = .signedIn(name)
            entry = ""
        } else {
            status = .failed("That token was not accepted by MangaBaka.")
        }
    }
}
