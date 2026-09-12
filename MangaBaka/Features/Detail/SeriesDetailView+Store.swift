import SwiftUI

/// The volumes shelf: the store's when it has one, MangaBaka's otherwise.
///
/// Its own file because `SeriesDetailView` is at the lint's body-length
/// ceiling.
extension SeriesDetailView {
    /// Apple's volumes, plus any number only Google has. Never both for one
    /// number — the same volume twice is a bug. See `VolumeShelf.merge`.
    var shelf: [ShelfVolume] {
        VolumeShelf.merge(apple: appleVolumes, google: googleVolumes)
    }

    @ViewBuilder
    var volumesShelf: some View {
        if shelf.isEmpty {
            VolumesSection(
                volumes: extras.volumes,
                note: appleUnreachable ? "Apple Books couldn't be reached" : nil
            )
        } else {
            AppleVolumesRow(
                volumes: shelf,
                expected: shown.finalVolume.map { Int($0) },
                edition: appleEdition
            )
        }
    }

    /// One request, cached a week, after the page is readable: the shelf is
    /// below the fold and the store is a third party with its own limit.
    func loadAppleVolumes() async {
        guard let appleBooks else { return }
        let country = Locale.current.region?.identifier ?? "us"
        let language = Locale.current.language.languageCode?.identifier
        var answer = await appleBooks.volumes(for: shown, country: country, language: language)
        appleEdition = nil
        // Nothing in the reader's store: the Japanese edition, for the covers
        // and the count. Not for buying — Apple Books purchases are locked to
        // the account's store, so the row says so and shows no price.
        if answer?.isEmpty == true, country.lowercased() != "jp" {
            answer = await appleBooks.japaneseVolumes(for: shown)
            if answer?.isEmpty == false { appleEdition = .japanese }
        }
        appleUnreachable = answer == nil
        appleVolumes = answer ?? []

        // Google only fills gaps, so it is only asked when there are gaps —
        // a series Apple carries end to end costs no Google request at all.
        // The Japanese shelf is left alone: it is one store's single edition,
        // and splicing a second store's covers into it would misrepresent it.
        guard appleEdition == nil,
              VolumeShelf.needsGoogle(apple: appleVolumes, expected: shown.finalVolume.map { Int($0) })
        else { return }
        googleVolumes = await googleBooks?.volumes(for: shown, language: language) ?? []
    }
}
