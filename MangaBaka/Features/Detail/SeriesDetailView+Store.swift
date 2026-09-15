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

    /// The store's shelf (or MangaBaka's), and under it the catalogues' —
    /// which is a different question and answers it for both branches.
    ///
    /// Under, not merged into: the shelf above is what you can buy, and
    /// `EditionShelvesSection` is what exists and what is coming. Merging them
    /// would put a library record with no price and no cover in a row of
    /// spines, and would lose the per-row link ANN's terms require.
    @ViewBuilder
    var volumesShelf: some View {
        VStack(alignment: .leading, spacing: 22) {
            storeShelf
            EditionShelvesSection(answer: editions, isLoading: isLoadingEditions)
        }
    }

    @ViewBuilder
    private var storeShelf: some View {
        if shelf.isEmpty {
            VolumesSection(
                volumes: extras.volumes,
                seriesCover: shown.cover,
                // The reason and a retry, not one bare line of text: this
                // was the only section on the page outside the failure kit,
                // so offline, a 429, a 5xx and a decode failure all read the
                // same and none of them could be retried (item 60).
                failure: appleFailure,
                retry: { await loadAppleVolumes() },
                // gap 22: while the store is still being asked, the section
                // shows a skeleton instead of MangaBaka's own shelf — showing
                // that first and swapping it for the store's the moment it
                // answers reads as content changing under the reader.
                isCheckingStore: isLoadingVolumes,
                worksTotal: extras.worksTotal,
                seriesDescription: shown.description,
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
        // On-device, no network. Read here as well as in `loadEditions` — the
        // table memoises after its first load, so this is a dictionary lookup,
        // and threading one value between two independent legs would couple
        // them for no gain. See `AppleBooksClient.isNovel(series:format:)` for
        // what it changes and what, measured, it does not.
        let format = await wikidata.format(for: shown)
        var answer = await appleBooks.volumes(
            for: shown, country: country, language: language, format: format
        )
        appleEdition = nil
        // Nothing in the reader's store: the Japanese edition, for the covers
        // and the count. Not for buying — Apple Books purchases are locked to
        // the account's store, so the row says so and shows no price.
        if (try? answer.get())?.isEmpty == true, country.lowercased() != "jp" {
            answer = await appleBooks.japaneseVolumes(for: shown)
            if (try? answer.get())?.isEmpty == false { appleEdition = .japanese }
        }
        // Read after the fallback, and off the fallback's own answer. It used
        // to be `appleUnreachable = answer == nil` computed over an `answer`
        // the Japanese ask had already overwritten, so a reader's store that
        // answered `[]` was blamed for being unreachable and the reader
        // retried a request that would answer `[]` again (item 59).
        switch answer {
        case let .success(volumes):
            appleFailure = nil
            appleVolumes = volumes
        case .failure(.cancelled):
            // The reader left mid-ask. Nothing is written — see
            // `presentableFailure` — and the skeleton is put down here
            // because the reset below is not reached (item 30).
            isLoadingVolumes = false
            return
        case let .failure(error):
            appleFailure = error
            appleVolumes = []
        }

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
    ///
    /// Answers are committed one at a time, in volume order, and the pass is
    /// capped. It used to be an unbounded serial loop in dictionary order
    /// that assigned `openLibraryCovers` only after the last answer, so a
    /// 40-volume series with no publisher art shimmered every spine for two
    /// minutes (40 x the 3 s spacing), showed nothing found, and committed
    /// nothing at all when the reader popped the page. It also made the
    /// "Detail complete" signpost measure Open Library's politeness delay
    /// rather than the page (item 57).
    func loadOpenLibraryCovers() async {
        guard let openLibrary, appleEdition == nil else {
            openLibraryStatus.pass = .answered
            return
        }

        let isbnsByNumber = coverlessISBNs()
        // Nothing to ask about is an answer too: the placeholder may say so.
        guard !isbnsByNumber.isEmpty else {
            openLibraryStatus.pass = .answered
            return
        }

        // Volume order, not dictionary order: a reader watching the shelf
        // fill in sees volume 1 answer first, which is where they are looking.
        let numbers = isbnsByNumber.keys.sorted()
        let asked = numbers.prefix(Self.openLibraryPassLimit)
        var progress = OpenLibraryProgress(pass: .loading)
        for number in asked { progress.byNumber[number] = .loading }
        // The tail is never asked, so it is never `.answered` either — a
        // spine that says "No cover from the publisher" on the strength of a
        // request nobody made is the caption this state exists to prevent.
        for number in numbers.dropFirst(Self.openLibraryPassLimit) {
            progress.byNumber[number] = .notAsked
        }
        openLibraryStatus = progress

        for number in asked {
            guard !Task.isCancelled else { return }
            guard let isbn = isbnsByNumber[number] else { continue }
            let url = await openLibrary.coverURL(isbn: isbn)
            guard !Task.isCancelled else { return }
            // Committed per answer, not per pass: every cover found is on
            // screen the moment it is known, and a pop keeps what has landed.
            if let url { openLibraryCovers[number] = url }
            openLibraryStatus.byNumber[number] = .answered
        }
        openLibraryStatus.pass = .answered
    }

    /// Every volume still missing artwork, keyed by number: MangaBaka's own
    /// volumes with none, plus shelf spines the stores sent no art for.
    private func coverlessISBNs() -> [Int: String] {
        var isbnsByNumber = VolumesSection.isbnsNeedingCovers(extras.volumes)
        for number in VolumeShelf.numbersNeedingCovers(shelf) where isbnsByNumber[number] == nil {
            // Apple and Google carry no ISBN of their own (S1) — the only
            // way to ask Open Library about a shelf gap is to borrow the
            // ISBN MangaBaka's own volume of the same number carries.
            guard let isbn = extras.volumes
                .first(where: { $0.number.flatMap(Int.init) == number })?
                .editions.compactMap(\.isbn).first
            else { continue }
            isbnsByNumber[number] = isbn
        }
        return isbnsByNumber
    }

    /// How many coverless volumes one page open will ask Open Library about.
    ///
    /// A GUESS. Open Library is spaced at one request every 3 s
    /// (`OpenLibraryCovers.minimumInterval`), so twelve is 36 seconds of
    /// background asking — about the length of a page a reader actually
    /// reads — where a 115-volume series uncapped was five and a half
    /// minutes of requests for a shelf nobody is still looking at.
    static let openLibraryPassLimit = 12

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
            return Self.stub(id: neighbour.id, title: title)
        }
    }
}
