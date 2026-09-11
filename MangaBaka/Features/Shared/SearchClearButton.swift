import SwiftUI

/// The X at the right of a search field.
///
/// One implementation, used by every field in the app that takes a query. It
/// existed only inside `InlineSearchField`, so the two fields people actually
/// search from — the Search tab and the tag picker — had no way to clear
/// themselves but backspacing a sentence one character at a time.
///
/// Absent when the field is empty, because a control that does nothing is worse
/// than no control, and it steals the space the text needs.
struct SearchClearButton: View {
    @Binding var text: String
    /// Called after clearing, for a field that has to react — the Search tab
    /// re-runs its query, the tag picker does not.
    var onClear: (() -> Void)?

    var body: some View {
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            Button {
                text = ""
                onClear?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    // textMuted, not textQuaternary: the latter measured 2.52:1
                    // and this is the control a reader reaches for when a long
                    // query is wrong.
                    .foregroundStyle(Palette.textMuted)
                    // A 16pt glyph is a 16pt target. The tap area is widened to
                    // the platform minimum without the icon growing; it was
                    // 30pt, fourteen under, beside the file that sets 44.
                    .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
        }
    }
}
