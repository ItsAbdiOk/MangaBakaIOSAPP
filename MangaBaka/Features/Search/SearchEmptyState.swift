import SwiftUI

/// What the Search tab says when a query comes back with nothing.
///
/// Its own file for the lint's body-length ceiling, and because it is one idea:
/// an empty result is only honest if it says why. "Nothing matched 'one piece'"
/// was true and useless — a tag picked on another screen was still applied, and
/// nothing on the page said so.
extension SearchView {
    /// Names the filters where there are any. "Try a looser filter" is advice;
    /// "3 filters are still applied" is the answer.
    var emptyAdvice: String {
        let count = model.query.activeFilterCount
        guard count > 0 else { return "Try a looser filter, or let the API pick." }
        return count == 1
            ? "One filter is still applied."
            : "\(count) filters are still applied."
    }

    var emptyState: some View {
        VStack(spacing: 0) {
            Text("Nothing matched \(displayedQuery)")
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
            Text(emptyAdvice)
                .typeInstruction()
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            if model.query.activeFilterCount > 0 {
                Button {
                    Task { await model.clearFilters() }
                } label: {
                    Text("Clear filters")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Palette.surfaceChip, in: Capsule())
                }
                .buttonStyle(.press)
                .padding(.top, 16)
            }
            Button {
                model.query.sort = "random"
                Task { model.cancelPendingDebounce(); await model.search() }
            } label: {
                Text("Random with these filters")
                    .typeRowTitle()
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.press)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 34)
    }
}
