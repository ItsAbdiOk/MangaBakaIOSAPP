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
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Formats")

            Text("""
            Shown everywhere: Discover, Search, the Stack and Mix. Turn off \
            what you don't read.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textSecondary)

            VStack(spacing: 0) {
                ForEach(FormatPreferences.Format.allCases, id: \.rawValue) { format in
                    row(format)
                    if format != FormatPreferences.Format.allCases.last {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)

            Text("""
            Changing this clears downloaded feeds, because they were fetched \
            under the previous setting.
            """)
            .typeFootnote()
            .foregroundStyle(Palette.textQuaternary)
        }
    }

    /// A Button wrapping a drawn indicator, matching the content rows. A live
    /// Toggle here only ever responded to a drag across the switch, never to an
    /// ordinary tap — verified repeatedly on device.
    private func row(_ format: FormatPreferences.Format) -> some View {
        let isOn = formats.preferences.allowed.contains(format)
        // The last one on cannot be switched off; turning everything off would
        // leave an empty app with no visible cause.
        let isLocked = isOn && formats.preferences.allowed.count == 1

        return Button {
            guard !isLocked else { return }
            Task { await formats.set(format, allowed: !isOn) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.title)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text(isLocked ? "Keep at least one format on" : format.subtitle)
                        .typeGridMeta()
                        .foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SwitchIndicator(isOn: isOn, isLocked: isLocked)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            // minHeight rather than height: two lines of scaled text, and a
            // fixed height made one row's caption overlap the next row's title
            // at accessibility sizes.
            .frame(minHeight: Metrics.ctaSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityLabel(format.title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// The drawn switch used by both settings sections.
///
/// Drawn rather than a real `Toggle`, because each row's tap target is the
/// whole row and a live control inside it would compete for the gesture. That
/// competition is not theoretical: the content rows only responded to a drag
/// across the switch until the row became the button and the switch became
/// presentation.
struct SwitchIndicator: View {
    let isOn: Bool
    let isLocked: Bool

    var body: some View {
        let track = isOn ? Palette.accent : Palette.surfaceChip
        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(track.opacity(isLocked ? 0.4 : 1))
                .frame(width: 51, height: 31)
            Circle()
                .fill(.white.opacity(isLocked ? 0.6 : 1))
                .frame(width: 27, height: 27)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(.horizontal, 2)
        }
        .frame(width: 51, height: 31)
        .animation(.snappy(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}
