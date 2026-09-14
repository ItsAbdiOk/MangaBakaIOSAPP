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

    static let textPrimary = Color.white.opacity(0.96)
    /// Detail hero title only.
    static let textEmphasis = Color.white.opacity(0.98)
    static let textBody = Color(hex: 0xEBEBF5).opacity(0.75)
    /// `#EBEBF5` @ 0.60 — `secondaryLabel`'s dark resolution exactly, so this
    /// is the system token rather than a copy of its numbers.
    static let textSecondary = Color(.secondaryLabel)
    /// A deliberate departure: `tertiaryLabel` dark is `#EBEBF5` @ 0.30 and
    /// this is 0.45. The spec's four text levels are spaced more evenly than
    /// Apple's three, and at 0.30 the tertiary level drops under 3:1 against
    /// the app's near-black ground.
    static let textTertiary = Color(hex: 0xEBEBF5).opacity(0.45)
    /// Provenance and attribution footnotes. A deliberate departure:
    /// `quaternaryLabel` dark is `#EBEBF5` @ 0.18 and this is 0.32.
    static let textQuaternary = Color(hex: 0xEBEBF5).opacity(0.32)

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
