import SwiftUI

/// The format filter in Settings.
///
/// Its own file rather than another section inside SettingsView: that type was
/// already at the lint's body-length ceiling, and a settings screen that cannot
/// gain a section without being split is a screen that will stop gaining
/// sections.
struct FormatSection: View {
    let formats: FormatPreferencesStore

    var body: some View {
        SettingsSection(
            title: "Formats",
            caption: "Which publication formats appear in results."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    ForEach(FormatPreferences.Format.allCases, id: \.rawValue) { format in
                        row(format)
                        if format != FormatPreferences.Format.allCases.last {
                            SettingsDivider()
                        }
                    }
                }

                // A plain line, where Content gets the tinted callout. Same
                // mechanism, smaller blast radius: turning off novels drops
                // some rows, turning off a rating discards every cached feed.
                // If both got the box, the box would stop meaning anything.
                Text("""
                Changing this clears downloaded feeds, because they were \
                fetched under the previous setting.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ format: FormatPreferences.Format) -> some View {
        let isOn = formats.preferences.allowed.contains(format)
        // The last format on cannot be turned off: a reader who excluded every
        // format would get an empty app and no explanation for it.
        let isLocked = isOn && formats.preferences.allowed.count == 1

        return Button {
            guard !isLocked else { return }
            Task { await formats.set(format, allowed: !isOn) }
        } label: {
            SettingsRow(title: format.title, caption: format.subtitle) {
                if isLocked {
                    LockPill()
                } else {
                    SwitchIndicator(isOn: isOn)
                }
            }
        }
        .buttonStyle(.plain)
        // NOT `.disabled(isLocked)`. That was the cause of the dimmed row the
        // design board calls out by name: SwiftUI fades a disabled Button's
        // whole label, so the title went grey along with everything else and a
        // deliberate rule read as a broken control. The guard inside the action
        // is what makes the row inert; the lock pill is what says why.
        .accessibilityLabel(format.title)
        .accessibilityValue(isLocked ? "Always on" : (isOn ? "On" : "Off"))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
