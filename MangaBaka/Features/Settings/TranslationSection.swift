import SwiftUI
import Translation

/// Offers the ru→en language-pack download that `CharacterProfileView` can
/// never ask for.
///
/// **Why here, and not there.** `CharacterProfileView` is presented in a
/// `.sheet`, and the Translation framework's download prompt is itself a
/// system sheet — raising it from inside an app sheet is what crashed
/// TestFlight build 64 (see `TranslationGate`). Settings is a plain pushed
/// screen, not a sheet, so `prepareTranslation()` — the call that raises that
/// prompt — is safe to make from here. Until a reader does this once, the
/// character profile silently shows no description at all for a Shikimori
/// character; this section is that reader's only way to fix that.
struct TranslationSection: View {
    @State private var status: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        SettingsSection(title: "Translation", caption: caption) {
            SettingsCard {
                SettingsRow(title: "Russian → English", caption: nil) {
                    trailing
                }
            }
        }
        .task { await refresh() }
        .translationTask(configuration) { session in
            // The call that raises the system download prompt. Safe here,
            // and only here — see the type comment. Wrapped the way the
            // profile wraps its session: `TranslationSession` is not
            // Sendable, and calling its async method straight from this
            // closure is "sending 'session' risks causing data races".
            await SystemDescriptionTranslator(session: session).prepare()
            await refresh()
            configuration = nil
        }
    }

    private var caption: String {
        """
        Character descriptions from Shikimori are in Russian and are \
        translated on your device. Nothing is sent anywhere.
        """
    }

    @ViewBuilder
    private var trailing: some View {
        if status == nil {
            ProgressView()
        } else if case .supported? = status {
            Button {
                configuration = TranslationSession.Configuration(
                    source: TranslationGate.sourceLanguage, target: TranslationGate.targetLanguage
                )
            } label: {
                Text("Download")
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.press)
            .accessibilityLabel(Self.label(for: .supported))
        } else if let status {
            Text(Self.label(for: status))
                .typeRowTitle()
                .foregroundStyle(Self.color(for: status))
        }
    }

    private static func color(for status: LanguageAvailability.Status) -> Color {
        if case .installed = status { Palette.textSecondary } else { Palette.textTertiary }
    }

    /// Pure mapping from a pack's status to what the row says, so it is
    /// testable without driving the framework's own async status call.
    nonisolated static func label(for status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed:
            "Russian → English: installed"
        case .supported:
            "Download Russian → English"
        case .unsupported:
            "Not available on this device"
        @unknown default:
            "Not available on this device"
        }
    }

    private func refresh() async {
        status = await LanguageAvailability().status(
            from: TranslationGate.sourceLanguage, to: TranslationGate.targetLanguage
        )
    }
}
