import Foundation

extension NDLClient {
    /// Turns NDL's answer into rows for one series, and throws the rest away.
    ///
    /// This has to be here because **`title=` is a keyword match, not a phrase
    /// match**, so NDL's answer is a superset that contains other people's
    /// books. Measured 2026-09-14, `title="薬屋のひとりごと" AND mediatype=books`
    /// returned 84 records whose first eight were:
    ///
    /// ```
    /// 薬屋のひとりごと：オリジナル・サウンドトラック  genre —      imprint —                  東宝
    /// 薬屋のひとりごと外伝小蘭回想録. 1              genre 漫画   imprint ビッグガンガンコミックス  スクウェア・エニックス
    /// 薬屋のひとりごと画集                          genre —      imprint —                  イマジカインフォス
    /// 薬屋のひとりごと                              genre —      imprint ヒーロー文庫          主婦の友社
    /// 「薬屋のひとりごと」猫猫の観察眼、後宮の謎      genre —      imprint EIWA MOOK          英和出版社
    /// 薬屋のひとりごと：猫猫の後宮謎解き手帳. 1-3     genre 漫画   imprint サンデーGXコミックス    小学館
    /// ```
    ///
    /// A soundtrack, an art book, a mook, **the light novel**, and the manga —
    /// all under one title search, all `mediatype=books`. The research pass
    /// found the same shape on `ダンジョン飯`, where the top hits were an
    /// unrelated light novel and a recipe book.
    ///
    /// ## How format is decided here
    ///
    /// `dcndl:genre` is the authority, and on this measurement it does the job
    /// Open Library's `form:` tags could not: **every manga volume carries
    /// `漫画` and the light novel carries none.** That is a cataloguer's field,
    /// not a crowd's tag.
    ///
    /// The complication is that the genre is filled in late. The most valuable
    /// record in the whole family — the forthcoming Solo Leveling volume dated
    /// 2026-09-18 — has **no genre at all**, while the published volumes of the
    /// same series do. Requiring `漫画` would drop exactly the row this client
    /// exists for; allowing a blank genre through would admit the soundtrack.
    ///
    /// So a blank genre is admitted only on **imprint corroboration**: the
    /// record's `dcndl:seriesTitle` must be an imprint that some *other* record
    /// in the same answer carries alongside an explicit `漫画`. Checked against
    /// both measured responses:
    ///
    /// - Solo Leveling: the 漫画 volumes are `MFC`; the forthcoming record is
    ///   also `MFC` → admitted, which is the result we need.
    /// - Apothecary: the 漫画 volumes are `サンデーGXコミックス` and
    ///   `ビッグガンガンコミックス`; the light novel is `ヒーロー文庫` → rejected.
    ///   The soundtrack and the art book carry no imprint at all → rejected.
    ///
    /// **Its failure mode, stated rather than hidden:** an imprint that
    /// publishes both manga and prose would let a prose volume in. None of the
    /// imprints measured does, and the row would still be labelled
    /// `.imprintCorroborated` rather than `.catalogueGenre`, so a caller that
    /// wants only cataloguer-confirmed comics can filter on the evidence.
    struct Query {
        let title: String
        let format: BookEdition.Format

        /// NDL's genre vocabulary term for comics. `漫画` is the value behind
        /// `http://id.ndl.go.jp/auth/ndlgft/001347325`, seen on every manga
        /// record in both measured responses.
        static let comicGenre = "漫画"

        func rows(from records: [NDLRecordParser.Record]) -> [BookEdition] {
            let candidates = Self.deduplicated(records).filter(titleMatches)
            let comicImprints = Set(
                candidates
                    .filter { $0.genre == Self.comicGenre }
                    .compactMap(\.seriesTitle)
            )
            let works = workTitles(for: candidates)
            return zip(candidates, works).compactMap { record, work in
                guard let evidence = evidence(for: record, comicImprints: comicImprints) else {
                    return nil
                }
                return row(record, evidence: evidence, workTitle: work)
            }
            .sorted(by: Self.byVolumeThenDate)
        }

        /// NDL sends each catalogue item twice — two sibling `BibResource`
        /// elements with the same `rdf:about`, one per contributing source
        /// (measured 2026-09-14: `R100000002` and `R100000001` for the same
        /// book). The second was empty in every record sampled and the parser
        /// already drops empty ones, but merging on the URI means a response
        /// where the second copy *is* filled in produces one row, not two.
        static func deduplicated(_ records: [NDLRecordParser.Record]) -> [NDLRecordParser.Record] {
            var seen = Set<String>()
            return records.filter { record in
                // A record with no URI cannot be proven a duplicate, so it is
                // kept rather than guessed at.
                guard let uri = record.uri else { return true }
                return seen.insert(uri).inserted
            }
        }

        /// The record's title must *begin* with the series title, not merely
        /// contain it.
        ///
        /// Prefix, because a Japanese volume appends its number and subtitle
        /// (`俺だけレベルアップな件. 10`, `薬屋のひとりごと : 猫猫の後宮謎解き手帳. 1`)
        /// and never prepends. Contains-matching is what let the research pass'
        /// `ダンジョン飯` query return
        /// `引退したSランク冒険者は辺境でダンジョン飯を作ることにした` — a different
        /// series that merely mentions this one.
        func titleMatches(_ record: NDLRecordParser.Record) -> Bool {
            guard let recorded = record.title else { return false }
            return Self.normalise(recorded).hasPrefix(Self.normalise(title))
        }

        /// - Returns: nil when the record is not this format and must be
        ///   dropped.
        private func evidence(
            for record: NDLRecordParser.Record, comicImprints: Set<String>
        ) -> BookEdition.FormatEvidence? {
            // No format asked for: no format filtering, and no format claimed
            // either. The caller gets everything the title matched, labelled
            // honestly — including, on the measured query, a soundtrack.
            guard format == .comic else {
                if let genre = record.genre { return .catalogueGenre(genre) }
                return .unstated
            }
            if let genre = record.genre {
                return genre == Self.comicGenre ? .catalogueGenre(genre) : nil
            }
            guard let imprint = record.seriesTitle, comicImprints.contains(imprint) else {
                return nil
            }
            return .imprintCorroborated(imprint: imprint)
        }

        /// - Parameter workTitle: from `workTitles(for:)` — nil for the work
        ///   that was asked for, the side story's own name otherwise.
        private func row(
            _ record: NDLRecordParser.Record, evidence: BookEdition.FormatEvidence, workTitle: String?
        ) -> BookEdition {
            let format: BookEdition.Format = {
                switch evidence {
                case .catalogueGenre(Self.comicGenre), .imprintCorroborated: .comic
                // A stated genre this app has no mapping for is not a guess
                // worth making. `.unknown` with the genre still attached lets
                // a later reader see what NDL actually said.
                case .catalogueGenre, .unstated, .anchorISBN: .unknown
                }
            }()
            return BookEdition(
                id: record.uri ?? record.isbn ?? record.title ?? UUID().uuidString,
                title: record.title ?? "",
                isbn13: record.isbn.flatMap { $0.count == 13 ? $0 : nil },
                publisher: record.publisher,
                // `dcterms:language`, the language of *this printing* — never
                // `dcndl:originalLanguage`, which said `kor` on the Japanese
                // Solo Leveling volumes and would have filed them as Korean.
                language: record.language,
                published: PartialDate.parse(record.issued),
                // NDL publishes no cover images. Nil, rather than a URL built
                // out of an ISBN that may 404.
                coverID: nil,
                volume: record.volume,
                source: .nationalDietLibrary,
                format: format,
                formatEvidence: evidence,
                edition: record.edition,
                workTitle: workTitle
            )
        }

        /// Volume order where NDL broke the number out, date order otherwise.
        /// A forthcoming volume therefore sorts last, which is where a reader
        /// looking for "what's next" expects to find it.
        private static func byVolumeThenDate(_ lhs: BookEdition, _ rhs: BookEdition) -> Bool {
            // `BookEditionShelf.number(from:)`, not `Int.init`: it folds the
            // full-width `１３` NDL writes on some records (measured 2026-09-15).
            if let left = lhs.volume.flatMap(BookEditionShelf.number(from:)),
               let right = rhs.volume.flatMap(BookEditionShelf.number(from:)),
               left != right {
                return left < right
            }
            switch (lhs.published, rhs.published) {
            case let (left?, right?): return left < right
            // An undated row sorts after a dated one: it cannot be placed, and
            // burying it at the end is better than asserting it came first.
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.title < rhs.title
            }
        }

        /// Full-width Latin and the ideographic space folded to half-width,
        /// then all whitespace removed and the result lower-cased.
        ///
        /// Measured 2026-09-14: the forthcoming Solo Leveling record is
        /// `俺だけレベルアップな件外伝　01` with U+3000 IDEOGRAPHIC SPACE, while its
        /// published siblings are `俺だけレベルアップな件. 10` with an ASCII one.
        /// A comparison that respects either would have matched one and missed
        /// the other.
        static func normalise(_ text: String) -> String {
            let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
            return folded.filter { !$0.isWhitespace }.lowercased()
        }
    }
}
