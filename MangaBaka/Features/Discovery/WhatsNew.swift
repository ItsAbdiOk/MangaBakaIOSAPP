import Observation
import SwiftUI

/// What changed in this build, told once.
///
/// A card at the top of Discover on the first launch after an update, listing
/// the features that arrived, with a "Got it" that puts it away for good. The
/// notes are written by hand per push — `ReleaseNotes.current` — because a
/// commit log is not a list of things a reader can now do. A fresh install
/// never sees it: nothing is "new" to someone who has not used the app.
enum ReleaseNotes {
    struct Release: Equatable, Sendable {
        /// Changes only when the notes do, so a build with nothing to say
        /// shows nothing.
        let id: String
        let headline: String
        let items: [String]
    }

    static let current = Release(
        id: "2026-09-11-b",
        headline: "New in this build",
        items: [
            "Every volume on Apple Books, with official covers and prices — "
                + "Japanese editions where your store has none",
            "\"Read in English\": the official platforms carrying a series in your language",
            "Your library in iOS search, and Siri: \"What's due this week in MangaBaka\"",
            "Glossy covers, and each row's colour on the ground behind it",
            "Flags and language names on titles and links",
            "Share a series as its mangabaka.org link"
        ]
    )
}

@MainActor
@Observable
final class WhatsNewState {
    private static let key = "whatsNew.lastSeen"
    private let defaults: UserDefaults
    private(set) var lastSeen: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastSeen = defaults.string(forKey: Self.key)
    }

    /// Whether the card is due: the notes have an id this reader has not
    /// put away, and the reader has used the app before.
    func isDue(hasCompletedOnboarding: Bool) -> Bool {
        guard hasCompletedOnboarding else {
            // A fresh install: mark the current notes as seen silently, so
            // the card first appears on the update after this one.
            if lastSeen == nil { dismiss() }
            return false
        }
        return lastSeen != ReleaseNotes.current.id
    }

    func dismiss() {
        lastSeen = ReleaseNotes.current.id
        defaults.set(lastSeen, forKey: Self.key)
    }
}

struct WhatsNewCard: View {
    let release: Release
    let onDismiss: () -> Void

    typealias Release = ReleaseNotes.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.headline)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Text("Got it")
                        .typeInstruction()
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: Metrics.headerPill)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
            }
            ForEach(release.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 2 }
                    Text(item)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Glass.floating(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)) }
        .padding(.horizontal, Metrics.gutter)
        .accessibilityElement(children: .contain)
    }
}
