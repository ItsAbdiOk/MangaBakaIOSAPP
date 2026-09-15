import Foundation

/// Whether the app is running under the App Store screenshot capture harness.
///
/// Abdi's instruction (2026-09-15): screenshots and promo material must never
/// show real cover art — it is licensed per-series and MangaBaka does not
/// have the rights to redistribute it in marketing material. `CoverImage`
/// reads `isActive` to swap every cover, real or BlurHash, for a generated
/// placeholder; see its `background` property.
enum ScreenshotMode {
    /// Read once, not on every check. `ProcessInfo.arguments` is fixed for
    /// the life of the process, and a grid can hold sixty `CoverImage`s each
    /// re-checking it on every body evaluation — a `nonisolated static let`
    /// costs one scan for the whole run instead of one per cover per redraw.
    ///
    /// `-mb-placeholder-covers` is passed only by
    /// `ScreenshotCaptureTests.launchedApp()`; the ordinary app, the
    /// accessibility audit's `AccessibilityAuditTests.launchedApp()`, and
    /// every unit test target launch without it, so this is `false`
    /// everywhere except the capture run.
    nonisolated static let isActive: Bool = ProcessInfo.processInfo.arguments.contains(
        "-mb-placeholder-covers"
    )

    /// A hue in `0..<1` for the placeholder gradient `CoverImage` draws when
    /// `isActive`, so a grid of generated placeholders reads as a grid of
    /// distinct series rather than one repeated grey card.
    ///
    /// Multiplies the id by the golden ratio conjugate and keeps the
    /// fractional part — Knuth's multiplicative hash, a standard
    /// low-discrepancy sequence. Sequential ids (1, 2, 3 — exactly what a
    /// feed of series looks like) land far apart on the hue wheel instead of
    /// a naive `id / someMax` walking around it in a slow, visible ramp.
    /// Pure and `nonisolated static` so it needs no view, no device, and no
    /// screenshot to test.
    nonisolated static func placeholderHue(for seriesID: Int) -> Double {
        let goldenConjugate = 0.6180339887498949
        let scaled = Double(seriesID) * goldenConjugate
        return scaled - scaled.rounded(.down)
    }
}
