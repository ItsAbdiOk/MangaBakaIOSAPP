import SwiftUI

/// A row heading with an optional trailing action.
struct SectionHeader: View {
    let title: String
    var action: (title: String, handler: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .typeSectionHeader()
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: Metrics.gapStrip)

            if let action {
                Button(action.title, action: action.handler)
                    .typeChip()
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

/// The small uppercase label above a group.
struct Eyebrow: View {
    let text: String
    var color: Color = Palette.textTertiary

    var body: some View {
        Text(text.uppercased())
            .typeEyebrow()
            .foregroundStyle(color)
            // "49 ESTIMATED OF 55 IN SCOPE" counts up as a measurement lands.
            .countsNotCuts()
            .animation(Motion.reduced(.snappy(duration: 0.25)), value: text)
    }
}
