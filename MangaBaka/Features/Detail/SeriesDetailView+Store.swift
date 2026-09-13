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
                seriesCover: shown.cover,
                note: appleUnreachable ? "Apple Books couldn't be reached" : nil,
                // gap 22: while the store is still being asked, the section
                // shows a skeleton instead of MangaBaka's own shelf — showing
                // that first and swapping it for the store's the moment it
                // answers reads as content changing under the reader.
                isCheckingStore: isLoadingVolumes,
                openLibraryCovers: openLibraryCovers,
                openLibraryStatus: openLibraryStatus
            )
        } else {
            AppleVolumesRow(
                volumes: shelf,
                expected: shown.finalVolume.map { Int(wholeOrClamped: $0) },
                edition: appleEdition,
                seriesCover: shown.cover,
                openLibraryCovers: openLibraryCovers,
                openLibraryStatus: openLibraryStatus
            )
        }
    }

    /// One request, cached a week, after the page is readable: the shelf is
    /// below the fold and the store is a third party with its own limit.
    func loadAppleVolumes() async {
        guard let appleBooks else {
            // No Apple client at all still leaves MangaBaka's own volumes on
            // screen (`VolumesSection`) worth filling gaps in.
            await loadOpenLibraryCovers()
            return
        }
        isLoadingVolumes = true
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
        if appleEdition == nil,
           VolumeShelf.needsGoogle(
             apple: appleVolumes, expected: shown.finalVolume.map { Int(wholeOrClamped: $0) }
           ) {
            googleVolumes = await googleBooks?.volumes(for: shown, language: language) ?? []
        }
        // The shelf itself is decided the moment Apple and Google have both
        // answered — `isLoadingVolumes` ends here, not after Open Library,
        // so the skeleton never sits through a third, spaced-out pass the
        // shelf's own shape does not depend on.
        isLoadingVolumes = false
        // Open Library, last, and not awaited by anything the shelf itself
        // needs: `appleEdition == nil` is checked again inside — the
        // Japanese shelf is skipped there too.
        await loadOpenLibraryCovers()
    }

    /// A follow-up pass, run after Apple and Google have both had their
    /// turn, that asks `OpenLibraryCovers` for whatever is still missing
    /// artwork — MangaBaka's own volumes with none, and shelf spines the
    /// stores sent no art for. Deliberately its own call, not folded into
    /// `loadAppleVolumes`: this must never be what a reader on the fast path
    /// (Apple carries the whole series) waits on.
    ///
    /// The Japanese-edition shelf is skipped: it is Apple's single foreign
    /// storefront, not matched against MangaBaka's own ISBNs, and asking for
    /// covers on someone else's numbering scheme is a coincidence away from
    /// showing the wrong volume's art.
    func loadOpenLibraryCovers() async {
        guard let openLibrary, appleEdition == nil else { openLibraryStatus = .answered; return }

        var isbnsByNumber = VolumesSection.isbnsNeedingCovers(extras.volumes)
        let shelfGaps = VolumeShelf.numbersNeedingCovers(shelf)
        for number in shelfGaps where isbnsByNumber[number] == nil {
            // Apple and Google carry no ISBN of their own (S1) — the only
            // way to ask Open Library about a shelf gap is to borrow the
            // ISBN MangaBaka's own volume of the same number carries.
            guard let isbn = extras.volumes
                .first(where: { $0.number.flatMap(Int.init) == number })?
                .editions.compactMap(\.isbn).first
            else { continue }
            isbnsByNumber[number] = isbn
        }
        // Nothing to ask about is an answer too: the placeholder may say so.
        guard !isbnsByNumber.isEmpty else { openLibraryStatus = .answered; return }

        openLibraryStatus = .loading
        var found: [Int: URL] = [:]
        for (number, isbn) in isbnsByNumber {
            guard !Task.isCancelled else { return }
            if let url = await openLibrary.coverURL(isbn: isbn) {
                found[number] = url
            }
        }
        guard !Task.isCancelled else { return }
        openLibraryCovers = found
        openLibraryStatus = .answered
    }

    /// "Similar by description": ids ranked by `EmbeddingIndex`, resolved to
    /// enough of a `Series` for a cover card — a title, no more.
    ///
    /// Deliberately not `repository.series(id:)` per neighbour: that method
    /// falls back to one GET per cache miss, and firing twelve of them for
    /// one row is exactly what the brief for this row rules out.
    /// `OfflineCatalogue.titles(for:)` answers from the same bundled 19k
    /// title list the embedding ids are drawn from, so this never touches
    /// the network — a card whose id has no title (should not happen, since
    /// both files are exports of the same 19k series, but not proven here)
    /// is simply dropped rather than shown with an empty label.
    ///
    /// **Requires `func titles(for ids: [Int]) -> [Int: String]` on
    /// `OfflineCatalogue`** (`MangaBaka/Core/Offline/OfflineCatalogue.swift`)
    /// — that actor landed this round with `matches(_:...)` and `count(_:...)`
    /// (both `SearchQuery`-shaped) but no lookup by id; this needs a small
    /// addition, e.g. `entries.filter { ids.contains($0.id) }` over its
    /// private `entries`, mapped to `[$0.id: $0.t]`.
    func loadSimilarByDescription() async {
        guard let neighbours = await embeddingIndex.neighbours(of: series.id),
              !neighbours.isEmpty
        else {
            similarByDescription = []
            return
        }
        let titles = await offlineCatalogue.titles(for: neighbours.map(\.id))
        similarByDescription = neighbours.compactMap { neighbour -> Series? in
            guard let title = titles[neighbour.id] else { return nil }
            return Series(
                id: neighbour.id,
                state: "active",
                mergedWith: nil,
                titles: [SeriesTitle(language: "en", traits: ["official"], title: title, isPrimary: true)],
                cover: .empty,
                description: nil,
                authors: nil,
                artists: nil,
                status: nil,
                rating: nil,
                type: nil,
                contentRating: nil,
                totalChapters: nil,
                finalVolume: nil,
                publishers: nil,
                anime: nil,
                source: nil
            )
        }
    }
}
