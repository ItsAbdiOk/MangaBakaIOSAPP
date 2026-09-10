import SwiftUI
import UIKit

/// The switch that turns release reminders on.
///
/// Permission is asked for here and nowhere else. A notification prompt on
/// first launch — before the app has shown it knows anything worth telling you
/// — is how an app gets denied permanently, and iOS only lets you ask once.
struct RemindersSection: View {
    let reminders: ReleaseReminders
    /// Rebuilds the pending list after the switch moves.
    let onChange: () async -> Void

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
                            SwitchIndicator(isOn: reminders.isEnabled)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Release reminders")
                    .accessibilityValue(reminders.isEnabled ? "On" : "Off")
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
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await reminders.refreshStatus() }
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
}
