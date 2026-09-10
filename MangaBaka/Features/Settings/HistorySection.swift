import SwiftUI

/// The recently-viewed history, and the control that erases it.
///
/// Its own file for the reason `FormatSection` gives: `SettingsView` is at the
/// lint's body-length ceiling.
///
/// This section exists because the feature it describes is a reading-history
/// log. The app can hold one without saying so, and chose not to: it states
/// where the list lives, that nothing leaves the phone, and offers one tap to
/// be rid of it.
struct HistorySection: View {
    let history: HistoryStore

    @State private var held = 0
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Recently viewed")

            Text("""
            The last \(HistoryStore.limit) series you opened appear on Discover \
            so you can get back to them. The list is stored on this phone, is \
            never sent anywhere, and clearing it does not touch your library.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textSecondary)

            Button {
                isConfirming = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                    Text(label)
                        .typeCTA()
                }
                .foregroundStyle(held == 0 ? Palette.textTertiary : Palette.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.ctaSecondary)
                .background(Palette.surface, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusCard, style: .continuous
                ))
                .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            }
            .buttonStyle(.plain)
            .disabled(held == 0)
        }
        .task { await refresh() }
        .confirmationDialog(
            "Clear recently viewed?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task {
                    try? await history.clear()
                    await refresh()
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            // Says what survives, because "clear" next to a library is a word
            // that reasonably frightens people.
            Text("Your library, saves and skips are not affected.")
        }
    }

    /// "Clear 12 series" — the number, so the reader knows what they are erasing
    /// before they erase it rather than after.
    private var label: String {
        switch held {
        case 0: "Nothing viewed yet"
        case 1: "Clear 1 series"
        default: "Clear \(held) series"
        }
    }

    private func refresh() async {
        held = (try? await history.count()) ?? 0
    }
}
