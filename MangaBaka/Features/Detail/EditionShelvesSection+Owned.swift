import SwiftUI

/// What the page hands the section about the reader's own shelf — see the
/// section's doc comment for why this is an environment value.
struct OwnedShelfControls {
    let seriesID: Int
    let owned: Set<OwnedVolumeKey>
    /// Ticks or unticks one row; the page persists it and updates `owned`.
    let toggle: (EditionVolume) -> Void
    /// Opens the barcode sheet.
    let scan: () -> Void
}

extension EnvironmentValues {
    @Entry var ownedShelf: OwnedShelfControls?
}
