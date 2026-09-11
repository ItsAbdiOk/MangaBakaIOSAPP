import SwiftUI

/// The volumes shelf: the store's when it has one, MangaBaka's otherwise.
///
/// Its own file because `SeriesDetailView` is at the lint's body-length
/// ceiling.
extension SeriesDetailView {
    /// Never both — the same volume twice is a bug.
    @ViewBuilder
    var volumesShelf: some View {
        if appleVolumes.isEmpty {
            VolumesSection(
                volumes: extras.volumes,
                note: appleUnreachable ? "Apple Books couldn't be reached" : nil
            )
        } else {
            AppleVolumesRow(volumes: appleVolumes, expected: shown.finalVolume.map { Int($0) })
        }
    }

    /// One request, cached a week, after the page is readable: the shelf is
    /// below the fold and the store is a third party with its own limit.
    func loadAppleVolumes() async {
        guard let appleBooks else { return }
        let country = Locale.current.region?.identifier ?? "us"
        let answer = await appleBooks.volumes(for: shown, country: country)
        appleUnreachable = answer == nil
        appleVolumes = answer ?? []
    }
}
