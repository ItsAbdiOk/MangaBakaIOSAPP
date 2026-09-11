import SwiftUI

/// The shapes the wrapped screen is built from.
///
/// Its own file because `WrappedView` hit the lint's 250-line body ceiling,
/// and because these are the parts with no opinion in them: a card, a big
/// number, a sentence under it, and a smaller sentence admitting to something.
extension WrappedView {
    // MARK: - Shapes

    func card<Content: View>(
        _ eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: eyebrow)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .hairlineBorder(Palette.border, radius: 20)
    }

    func headline(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
            if !unit.isEmpty {
                Text(unit)
                    .typeSubtitle()
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    func detail(_ text: String) -> some View {
        Text(text)
            .typeBody()
            .foregroundStyle(Palette.textBody)
            .fixedSize(horizontal: false, vertical: true)
    }

    func caveat(_ text: String) -> some View {
        Text(text)
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    func monthName(_ month: Int) -> String {
        DateFormatter().monthSymbols?[max(0, min(11, month - 1))] ?? "\(month)"
    }
}
