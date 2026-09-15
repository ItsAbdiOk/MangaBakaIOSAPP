import SwiftUI
import UIKit

/// Colours from the BakaManga design spec.
///
/// Two rules from that spec are load-bearing and easy to break by accident:
/// raised surfaces are always translucent white over the ground, never solid
/// greys, and every border is 0.5pt rather than 1pt.
enum Palette {
    // MARK: Grounds

    /// Every screen's background. A deliberate departure: `systemBackground`
    /// dark is `#000000` and `secondarySystemBackground` is `#1C1C1E`; the
    /// spec's ground is the near-black between them, and the contrast figures
    /// recorded for the text tokens are all measured against this value.
    static let ground = Color(hex: 0x08080B)
    /// Cover and image placeholder, shown behind art while it loads.
    static let imagePlaceholder = Color(hex: 0x131318)

    // MARK: Raised surfaces — white over the ground, never solid grey

    /// Inset row inside an already-bordered card.
    static let surfaceInset = Color.white.opacity(0.035)
    /// Standard card fill.
    static let surface = Color.white.opacity(0.045)
    /// Chip or secondary button, unselected.
    static let surfaceChip = Color.white.opacity(0.06)
    /// Search field.
    static let surfaceField = Color.white.opacity(0.09)

    // MARK: Text
    //
    // The spec collapses the drifted values to exactly four levels. Anything
    // between them is a mistake, not a nuance.

    // Where a spec value is bit-for-bit a system semantic colour, the system
    // one is used: the app pins `.preferredColorScheme(.dark)` at the root and
    // in every sheet, so the dark resolution is the only one that ever
    // renders, and taking the semantic token costs the mockup nothing while
    // gaining Increase Contrast, Smart Invert and Differentiate Without
    // Colour — all of which a hard-coded hex silently ignores. The three
    // deliberate departures are recorded on the lines below, with how far
    // each is from the system colour it resembles (measured against the iOS
    // 26.5 dark resolutions, 2026-09-14).

    // S16: within 4% of `.label`'s dark resolution (white @ 1.0, measured
    // 2026-09-14) — the same reasoning `textSecondary` below already applies
    // to itself. Taking the semantic token costs the mockup nothing anyone
    // can see and gains Increase Contrast and Smart Invert on every primary
    // and emphasis text in the app, same as `textSecondary`.
    static let textPrimary = Color(.label)
    /// Detail hero title only.
    static let textEmphasis = Color(.label)
    static let textBody = Color(hex: 0xEBEBF5).opacity(0.75)
    /// `#EBEBF5` @ 0.60 — `secondaryLabel`'s dark resolution exactly, so this
    /// is the system token rather than a copy of its numbers.
    static let textSecondary = Color(.secondaryLabel)
    /// **Marks and inactive controls, not running text.** A deliberate
    /// departure: `tertiaryLabel` dark is `#EBEBF5` @ 0.30 and this is 0.45.
    /// The spec's four text levels are spaced more evenly than Apple's three,
    /// and at 0.30 the tertiary level drops under 3:1 against the app's
    /// near-black ground.
    ///
    /// 3.96:1 on `ground` and 3.89:1 on a row's tinted ground (computed
    /// 2026-09-14, `PaletteContrastFloorTests`). That clears WCAG 1.4.11's
    /// 3:1 for non-text — a chevron, a spinner, an empty star, a status dot —
    /// and clears the "inactive user interface component" exemption in both
    /// 1.4.3 and 1.4.11 for a disabled control. It does **not** clear 4.5:1,
    /// so anything a reader has to read wants `textMuted` (4.66:1) or better.
    static let textTertiary = Color(hex: 0xEBEBF5).opacity(0.45)

    // There is no fifth level. `textQuaternary` was `#EBEBF5` @ 0.32, and it
    // was retired on 2026-09-14 rather than repaired, because the arithmetic
    // left nowhere to put it (computed in `PaletteContrastFloorTests`):
    //
    //   - it measured 2.52:1 on `ground`, which fails 4.5:1 for text and also
    //     3:1 for non-text, so it failed on every reading;
    //   - reaching 4.5:1 on this ground needs alpha 0.489, and reaching even
    //     3:1 needs 0.369 — so a "quaternary" level that passes AA for text
    //     is brighter than `textTertiary` at 0.45 and all but identical to
    //     `textMuted` at 0.50. A fifth level below the fourth cannot both
    //     exist and pass;
    //   - none of its 15 call sites was the "provenance and attribution
    //     footnote" its own doc comment described. Every one was a mark, a
    //     disabled control, or body text that had no business being there.
    //
    // The spec collapsed the text levels to four; this is that, arrived at
    // from the contrast side. Reaching for a fainter level than
    // `textTertiary` is the mistake this note exists to catch.

    // MARK: Accent

    /// oklch(0.72 0.16 30) — approximately #FF7F63.
    /// The mockup states this as `oklch(0.72 0.16 30)`, which converts to
    /// #F87966. It was #FF7F63 before, a difference of about 7/255 per channel
    /// — invisible, but it is the spec, so it is the spec.
    static let accent = Color(hex: 0xF87966)
    /// Text and icons on an accent fill. Never white: white on this fails contrast.
    static let onAccent = Color(hex: 0x180B06)
    /// oklch(0.72 0.16 145). Used only for the cached indicator dot.
    /// The mockup's oklch(0.72 0.16 145), converted. Used for the cached dot.
    static let positive = Color(hex: 0x5BBE62)

    /// The one amber in the app, and it means exactly one thing: what you are
    /// looking at is real but out of date.
    ///
    /// Deliberately not the accent. The accent means "tap me"; a stale bar is a
    /// fact with an optional action. Sampled from the design board at #EFA831.
    /// If a second thing ever wants amber, that is the moment to stop and ask
    /// what the colour is supposed to mean.
    static let stale = Color(hex: 0xEFA831)

    /// A switch that is off. iOS's own off-track grey rather than the app's
    /// chip fill, because the drawn switch is meant to be indistinguishable
    /// from a real one and this is the colour a real one uses — so it is
    /// `systemGray5` itself, whose dark resolution is the `#2C2C2E` this used
    /// to spell out. A drawn control that tracks the real one through
    /// Increase Contrast is the whole point of drawing it to system metrics.
    static let switchOff = Color(.systemGray5)

    /// Paused, in the library's own colour set.
    ///
    /// Its own token rather than reusing `stale`, which is a near-identical
    /// orange. They mean unrelated things — one is "you set this down", the
    /// other is "what you are looking at is out of date" — and a colour that
    /// carries two meanings carries neither. Sampled from the design board.
    static let paused = Color(hex: 0xE38D3D)

    /// The tinted callout: a wash of the accent dark enough to sit under body
    /// text, with a matching edge. Used where a setting discards content the
    /// moment it changes. Sampled from the design board.
    static let accentTint = Color(hex: 0x160B09)
    static let accentEdge = Color(hex: 0x47231D)

    // MARK: Borders — always 0.5pt

    /// Meta lines and inactive tab labels. Between textSecondary and
    /// textTertiary, and the mockup uses it often enough to name.
    static let textMuted = Color(hex: 0xEBEBF5).opacity(0.50)

    /// The dark badge sitting on a cover. rgba(10,10,12,0.6).
    static let surfaceBadge = Color(hex: 0x0A0A0C).opacity(0.60)
    /// A small pill. rgba(255,255,255,0.07).
    static let surfacePill = Color.white.opacity(0.07)
    static let borderPill = Color.white.opacity(0.12)

    static let hairline = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.10)
    static let glassEdge = Color.white.opacity(0.13)
    /// Dashed, for empty and add affordances only.
    static let borderDashed = Color.white.opacity(0.20)
}

extension Color {
    /// Hex literal, e.g. `Color(hex: 0x08080B)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
