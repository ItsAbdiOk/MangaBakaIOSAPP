import SwiftUI

/// The account section: one card with four occupants.
///
/// The dot and the line beside it carry the state; nothing below them moves as
/// a check completes. That is the whole design — a card that re-lays itself out
/// mid-check makes a two-second network round trip feel like the app rebuilding
/// itself, and a reader who was mid-tap loses their target.
///
/// The app works without a token, and this says so first. Everything here adds
/// to a working app rather than unlocking one.
struct AccountCard: View {
    let status: TokenStatus
    let hasStoredToken: Bool
    @Binding var entry: String
    let onSave: () async -> Void
    let onCheck: () async -> Void
    let onRemove: () async -> Void
    /// Gap 120: "Replace" used to only clear the text field, while the card
    /// stayed in its `.signedIn` rendering — which shows no field at all —
    /// so the tap had no visible effect whatsoever. This tells the caller to
    /// drop `status` back to `.idle`, which is what actually reveals the
    /// field to type the new token into.
    let onReplace: () -> Void
    /// Set when the reader arrived here from onboarding's "Connect an account".
    /// Dropping them at the top of Settings after they said yes is the version
    /// that loses them.
    var focusOnAppear = false

    @FocusState private var isFieldFocused: Bool
    /// Gap 90: "Remove token" used to fire on the first tap, `role:
    /// .destructive` one tap below a dead "Replace" — one undefended tap
    /// forgot seven account-scoped stores (the library, taste ledger,
    /// reminders, Spotlight index and more; see
    /// `RootView+Session.forgetPreviousAccount`) with nothing to undo it.
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if case .checking = status {
                // A bar rather than a spinner. A spinner in a card says "wait";
                // a bar under the line it belongs to says "this line is being
                // worked out", which is the truth.
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
                    .padding(.top, 12)
                    // The spinner leaving and the status line replacing it
                    // are the same transition, per the motion brief — a
                    // blur-replace rather than a plain cut so "checking" and
                    // its answer read as one continuous card, not two.
                    .transition(.blurReplace)
            }

            Text(explanation)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .transition(.blurReplace)
                .id(headline)

            actions
                .padding(.top, 14)
        }
        .padding(14)
        .background(background, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(borderColour, lineWidth: status.isRejection ? 1 : 0.5)
        )
        .animation(Motion.reduced(Motion.settle), value: status)
        // The one real "connect an account" success in this app — onboarding's
        // own "Connect an account" only defers to here, since the actual
        // token has not been entered yet when that button is tapped. See
        // `OnboardingView`'s report note.
        .celebrates(on: isSignedIn)
        .sensoryFeedback(Haptics.success, trigger: isSignedIn)
        .task {
            guard focusOnAppear else { return }
            // One run loop: focusing during the sheet's own presentation
            // animation is dropped, and the keyboard never appears.
            try? await Task.sleep(for: .milliseconds(350))
            isFieldFocused = true
        }
        .confirmDestructive(
            isPresented: $isConfirmingRemoval,
            title: "Remove this token?",
            consequence: "Library sync, personal recommendations and your taste profile stop. "
                + "Nothing on mangabaka.org is affected, and pasting the same token back restores all of it.",
            label: "Remove token",
            action: onRemove
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(headline)
                .typeRowTitle()
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 8)
            if case let .signedIn(name) = status, let name {
                Text(name)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
    }

    /// A rejected token is the one state that colours the whole card.
    ///
    /// Everything else here is a statement about the app; this one is a thing
    /// the reader has to do something about, and it is easy to scroll past a
    /// grey card.
    private var background: Color {
        status.isRejection ? Palette.accentTint : Palette.surface
    }

    private var borderColour: Color {
        status.isRejection ? Palette.accentEdge : Palette.border
    }

    /// The trigger for the card's one reward moment: a token that has just
    /// been confirmed working. Not fired on first appearance already
    /// `.signedIn` (a cached check, or a relaunch) — only a *change* into
    /// this state celebrates, the same rule `CelebratesModifier` already
    /// applies to every other trigger it watches.
    private var isSignedIn: Bool {
        if case .signedIn = status { true } else { false }
    }

    private var dot: Color {
        switch status {
        case .signedIn: Palette.positive
        case .failed, .notStored: Palette.accent
        case .checking: Palette.accent.opacity(0.45)
        case .idle, .unverified: Palette.textQuaternary
        }
    }

    private var headline: String {
        switch status {
        case .signedIn: "Connected"
        case .failed: "Token rejected"
        // Gap 118: distinct from "Token rejected" — MangaBaka never saw this
        // token, so telling the reader it was "rejected" points them at
        // generating a new one on the site, which does nothing for a local
        // Keychain write failure.
        case .notStored: "Couldn't save it here"
        case .checking: "Checking…"
        case .unverified: "Not checked yet"
        case .idle: hasStoredToken ? "Not checked yet" : "No account"
        }
    }

    private var explanation: String {
        switch status {
        case .signedIn:
            "Library sync, recommendations and your taste profile are on."
        case let .failed(reason):
            """
            \(reason) Tokens are revoked when you regenerate one on the site. \
            Discovery, search and the stack keep working without it.
            """
        case .notStored:
            "The token itself may be fine — this phone's secure storage couldn't be written to just now."
        case .checking:
            "Checking the token with MangaBaka."
        case let .unverified(reason):
            "Saved on this phone but not checked yet: \(reason)"
        case .idle:
            hasStoredToken
                ? "Saved on this phone but never used. It is checked the first time something needs it."
                : """
                The app works without one. A token adds library sync, personal \
                recommendations and your taste profile.
                """
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .signedIn:
            connected
        case .checking:
            // Reserved, not collapsed: the buttons keep their place so nothing
            // below them jumps when the check lands.
            field.opacity(0.5).disabled(true)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                field
                TokenLink()
            }
        case .notStored:
            // No `TokenLink` here: the token was never sent anywhere, so
            // "Get a token" would send someone whose token is fine off to
            // generate a new one for a local storage problem.
            field
        case .idle, .unverified:
            VStack(alignment: .leading, spacing: 10) {
                if hasStoredToken {
                    StateAction(title: "Check now", weight: .wayOut) { Task { await onCheck() } }
                }
                field
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String(repeating: "•", count: 12))
                    .typeBody()
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(minHeight: Metrics.field)
                    .background(Palette.surfaceField, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusChip, style: .continuous
                    ))
                    .accessibilityLabel("Token, hidden")

                StateAction(title: "Replace", weight: .wayOut) {
                    entry = ""
                    onReplace()
                }
            }

            Button("Remove token", role: .destructive) {
                isConfirmingRemoval = true
            }
                .typeRowTitle()
                .foregroundStyle(Palette.accent)
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SecureField("mb-…", text: $entry)
                    .focused($isFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    // 40pt was the mockup's field height and Apple's audit
                    // measured the text field inside it at 225x19. A field you
                    // have to aim at is a field people mistype into.
                    .frame(minHeight: max(Metrics.field, Metrics.tapTarget))
                    .background(Palette.surfaceField, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusChip, style: .continuous
                    ))

                StateAction(
                    title: status.isRejection ? "Paste a new one" : "Save",
                    weight: TokenStore.looksValid(entry) ? .fixes : .wayOut
                ) {
                    Task { await onSave() }
                }
                .disabled(!TokenStore.looksValid(entry))
            }

            // Gap 69: Save used to grey itself out with nothing saying why —
            // a reader who had typed something that merely wasn't a token
            // yet (still pasting, or the wrong thing entirely) had no way to
            // tell "not yet" from "this app is broken".
            if !entry.isEmpty, !TokenStore.looksValid(entry) {
                Text("Tokens start with mb-")
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }
}

/// Where a token actually comes from.
///
/// A rejection that does not say where to get a new one leaves the reader to
/// guess at a URL, and the guess is usually the API host.
private struct TokenLink: View {
    private static let url = URL(string: "https://mangabaka.org/settings/api")

    var body: some View {
        if let url = Self.url {
            Link(destination: url) {
                HStack(spacing: 5) {
                    Text("Get a token")
                        .typeCTA()
                    Image(systemName: "arrow.up.right")
                        .typeSymbol(size: 11, weight: .semibold)
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 16)
                .frame(minHeight: Metrics.ctaSecondary)
                .overlay(Capsule().strokeBorder(Palette.borderPill, lineWidth: 0.5))
            }
        }
    }
}
