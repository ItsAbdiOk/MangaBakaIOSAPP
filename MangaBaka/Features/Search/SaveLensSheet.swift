import SwiftUI

/// Naming a lens.
///
/// The name arrives already written, generated from the filters, and already
/// selected so a keystroke replaces it. A reader made to invent a name before
/// they have seen the thing be useful usually abandons — and the generated name
/// is genuinely good enough, because it says what the lens does.
struct SaveLensSheet: View {
    let query: SearchQuery
    let onSave: (String) -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(query: SearchQuery, onSave: @escaping (String) -> Void) {
        self.query = query
        self.onSave = onSave
        _name = State(initialValue: SearchLens.describe(query))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save as a lens")
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)

            Text("""
            Lenses sit at the top of Search. This one reruns live — it stores \
            the filters, not the results.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)

            TextField("Name", text: $name)
                .focused($isFocused)
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 12)
                .frame(height: Metrics.field)
                .background(Palette.surfaceField, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusChip, style: .continuous
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1)
                )
                .padding(.top, 20)

            Text("Generated from the filters. Selected, so typing replaces it.")
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 8)

            stored
                .padding(.top, 20)

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                StateAction(title: "Cancel", weight: .aside) { dismiss() }
                    .frame(maxWidth: .infinity)
                StateAction(title: "Save lens", weight: .fixes, action: save)
                    .frame(maxWidth: .infinity)
            }
            // Equal widths, not weighted toward the primary. Cancelling here is
            // not a mistake to be discouraged — the reader may simply have
            // opened the wrong thing.
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .background(Palette.ground)
        .task {
            // A run loop, so the field is on screen before it is asked to take
            // focus; asking during the sheet's presentation is dropped.
            try? await Task.sleep(for: .milliseconds(350))
            isFocused = true
        }
    }

    /// What the lens will actually hold, in one line.
    ///
    /// Shown because the name is editable and about to stop describing the
    /// filters — someone who renames this to "Weekend reading" should still be
    /// able to see what they are saving.
    private var stored: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "What it stores")
            Text(SearchLens.describe(query))
                .typeSmallMeta()
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

/// The control that saves the current filters as a lens.
///
/// One control, living in the sheet that owns filters — so it appears in Search
/// and in Mix without being designed twice. Saving from a results screen would
/// need a second entry point, and two entry points for one action is how they
/// drift apart.
struct SaveLensButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bookmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isEnabled ? Palette.accent : Palette.textQuaternary)
                .frame(width: Metrics.ctaPrimary, height: Metrics.ctaPrimary)
                .background(
                    isEnabled ? Palette.accentTint : Palette.surface,
                    in: RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                        .strokeBorder(
                            isEnabled ? Palette.accent : Palette.border,
                            lineWidth: isEnabled ? 1 : 0.5
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Save these filters as a lens")
        .accessibilityHint(isEnabled ? "" : "Set a filter first")
    }
}
