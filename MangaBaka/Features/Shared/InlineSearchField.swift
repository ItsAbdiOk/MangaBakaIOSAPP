import SwiftUI

/// The app's own search field, for filtering a list that is already on screen.
///
/// Distinct from the Search tab, which asks MangaBaka a question. This one only
/// narrows what the reader already has, so it never spins and never fails.
///
/// It exists as a component because a shelf of 429 dropped series has the same
/// problem the whole library does — you cannot scroll to a title you can name —
/// and two copies of a control drift apart.
struct InlineSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
            SearchClearButton(text: $text)
        }
        .padding(.horizontal, 13)
        .frame(height: Metrics.field)
        .background(Palette.surfaceField, in: RoundedRectangle(
            cornerRadius: 13, style: .continuous
        ))
        .hairlineBorder(Palette.hairline, radius: 13)
    }
}
