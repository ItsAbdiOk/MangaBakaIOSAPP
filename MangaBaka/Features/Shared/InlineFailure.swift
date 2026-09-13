import SwiftUI

/// One muted line for a section that asked for something and failed, sitting
/// under the section's own header rather than replacing the section.
///
/// The distinction `Fetched<T>` exists to draw: a section that *asked and got
/// nothing back* (no error) simply isn't shown — there is nothing to say. A
/// section that *asked and failed* owes the reader one line saying so and a
/// way to try again, rather than vanishing identically to the first case
/// (gap 16, 17, 18, 19, 21: similar/cast/cadence/release/volumes rows all
/// disappear on failure today, indistinguishable from "nothing here").
struct InlineFailure: View {
    let error: APIError
    var retry: (() async -> Void)?

    @State private var isRetrying = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error.symbolName)
                .typeSymbol(size: 13, weight: .regular)
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(oneSentence(error.userFacingMessage))
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let retry {
                StateAction(title: isRetrying ? "Retrying…" : "Retry", weight: .aside) {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        await retry()
                        isRetrying = false
                    }
                }
                .disabled(isRetrying)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .accessibilityElement(children: .combine)
    }

    /// `userFacingMessage` is written to stand alone on a full failure
    /// screen and can run two or three sentences (see `.needsAccount`'s
    /// copy). A section slot gets one line under a header it already has, so
    /// only the first sentence is kept — the rest is detail this cramped a
    /// spot cannot afford and the reader did not ask for anyway.
    private func oneSentence(_ message: String) -> String {
        let collapsed = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let period = collapsed.firstIndex(of: ".") else { return collapsed }
        return String(collapsed[collapsed.startIndex...period])
    }
}
