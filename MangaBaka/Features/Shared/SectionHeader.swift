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
    /// `textMuted`, not `textTertiary`, since 2026-09-14.
    ///
    /// An eyebrow is 11pt semibold, which is not large text by any reading of
    /// WCAG (18pt regular, or 14pt bold), so AA wants 4.5:1. Computed from
    /// the tokens and checked against the audit's own screenshots:
    /// `textTertiary` draws at 3.95:1 on `Palette.ground` and `textMuted` at
    /// 4.66:1. This one default was every "Contrast nearly passed" row the
    /// 2026-09-13 audit filed against a group label — MINIMUM RATING and
    /// REQUIRE TAGS on Mix, TYPE / STATUS / SORT / MINIMUM RATING / YEAR and
    /// NARROW BY on Search, and GENRES, THEMES, ACCOUNT, SERIES TITLES and
    /// FORMATS on the series page and in Settings. "Nearly" was the audit
    /// being polite about a real miss. No call site passes this argument;
    /// it stays only as the escape hatch it always was.
    var color: Color = Palette.textMuted

    var body: some View {
        Text(text.uppercased())
            .typeEyebrow()
            .foregroundStyle(color)
            // "49 ESTIMATED OF 55 IN SCOPE" counts up as a measurement lands.
            .countsNotCuts()
            .animation(Motion.reduced(Motion.snappy), value: text)
    }
}
