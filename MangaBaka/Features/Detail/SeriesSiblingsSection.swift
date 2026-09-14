import SwiftUI

/// "Also exists as": the other formats of the same story — the light novel a
/// manga adapts, the manga a light novel became — from the bundled Wikidata
/// identity table. See `WikidataIdentityTable.siblings(for:)`, which this
/// section's row list is built from (`SeriesDetailView+Siblings.swift`).
///
/// **Absence means nothing.** `WikidataIdentityTable`'s own doc comment
/// records how far it reaches: a quarter of the catalogue by row, nine in ten
/// of what a reader actually opens. A series with nothing here may simply not
/// be in the table — never evidence that it exists in only one format. The
/// section hides itself entirely rather than say so.
struct SeriesSiblingsSection: View {
    let rows: [SeriesSiblingRow]
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Also exists as")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)

                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(Palette.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(Palette.surface, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusCard, style: .continuous
                ))
                .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    @ViewBuilder
    private func rowView(_ row: SeriesSiblingRow) -> some View {
        if let mangaBakaID = row.mangaBakaID {
            Button {
                // A text row, not a cover, so the zoom grows out of the row
                // itself — `ZoomRouteCoverageTests` holds every push to the
                // same rule, and a row that slid while its neighbours zoomed
                // is exactly the inconsistency that rule exists for.
                zoomRoute?.source = ZoomRoute.id("sibling", mangaBakaID)
                zoomRoute?.neighbours = []
                // A stub, not a full record — the same pattern
                // `SeriesDetailView.loadSimilarByDescription()` uses for an
                // id the page has never fetched: `SeriesDetailView.shown`
                // fills the rest in once the push lands and `loadCore` runs
                // for the new id, so nothing here needs to duplicate that
                // fetch.
                path.append(Self.stub(id: mangaBakaID, title: row.title))
            } label: {
                content(row)
            }
            .zoomSource("sibling", mangaBakaID)
            .buttonStyle(.press)
            .accessibilityHint("Opens \(row.title) in MangaBaka")
        } else {
            content(row)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func content(_ row: SeriesSiblingRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if row.mangaBakaID == nil {
                    Text("Not on MangaBaka")
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            Spacer(minLength: 8)
            Text(row.formatLabel)
                .typeGridMeta()
                .foregroundStyle(Palette.textMuted)
            if row.mangaBakaID != nil {
                Image(systemName: "chevron.right")
                    .typeSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Metrics.ctaSecondary)
    }

    /// A minimal `Series` carrying only what `SeriesSiblingRow` knows.
    /// `loadSimilarByDescription()` in `SeriesDetailView+Store.swift` builds
    /// the same shape for an embedding neighbour the page has not fetched —
    /// copied rather than shared because that one is `private` to its file.
    private static func stub(id: Int, title: String) -> Series {
        Series(
            id: id, state: "active", mergedWith: nil,
            titles: [SeriesTitle(language: "en", traits: ["official"], title: title, isPrimary: true)],
            cover: .empty, description: nil, authors: nil, artists: nil, status: nil, rating: nil,
            type: nil, contentRating: nil, totalChapters: nil, finalVolume: nil, publishers: nil,
            anime: nil, source: nil
        )
    }
}

/// One row: a sibling work's format, its title, and its MangaBaka id when it
/// has one. Derivation kept `nonisolated static` and apart from
/// `WikidataIdentity` itself so it can be unit-tested with a fixture rather
/// than only against the real 8,816-row table — see `SeriesSiblingsTests`.
struct SeriesSiblingRow: Identifiable, Equatable {
    /// The sibling's own QID. Stable and unique, unlike `mangaBakaID`, which
    /// is nil for a sibling only Wikidata and AniList/MangaUpdates know
    /// about — that is the "not on MangaBaka" row.
    let id: Int
    let formatLabel: String
    let title: String
    let mangaBakaID: Int?

    /// Every non-`.other` sibling, formatted for the row.
    ///
    /// Title: the English title when the table has one, else the native
    /// title — never a romanisation. `WikidataIdentity.nativeTitle` is
    /// already the original script, chosen by `P407` (language of work), so
    /// falling back to it is not a downgrade to transliteration the way
    /// falling back to a Latin-alphabet label would be. A sibling with
    /// neither is dropped: a row with no title to show is not a row.
    ///
    /// `.other` is dropped rather than labelled: Wikidata's `P31` collapses
    /// an anime, a film and a video game into one bucket
    /// (`WikidataFormat.other`'s own doc comment), and no single word is
    /// right for all three, so the row is skipped instead of guessing.
    nonisolated static func rows(for siblings: [WikidataIdentity]) -> [SeriesSiblingRow] {
        siblings.compactMap { sibling in
            guard let label = formatLabel(for: sibling.format) else { return nil }
            guard let title = displayTitle(for: sibling) else { return nil }
            return SeriesSiblingRow(
                id: sibling.qid, formatLabel: label, title: title, mangaBakaID: sibling.mangaBakaID
            )
        }
    }

    /// The English title unless Wikidata's "English" label is a romanisation,
    /// in which case the native title — the app shows English and the
    /// original language, never a transliteration.
    ///
    /// **A heuristic, and a partial one.** Wikidata's `en` label is a romaji
    /// reading for a good part of the catalogue: on the shipped table
    /// 1,043 of 8,657 English labels carry a Hepburn macron (counted
    /// 2026-09-14), and a sim walk put "Kusuriya no Hitorigoto: Mao Mao no
    /// Kōkyū Nazotoki Techō" on The Apothecary Diaries' page. Macrons are
    /// the only cheap, exact tell; a romanisation written without them
    /// ("Kusuriya no Hitorigoto") still passes as English. Nothing here
    /// guesses at word shapes.
    nonisolated static func displayTitle(for sibling: WikidataIdentity) -> String? {
        if let english = sibling.englishTitle, !isRomanisation(english) { return english }
        return sibling.nativeTitle ?? sibling.englishTitle
    }

    /// Hepburn long-vowel macrons, upper and lower case.
    nonisolated static func isRomanisation(_ title: String) -> Bool {
        title.unicodeScalars.contains { scalar in
            switch scalar.value {
            // ā ī ū ē ō, Ā Ī Ū Ē Ō
            case 0x101, 0x12B, 0x16B, 0x113, 0x14D, 0x100, 0x12A, 0x16A, 0x112, 0x14C: true
            default: false
            }
        }
    }

    private static func formatLabel(for format: WikidataFormat) -> String? {
        switch format {
        case .manga: "Manga"
        case .lightNovel: "Light novel"
        case .novel: "Novel"
        // Manhwa and webcomic collapse into `.webtoon` upstream (see
        // `WikidataFormat`'s doc comment); the row says the word a reader
        // recognises rather than the bucket's own case name.
        case .webtoon: "Webtoon"
        case .other: nil
        }
    }
}
