import SwiftUI

/// The parts every Settings section is built from.
///
/// Settings had six sections and six private ways of drawing a row. One set of
/// pieces means the design board can be followed once rather than six times,
/// and means the next section costs a call rather than a layout.
struct SettingsSection<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: title)
            if let caption {
                Text(caption)
                    .typeSubtitle()
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            content
                .padding(.top, 14)
        }
    }
}

/// Rows on one rounded card, hairline-divided.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
    }
}

/// A hairline between two rows, inset to the row's own padding rather than
/// bleeding to the card edge — the standard grouped-list treatment, and the
/// thing that makes a card read as a list rather than as a block.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

/// One row: a title, a caption, and something on the right.
///
/// The row restacks above the accessibility text sizes rather than squeezing.
/// Side by side at 1.6x the title and the switch fight for the same 393pt and
/// the caption wraps to four lines; stacked, nothing has to give.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let caption: String?
    /// Dimmed only when the row genuinely does nothing. A locked row is not
    /// this — see `LockPill`.
    var isDimmed = false
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: 10) {
                    label
                    trailing
                }
            } else {
                HStack(spacing: 12) {
                    label
                    trailing
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // minHeight, never height: two lines of scaling text in a fixed box is
        // what made one row's caption overlap the next row's title.
        .frame(minHeight: 63)
        .contentShape(Rectangle())
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .typeRowTitle()
                .foregroundStyle(isDimmed ? Palette.textTertiary : Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Text(caption)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch that is a picture of a switch.
///
/// **51x31 with a 27pt knob — UIKit's exact metrics.** This overturns an
/// earlier decision here to draw it at 46x28 because the real size looked
/// "noticeably larger than every other control on the same screen". The design
/// board asks for the system metrics twice, and it is right: a drawn control
/// that is *nearly* the system's reads as a slightly wrong copy, and 51x31 is
/// also the hit target people's thumbs are trained on. Aesthetics lost to
/// muscle memory.
///
/// It is a picture because the real `Toggle` here only ever responded to a drag
/// across it, never to a tap — verified repeatedly on device. The row behind it
/// is the control. See the note in `SettingsView`.
struct SwitchIndicator: View {
    let isOn: Bool

    private static let trackWidth: CGFloat = 51
    private static let trackHeight: CGFloat = 31
    private static let knob: CGFloat = 27

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Palette.accent : Palette.switchOff)
                .frame(width: Self.trackWidth, height: Self.trackHeight)
            Circle()
                .fill(.white)
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(.horizontal, 2)
        }
        .frame(width: Self.trackWidth, height: Self.trackHeight)
        .animation(.snappy(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

/// What sits where a switch would, on a row that is a rule rather than a
/// choice.
///
/// A dimmed switch reads as "broken, or not yours yet". A padlock and the words
/// "Always on" read as a rule someone decided — which is what this is: safe
/// content cannot be excluded, because a reader who excluded everything would
/// get an empty app with no explanation.
struct LockPill: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Always on")
                .typeChip()
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 10)
        .frame(minHeight: Metrics.headerPill)
        .background(Palette.surfaceChip, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
        .tapTarget()
        .accessibilityLabel("Always on")
    }
}

/// The heavier of the two warnings, for a change that discards content the
/// moment it is made.
///
/// Formats gets a plain grey line for the same mechanism, because its blast
/// radius is smaller. Two weights for two sizes of consequence — and if
/// everything got the tinted box, the box would stop meaning anything.
struct RefetchCallout: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .typeSmallMeta()
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accentTint, in: RoundedRectangle(
            cornerRadius: Metrics.radiusChip, style: .continuous
        ))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .strokeBorder(Palette.accentEdge, lineWidth: 1)
        )
    }
}
