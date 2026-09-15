import Foundation

/// Parses one NDL SRU response into records. The only place in the app that
/// reads `dcndl` XML.
///
/// `XMLParser`, not a dependency: the app already parses two RSS feeds this
/// way (`MagazineFeedParser`, `WebtoonsFeedParser`) and a third-party XML
/// library for one endpoint would be a new supply-chain entry to justify at
/// review for no capability we lack.
///
/// ## The shape, measured 2026-09-14
///
/// `dcndl` nests almost everything one level deeper than it looks. A record's
/// title, volume, series and genre are each an `rdf:Description` wrapper with
/// an `rdf:value` *and* a `dcndl:transcription` (the kana reading) inside it,
/// and publisher and creator both wrap a `foaf:Agent/foaf:name`:
///
/// ```xml
/// <dcndl:genre>
///   <rdf:Description rdf:about="http://id.ndl.go.jp/auth/ndlgft/001347325">
///     <rdf:value>漫画</rdf:value>
///     <dcndl:transcription>マンガ</dcndl:transcription>
/// <dcterms:publisher><foaf:Agent><foaf:name>ＫＡＤＯＫＡＷＡ</foaf:name>
/// ```
///
/// So a flat "last element name wins" reader — which is all either RSS parser
/// needs — would file the publisher's name under the creator's and read the
/// kana transcription as the genre. This delegate therefore keeps a stack of
/// the enclosing container element and attributes `rdf:value` / `foaf:name` to
/// it.
///
/// - Note: `recordPacking=xml` is required on the request. Without it NDL
///   returns `recordData` as an escaped string and every parse here finds zero
///   records — recorded in `docs/sources/bibliographic.md` as having cost a
///   research run.
enum NDLRecordParser {
    /// One catalogue record, still in NDL's own vocabulary. Turned into a
    /// `BookEdition` by `NDLClient`, which is where the matching rules live —
    /// this type states what the library said and judges none of it.
    struct Record: Equatable, Sendable {
        /// `rdf:about` on the `BibResource`, e.g.
        /// `https://ndlsearch.ndl.go.jp/books/R100000137-I9784046604873#material`.
        var uri: String?
        /// `dcterms:title`, the full form as catalogued —
        /// `俺だけレベルアップな件. 10`, volume number included.
        var title: String?
        /// `dcndl:volume`'s own value: `10`. NDL is the only source in the
        /// bibliographic family besides DNB that breaks this out of the title.
        var volume: String?
        /// `dcndl:seriesTitle` — the imprint, `MFC`, not the work's name.
        /// Light-novel records carry a bunko imprint here (`ヒーロー文庫`),
        /// which is the second format signal after `dcndl:genre`.
        var seriesTitle: String?
        var publisher: String?
        var issued: String?
        /// `dcndl:genre`'s value, e.g. `漫画`. Present on many records and
        /// absent on others — measured present on two of three rows of the
        /// Solo Leveling response, absent on the forthcoming one.
        var genre: String?
        /// `dcterms:language`, ISO 639-2: `jpn` on every record measured.
        /// This is the language of *this printing*.
        var language: String?
        /// `dcndl:originalLanguage`, ISO 639-2: `kor` on the Solo Leveling
        /// records. **Not the language of this edition** — it says what the
        /// work was translated from, and confusing the two would file a
        /// Japanese book as Korean.
        var originalLanguage: String?
        var isbn: String?
        /// `dcndl:edition` — the printing's own note, `特装版小冊子付き`
        /// ("special edition, booklet included"). Nil on the plain printing.
        ///
        /// Measured 2026-09-15 on the 50-record 薬屋のひとりごと page: volume 13
        /// arrives twice with the same title, imprint and publisher and two
        /// ISBNs — 978-4-7575-9028-1 carries this note and 978-4-7575-9027-4
        /// does not. Without this field the two are indistinguishable and a
        /// shelf counts one volume as two.
        var edition: String?

        var isEmpty: Bool { title == nil && isbn == nil }
    }

    /// One SRU page: its records, and how many NDL holds in all.
    struct Response: Equatable, Sendable {
        let records: [Record]
        /// `<numberOfRecords>` off the SRU envelope — how many NDL holds, as
        /// opposed to how many this page returned. Nil when the envelope did
        /// not say.
        let totalRecords: Int?
    }

    /// The page in one pass. Nil when the document is not XML at all.
    static func parseResponse(_ data: Data) -> Response? {
        let delegate = NDLRecordDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return Response(records: delegate.records, totalRecords: delegate.totalRecords)
    }

    /// - Returns: the records, or nil when the document is not XML at all.
    ///   An empty array is a real answer — NDL searched and matched nothing.
    static func parse(_ data: Data) -> [Record]? {
        parseResponse(data)?.records
    }
}

private final class NDLRecordDelegate: NSObject, XMLParserDelegate {
    var records: [NDLRecordParser.Record] = []
    var totalRecords: Int?

    private var text = ""
    private var current = NDLRecordParser.Record()
    private var insideResource = false
    /// The enclosing `dcndl`/`dcterms` element an `rdf:value` or `foaf:name`
    /// belongs to. A stack rather than a single value because these wrappers
    /// nest — see the type's doc comment for the record shape that forces it.
    private var containers: [String] = []

    /// Elements whose real content is an `rdf:value` or a `foaf:name` one or
    /// two levels down.
    ///
    /// Every wrapper this app reads (`nested`), plus the three it must
    /// recognise in order to *ignore* what is inside them — `dcterms:creator`
    /// wraps a `foaf:name` identical in shape to the publisher's, and
    /// `dcndl:partInformation` wraps a `dcterms:title` per track.
    private lazy var wrappers: Set<String> = Set(nested.keys)
        .union(["dcterms:creator", "dcterms:subject", "dcndl:partInformation"])

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        if wrappers.contains(name) { containers.append(name) }

        switch name {
        case "dcndl:BibResource":
            insideResource = true
            current = NDLRecordParser.Record(uri: attributes["rdf:about"])
        case "dcterms:identifier":
            // The datatype URI is what says which identifier this is: the
            // same element carries ISBN, JPNO and NDLBibID. Measured
            // 2026-09-14, one record's four identifiers were
            // 9784046604873 (ISBN), 23733021, 032308103, 34372823.
            identifierType = attributes["rdf:datatype"] ?? ""
        default:
            break
        }
    }

    private var identifierType = ""

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let decoded = String(bytes: CDATABlock, encoding: .utf8) else { return }
        text += decoded
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if containers.last == name { containers.removeLast() }
            text = ""
        }

        if name == "numberOfRecords" {
            totalRecords = Int(value)
            return
        }
        guard insideResource, !value.isEmpty else {
            if name == "dcndl:BibResource" { closeRecord() }
            return
        }

        switch name {
        case "rdf:value", "foaf:name":
            // Belongs to whichever wrapper encloses it, never to the element
            // that happens to have closed last.
            store(value, at: containers.last.flatMap { nested[$0] })
        case "dcterms:identifier":
            // Hyphenated on some records (`978-4-04-681635-1`) and not on
            // others (`9784046604873`) — measured in the same response, so
            // the hyphens come out here rather than at every call site.
            guard identifierType.hasSuffix("ISBN") else { return }
            store(value.filter { $0.isNumber || $0 == "X" }, at: \.isbn)
        case "dcndl:BibResource":
            closeRecord()
        default:
            store(value, at: flat[name])
        }
    }

    /// First value wins, and an unmapped element is dropped.
    ///
    /// First rather than last because NDL repeats fields: a record carries
    /// `dcterms:publisher` twice (ＫＡＤＯＫＡＷＡ, measured 2026-09-14) and its
    /// `dcndl:partInformation` children each carry their own `dcterms:title` —
    /// 78 of them on the soundtrack record, any of which would overwrite the
    /// book's real title under a last-wins rule.
    private func store(_ value: String, at field: WritableKeyPath<NDLRecordParser.Record, String?>?) {
        guard let field, current[keyPath: field] == nil else { return }
        current[keyPath: field] = value
    }

    /// Elements whose text is the value itself.
    ///
    /// `dcterms:title` is the flat form and carries the volume number as
    /// catalogued (`俺だけレベルアップな件. 10`), so it is preferred over
    /// `dc:title`'s nested `rdf:value`, which drops it
    /// (`俺だけレベルアップな件`) — both write `\.title`, and first-wins picks
    /// whichever the document put first, which is `dcterms:title`.
    /// `dcterms:creator` and `dcterms:subject` are deliberately absent from
    /// both tables: a reader is never shown them, and an unread field cannot
    /// be wrong.
    private let flat: [String: WritableKeyPath<NDLRecordParser.Record, String?>] = [
        "dcterms:title": \.title,
        "dcterms:issued": \.issued,
        "dcterms:language": \.language,
        "dcndl:originalLanguage": \.originalLanguage,
        "dcndl:edition": \.edition
    ]

    /// Wrappers, and the field their inner `rdf:value` or `foaf:name` fills.
    private let nested: [String: WritableKeyPath<NDLRecordParser.Record, String?>] = [
        "dcndl:volume": \.volume,
        "dcndl:seriesTitle": \.seriesTitle,
        "dcndl:genre": \.genre,
        "dcterms:publisher": \.publisher,
        "dc:title": \.title
    ]

    private func closeRecord() {
        insideResource = false
        containers.removeAll()
        guard !current.isEmpty else { return }
        records.append(current)
        current = NDLRecordParser.Record()
    }
}
