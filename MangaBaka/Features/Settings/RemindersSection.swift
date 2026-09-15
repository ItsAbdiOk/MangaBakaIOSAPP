import SwiftUI
import UIKit

/// The switch that turns release reminders on.
///
/// Permission is asked for here and nowhere else. A notification prompt on
/// first launch — before the app has shown it knows anything worth telling you
/// — is how an app gets denied permanently, and iOS only lets you ask once.
struct RemindersSection: View {
    let reminders: ReleaseReminders
    /// Rebuilds the pending list after a switch moves.
    let onChange: () async -> Void
    /// The app's one instance, passed in by `SettingsView`; the default only
    /// serves previews and tests that have no `AppServices`.
    var publisherFollows: PublisherFollows = PublisherFollows()

    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsSection(title: "Release reminders", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    Button {
                        Task { await toggle() }
                    } label: {
                        SettingsRow(
                            title: "Release notifications",
                            caption: "Nothing leaves this phone. iOS schedules these locally."
                        ) {
                            // Gap 102: this read `reminders.isEnabled` alone,
                            // which is only what the reader asked this app
                            // for — a reader who denied (or later revoked)
                            // the system permission still saw the switch On
                            // with nothing actually scheduled behind it.
                            // `effectiveEnabled` also checks `systemStatus`.
                            SwitchIndicator(isOn: reminders.effectiveEnabled)
                        }
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Release notifications")
                    .accessibilityValue(reminders.effectiveEnabled ? "On" : "Off")
                }

                // Only shown once iOS has actually refused. Offering a trip to
                // Settings before anyone has said no is an app assuming it has
                // been wronged.
                if reminders.systemStatus == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Text("Notifications are switched off for MangaBaka in iOS Settings. Open Settings")
                            .typeFootnote()
                            .foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.press)
                }

                if !publisherFollows.follows.isEmpty {
                    followsList
                    Text("Follows don't notify yet.")
                        .typeFootnote()
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .task { await reminders.refreshStatus() }
    }

    /// Every publisher, studio, or creator the reader has followed, each with
    /// a way to undo it.
    ///
    /// A tap-to-unfollow row rather than swipe-to-delete: there is no
    /// existing swipe-action list anywhere in this app to match the feel of,
    /// and Abdi will send a real design for this screen later regardless —
    /// this is deliberately plain.
    private var followsList: some View {
        SettingsCard {
            ForEach(Array(publisherFollows.follows.enumerated()), id: \.element.id) { index, follow in
                if index > 0 { SettingsDivider() }
                HStack {
                    Text(follow.name)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Unfollow") {
                        publisherFollows.unfollow(follow.name, kind: follow.kind)
                    }
                    .typeFootnote()
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.press)
                    .accessibilityLabel("Unfollow \(follow.name)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    /// States the two conditions exactly, and nothing else — Abdi's rule
    /// (2026-09-13): "Limit notifications to: (1) release notifications for
    /// something that has just come out, confirmed; (2) a series they're
    /// reading or have paused has either completed or finished the end of a
    /// season. Those are the only conditions." No prediction, no nudge.
    ///
    /// Q2 (2026-09-14): no background refresh, so the app only learns a
    /// publisher's feed has moved when that series' page is opened. The old
    /// wording — "a confirmed release the day it's out" — promised a
    /// timeliness nothing in the app delivers: a feed refreshed on Tuesday's
    /// page visit is what Thursday's notification is built from. This says
    /// what actually happens instead of what would be nice.
    private var caption: String {
        """
        A confirmed release, once the app has seen it — which is next time you \
        open that series. Plus word when a series you're reading or have \
        paused has completed or ended a season. Nothing else.
        """
    }

    private func toggle() async {
        if reminders.isEnabled {
            await reminders.disable()
        } else {
            await reminders.enable()
        }
        await onChange()
    }
}
