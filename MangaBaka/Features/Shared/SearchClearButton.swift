import SwiftUI

/// The X at the right of a search field.
///
/// One implementation, used by every hand-rolled field in the app that takes
/// a query — the tag, genre and seed pickers and `InlineSearchField`. It
/// existed only inside `InlineSearchField`, so the fields people actually
/// search from had no way to clear themselves but backspacing a sentence one
/// character at a time. The Search tab itself no longer uses it: its field
/// is the system's (`SearchField`, 2026-09-13), which clears itself.
///
/// Absent when the field is empty, because a control that does nothing is worse
/// than no control, and it steals the space the text needs.
struct SearchClearButton: View {
    @Binding var text: String
    /// Called after clearing, for a field that has to react — the Search tab
    /// re-runs its query, the tag picker does not.
    var onClear: (() -> Void)?

    private var hasQuery: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if hasQuery {
                Button {
                    text = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .typeSymbol(size: 16, weight: .regular, relativeTo: .callout)
                        // textMuted, not textQuaternary: the latter measured 2.52:1
                        // and this is the control a reader reaches for when a long
                        // query is wrong.
                        .foregroundStyle(Palette.textMuted)
                        // A 16pt glyph is a 16pt target. The tap area is widened to
                        // the platform minimum without the icon growing at the
                        // default text size; it was 30pt, fourteen under, beside
                        // the file that sets 44. Minimums, so the glyph can grow
                        // the target past 44 at accessibility sizes.
                        .frame(minWidth: Metrics.tapTarget, minHeight: Metrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Clear search")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Keyed on `hasQuery` rather than `text` itself: every keystroke is a
        // change to `text`, and this button's own appearance only ever
        // depends on the one boolean crossing.
        .animation(Motion.reduced(Motion.snappy), value: hasQuery)
    }
}
