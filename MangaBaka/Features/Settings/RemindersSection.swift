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
    /// Not injected from `AppServices` yet — see this feature's report for
    /// the one line that should replace this default with a shared instance.
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
                            title: "Tell me when something is due",
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
                    .accessibilityLabel("Release reminders")
                    .accessibilityValue(reminders.effectiveEnabled ? "On" : "Off")
                    SettingsDivider()
                    Button {
                        Task { await toggleBackToIt() }
                    } label: {
                        SettingsRow(
                            title: "Back-to-it nudges",
                            caption: "A nudge when you have not opened something you were reading."
                        ) {
                            SwitchIndicator(isOn: reminders.effectiveBackToItEnabled)
                        }
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Back-to-it nudges")
                    .accessibilityValue(reminders.effectiveBackToItEnabled ? "On" : "Off")
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

    /// Says what it will and will not tell you, because the honest answer is
    /// "two different kinds of thing, and one of them is a guess".
    private var caption: String {
        """
        A notice on the day a volume you follow is published, and a rougher one \
        when a series you are reading is about due a chapter. The second is an \
        estimate and says so.
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

    private func toggleBackToIt() async {
        await reminders.setBackToIt(!reminders.backToItEnabled)
        await onChange()
    }
}
