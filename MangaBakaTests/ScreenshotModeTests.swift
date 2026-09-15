import Foundation
import Testing
@testable import MangaBaka

/// `ScreenshotMode.placeholderHue` — the seed for the generated placeholder
/// `CoverImage` draws instead of real art when capturing App Store
/// screenshots (Abdi, 2026-09-15: no real covers in screenshots or promo,
/// licensing). Before this type existed there was no hue function at all, so
/// every one of these would have failed to compile — that is the pre-change
/// failure for a type that did not exist yet.
@Suite("Screenshot placeholder hue")
struct ScreenshotModeTests {
    @Test("Deterministic: the same id always yields the same hue")
    func deterministic() {
        let first = ScreenshotMode.placeholderHue(for: 377)
        let second = ScreenshotMode.placeholderHue(for: 377)
        #expect(first == second)
    }

    @Test("Always lands in 0..<1, across a spread of ids including zero and negative")
    func inUnitRange() {
        for id in [0, 1, 2, 377, 1_000_000, -1, -50] {
            let hue = ScreenshotMode.placeholderHue(for: id)
            #expect(hue >= 0)
            #expect(hue < 1)
        }
    }

    @Test("Two different ids differ — the grid should not read as one repeated block")
    func distinctIDsDiffer() {
        #expect(ScreenshotMode.placeholderHue(for: 1) != ScreenshotMode.placeholderHue(for: 2))
        #expect(ScreenshotMode.placeholderHue(for: 1) != ScreenshotMode.placeholderHue(for: 3))
    }

    @Test("Sequential ids are not a slow ramp around the wheel")
    func sequentialIDsSpread() {
        // A naive `id / someMax` hue would put 1 and 2 a hair apart. The
        // golden-ratio-conjugate hash should separate them by roughly 0.618
        // of the wheel (mod 1), not by a sliver.
        let first = ScreenshotMode.placeholderHue(for: 1)
        let second = ScreenshotMode.placeholderHue(for: 2)
        #expect(abs(first - second) > 0.2)
    }
}
