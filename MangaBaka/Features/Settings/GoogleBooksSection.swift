import SwiftUI

/// Where the reader puts their own Google Books API key.
///
/// Needed on the phone, not just in a build setting: the build-time key lives
/// in `Secrets.xcconfig`, which only `Debug.xcconfig` includes, so a build
/// installed on a device has no key at all. This field is the only way one
/// gets there. See `GoogleBooksKey`.
///
/// Google is used for covers only — volumes Apple Books does not carry. It is
/// not a shop here and nothing is bought through it, so there is no account to
/// connect and nothing to lose if the key is wrong: the shelf simply shows
/// what Apple and MangaBaka already had.
struct GoogleBooksSection: View {
    @State private var entry = ""
    @State private var isStored = TokenStore(service: TokenStore.googleBooksService).read() != nil
    @FocusState private var isFieldFocused: Bool

    private let store = TokenStore(service: TokenStore.googleBooksService)

    var body: some View {
        SettingsSection(title: "Google Books", caption: caption) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(isStored ? "A key is saved on this device." : "No key saved.")
                        .typeRowTitle()
                        .foregroundStyle(isStored ? Palette.textPrimary : Palette.textSecondary)
                    field
                    if isStored {
                        Button("Remove key", role: .destructive) { remove() }
                            .typeRowTitle()
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
        }
    }

    private var caption: String {
        """
        Fills in volume covers for series Apple Books does not sell. \
        Optional — without a key the app asks Google nothing. Make one in the \
        Google Cloud console, enable the Books API, and restrict the key to \
        this app.
        """
    }

    private var field: some View {
        HStack(spacing: 10) {
            SecureField("AIza…", text: $entry)
                .focused($isFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: max(Metrics.field, Metrics.tapTarget))
                .background(Palette.surfaceField, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusChip, style: .continuous
                ))

            StateAction(
                title: "Save",
                weight: GoogleBooksKey.looksValid(entry) ? .fixes : .wayOut
            ) {
                save()
            }
            .disabled(!GoogleBooksKey.looksValid(entry))
        }
    }

    /// No round trip to Google to check it. Unlike the personal access token
    /// there is nothing a bad key can damage — a rejected key means no extra
    /// covers, which is the same as no key — and spending a request to find
    /// out would burn the very quota the key exists to grant.
    private func save() {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.write(trimmed) else { return }
        isStored = true
        entry = ""
        isFieldFocused = false
    }

    private func remove() {
        guard store.clear() else { return }
        isStored = false
        entry = ""
    }
}
