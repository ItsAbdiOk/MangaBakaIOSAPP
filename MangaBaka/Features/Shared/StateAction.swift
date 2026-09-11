import SwiftUI

/// A button on an empty or failed screen, in one of three weights.
///
/// The weight is the message, and the design board is strict about it: an
/// accent fill means *tapping this fixes the thing*. Only one state in the
/// whole family qualifies — "this part needs an account", where Settings is
/// genuinely the answer. "Try again" on an offline screen does not fix being
/// offline, so it does not get the accent, however much a retry button wants
/// to be the loudest thing on an empty screen.
struct StateAction: View {
    enum Weight {
        /// Filled accent. Tapping this fixes the problem.
        case fixes
        /// Filled neutral. A way out, or a retry that might work.
        case wayOut
        /// Outline only. Somewhere else to go, when nothing here is broken.
        case aside
    }

    let title: String
    var weight: Weight = .wayOut
    let action: () -> Void

    /// A disabled control is a different control, not a faded live one.
    ///
    /// Call sites used to reach for `.opacity(0.5)`, which halves the
    /// foreground AND the background together and leaves dim text on a dim
    /// fill: Apple's audit measured the Settings "Save" button at 2.27:1 that
    /// way. Reading it here means every `StateAction` gets the right
    /// treatment instead of each caller remembering to.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .typeCTA()
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 20)
                .frame(minHeight: Metrics.ctaSecondary)
                .background(background, in: Capsule())
                .overlay {
                    if case .aside = weight {
                        Capsule().strokeBorder(Palette.borderPill, lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        guard isEnabled else { return Palette.textMuted }
        return switch weight {
        case .fixes: Palette.onAccent
        case .wayOut: Palette.textPrimary
        case .aside: Palette.textSecondary
        }
    }

    private var background: Color {
        guard isEnabled else { return Palette.surfaceInset }
        return switch weight {
        case .fixes: Palette.accent
        case .wayOut: Palette.surfaceChip
        case .aside: Color.clear
        }
    }
}

/// The mark at the top of a failure: a glyph in a rounded square, not a circle.
///
/// A circle badge reads as a status pip — something that happened to a thing on
/// the screen. A rounded square at 55pt reads as the subject of the screen,
/// which is what a failure state is.
struct StateMark: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 55, height: 55)
            .background(
                Palette.surface,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
