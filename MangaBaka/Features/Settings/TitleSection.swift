import SwiftUI

/// Which of a series' many titles to show.
///
/// A series carries a dozen or more — the official English one, several fan
/// translations, a romanisation, the original script. English is the default
/// because it is the language the app is written in, and the other two are
/// there because a lot of readers know these series by their Korean or Japanese
/// names and being shown a translation is the wrong answer for them.
struct TitleSection: View {
    /// Bumped so every title on screen redraws when the choice changes.
    @Binding var revision: Int

    @State private var preference = TitleSettings.preference

    var body: some View {
        SettingsSection(
            title: "Series titles",
            caption: "Which name to show where a series has several."
        ) {
            SettingsCard {
                ForEach(Array(TitlePreference.allCases.enumerated()), id: \.element) { index, option in
                    row(option)
                    if index < TitlePreference.allCases.count - 1 { SettingsDivider() }
                }
            }
        }
    }

    private func row(_ option: TitlePreference) -> some View {
        Button {
            preference = option
            TitleSettings.set(option)
            revision += 1
        } label: {
            // The example is the control's real job: "Romanised" means nothing
            // until you see what it looks like, and the same series shown three
            // ways is the whole explanation.
            SettingsRow(title: option.title, caption: option.caption) {
                if preference == option {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(preference == option ? [.isButton, .isSelected] : .isButton)
    }
}
