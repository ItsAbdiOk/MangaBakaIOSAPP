import SwiftUI

/// Settings as a `Form`, which is what iOS Settings is.
///
/// The app's own Settings is a `ScrollView` of hand-built rows with hand-built
/// separators, hand-built chips and a hand-built lock pill. This is the same
/// information in the container the platform provides.
///
/// What comes free: grouped insets that match every other app, the keyboard
/// avoidance, the row heights that are already at 44pt without anyone adding a
/// modifier, `Toggle` and `Picker` with their real switch and real menu, and
/// footers that are styled as footers rather than as small grey text somebody
/// chose.
struct AppleSettingsView: View {
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore
    @Binding var titleRevision: Int

    @State private var preference = TitleSettings.preference

    var body: some View {
        Form {
            Section {
                // A real Picker. The app builds three tappable rows with a
                // checkmark; this is one control that knows how to be a menu
                // on iPhone, a segmented control where that fits, and whatever
                // Apple makes it next.
                Picker("Series titles", selection: $preference) {
                    ForEach(TitlePreference.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: preference) { _, new in
                    TitleSettings.set(new)
                    titleRevision += 1
                }
            } header: {
                Text("Titles")
            } footer: {
                Text("Which language a series' name is shown in, where the series has one.")
            }

            Section {
                ForEach(ContentPreferences.Rating.allCases, id: \.self) { rating in
                    Toggle(rating.title, isOn: binding(for: rating))
                        .disabled(rating == .safe)
                }
            } header: {
                Text("Content")
            } footer: {
                Text("""
                Safe cannot be turned off: a reader who excluded everything \
                would see an empty app with no explanation for it.
                """)
            }

            Section {
                ForEach(FormatPreferences.Format.allCases, id: \.self) { format in
                    Toggle(format.title, isOn: formatBinding(for: format))
                }
            } header: {
                Text("Formats")
            } footer: {
                Text("Which publication formats appear in results.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for rating: ContentPreferences.Rating) -> Binding<Bool> {
        Binding(
            get: { content.preferences.allowed.contains(rating) },
            set: { isOn in Task { await content.set(rating, allowed: isOn) } }
        )
    }

    private func formatBinding(for format: FormatPreferences.Format) -> Binding<Bool> {
        Binding(
            get: { formats.preferences.allowed.contains(format) },
            set: { isOn in Task { await formats.set(format, allowed: isOn) } }
        )
    }
}
