import SwiftUI

/// The stack's title, its saved counter, and the way to start over.
///
/// Title and counter sit side by side until the text is large enough that they
/// squeeze each other — at which point the title truncated to "The sta…" and
/// the counter broke into "4" over "saved".
struct StackHeader: View {
    let savedCount: Int
    /// Where the cards came from, said under the title.
    let provenance: String
    /// False once the reader has dragged a card. See `StackHint`.
    let showsInstruction: Bool
    let onReset: () async -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                title
                count
            }
            .padding(.horizontal, Metrics.gutterStack)
            .padding(.bottom, 14)
            .overlay(alignment: .topTrailing) { StackResetMenu(onReset: onReset) }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title
                Spacer(minLength: 0)
                count
                StackResetMenu(onReset: onReset)
            }
            .padding(.horizontal, Metrics.gutterStack)
            .padding(.bottom, 14)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The stack")
                .typeStackTitle()
                .foregroundStyle(Palette.textEmphasis)
                .fixedSize(horizontal: false, vertical: true)
            Text(provenance)
                .typeInstruction()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if showsInstruction {
                Text("Drag the cover aside · tap it to open")
                    .typeInstruction()
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var count: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(savedCount)")
                .countsNotCuts()
                .animation(Motion.reduced(.snappy(duration: 0.25)), value: savedCount)
                .typeStatNumber()
                .foregroundStyle(Palette.accent)
            Text("saved")
                .typeGridMeta()
                .foregroundStyle(Palette.textMuted)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(savedCount) saved")
    }
}
