import SwiftUI
import os

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

    /// How many rows the list holds, or nil when the read itself failed.
    ///
    /// Item 102: this was a non-optional `Int` set from
    /// `(try? await history.count()) ?? 0`, so a disk error rendered as
    /// "Nothing viewed yet" *and* disabled the button — the reader could not
    /// clear a list the app could not read, and was told there was nothing
    /// to clear. Three states, not two.
    @State private var held: Int?
    @State private var isConfirming = false
    /// From the environment, the same instance `RootView` puts every toast
    /// through — see `.environment(toasts)` at the tab tree's root. Optional
    /// like every other reader of it (`LibraryList`, `SearchView`, …): a
    /// preview or a future host that never sets the environment value must
    /// not crash reaching for it.
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    /// S19: this slice had no `Logger` at all. A disk read failure here
    /// renders as the (already handled) "couldn't be read" state, but was
    /// otherwise invisible — nothing a production report could point at.
    private static let logger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "settings")

    var body: some View {
        SettingsSection(title: "Recently viewed", caption: caption) {
            Button {
                isConfirming = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .typeSymbol(size: 13, weight: .semibold)
                    Text(label)
                        .typeCTA()
                }
                // Inert rather than absent when there is nothing to clear. A
                // control that vanishes makes the section look like it lost a
                // feature, and the reader is left wondering what they did.
                .foregroundStyle(held == 0 ? Palette.textTertiary : Palette.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.ctaSecondary)
                .background(Palette.surface, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusCard, style: .continuous
                ))
                .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            }
            .buttonStyle(.press)
            // Enabled when the count could not be read: clearing is exactly
            // what a reader wants to be able to do about a list the app is
            // having trouble with.
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
                    // Gap 122: `try?` swallowed a real failure — a disk
                    // error, a locked file — and `refresh()` after it still
                    // ran, so the list either stayed exactly as full as
                    // before with nothing said, or (worse) looked cleared
                    // for the rest of the session while the row remained on
                    // disk.
                    do {
                        try await history.clear()
                    } catch {
                        toasts?.show("Couldn't clear the list", kind: .failure)
                    }
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

    /// The empty caption is not the populated one with a word removed: with
    /// nothing in the list the sentence has to explain what the list is FOR,
    /// which the populated one can take for granted.
    private var caption: String {
        held == nil
            ? """
            The list couldn't be read just now. Clearing still works, and your \
            library, saves and skips are not affected either way.
            """
            : held == 0
            ? """
            Nothing opened yet. The last \(HistoryStore.limit) series you open \
            appear on Discover so you can get back to them, stored on this \
            phone and never sent anywhere.
            """
            : """
            The last \(HistoryStore.limit) series you opened appear on Discover \
            so you can get back to them. The list is stored on this phone, is \
            never sent anywhere, and clearing it does not touch your library.
            """
    }

    /// "Clear 12 series" — the number, so the reader knows what they are erasing
    /// before they erase it rather than after.
    private var label: String {
        switch held {
        case nil: "Couldn't read the list"
        case .some(0): "Nothing viewed yet"
        case .some(1): "Clear 1 series"
        case let .some(count): "Clear \(count) series"
        }
    }

    private func refresh() async {
        do {
            held = try await history.count()
        } catch {
            held = nil
            Self.logger.error("history.count() failed: \(error, privacy: .public)")
        }
    }
}
