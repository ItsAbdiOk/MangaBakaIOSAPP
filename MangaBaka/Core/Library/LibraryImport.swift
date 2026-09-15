import Foundation

/// What one parsed row of an import file says about one series.
///
/// A staging shape, not `LibraryEntry`: an imported row may not resolve to a
/// MangaBaka series at all (see `malId`), and unlike `LibraryEntry` there is
/// no reason to distinguish "not set" from "explicitly cleared" here — an
/// import file that says nothing about a note means "leave it", never "erase
/// it", so a plain `String?` is enough.
struct ImportedEntry: Sendable, Equatable {
    /// The MangaBaka series id, when the row names one directly (our own
    /// JSON/CSV) or a MAL id could be resolved to one (it currently cannot —
    /// see `LibraryImport.parseMALXML`). Nil means `apply` cannot act on this
    /// row at all.
    var seriesId: Int?
    /// Present only for a MyAnimeList row, so a caller can say which series
    /// it named even when `seriesId` is nil.
    var malId: Int?
    var title: String?
    var state: LibraryEntry.State
    var progressChapter: Double?
    var progressVolume: Double?
    var rating: Double?
    var note: String?
    var isPrivate: Bool?
    /// The state string exactly as the file spelled it, when `state` had to
    /// coerce it to `.considering` because this build has no case for it.
    ///
    /// Work-list 90: the export half already writes the server's own
    /// spelling (`LibraryExport.Entry.rawState`, and the CSV `state` column
    /// is `LibraryEntry.exportedState`). Without this the import half threw
    /// it away again, so a backup taken on an older build and restored still
    /// rewrote every such entry to `considering` — the round trip was lossy
    /// in exactly the case the raw value was added for.
    ///
    /// Last, and defaulted, so the memberwise initialiser every call site
    /// here and in the tests uses keeps its existing argument list.
    var rawState: String?

    /// What to send for this row's state: the file's own spelling when it
    /// had one this build could not name, and the enum's otherwise.
    var stateValue: String { rawState ?? state.rawValue }
}

enum ImportError: Error, Equatable {
    /// The bytes are not any of the three shapes this reads: our JSON, our
    /// CSV (no `seriesId`/`state` header), or MyAnimeList XML.
    case invalidFormat
    /// Recognisably one of the three shapes, but it named zero entries.
    case empty
}

/// Reads a library export back in — our own JSON and CSV, and, best-effort,
/// a MyAnimeList export.
///
/// `apply` can only restore what `LibraryChange` can send in a PATCH: state,
/// progress, rating, note, privacy. `startDate`, `finishDate` and
/// `numberOfRereads` round-trip through `LibraryExport`'s JSON/CSV for a
/// faithful backup, but `LibraryProviding` has no way to write them back to
/// MangaBaka, so an import cannot restore them either. **Unsure**: whether
/// MangaBaka's write API can set those fields at all was not checked here —
/// if it can, `LibraryChange` would need new fields before this could use
/// them.
enum LibraryImport {
    /// One request per entry, so a large import stays comfortably under
    /// MangaBaka's general 180-requests-per-minute limit even for another
    /// person on the same rate-limited connection. **A guess**: 500ms is not
    /// measured against a real account, only chosen to land at 120/min —
    /// two-thirds of the documented ceiling — with margin to spare.
    static let requestSpacing: Duration = .milliseconds(500)

    static func parse(_ data: Data) -> Result<[ImportedEntry], ImportError> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.invalidFormat) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            return parseMALXML(data)
        }
        if trimmed.hasPrefix("{") {
            return parseOwnJSON(data)
        }
        return parseCSV(text)
    }

    // MARK: - Our own JSON

    private static func parseOwnJSON(_ data: Data) -> Result<[ImportedEntry], ImportError> {
        guard let envelope = try? LibraryExport.dateDecoder.decode(LibraryExport.Envelope.self, from: data)
        else { return .failure(.invalidFormat) }
        let entries = envelope.entries.map { entry in
            ImportedEntry(
                seriesId: entry.seriesId,
                malId: nil,
                title: entry.title,
                state: entry.state,
                progressChapter: entry.progressChapter,
                progressVolume: entry.progressVolume,
                rating: entry.rating,
                note: entry.note,
                isPrivate: entry.isPrivate,
                rawState: entry.rawState
            )
        }
        guard !entries.isEmpty else { return .failure(.empty) }
        return .success(entries)
    }

    // MARK: - Our own CSV

    /// Header-matched: columns can arrive in any order, and every column but
    /// `seriesId` and `state` is optional — a CSV re-exported from a
    /// spreadsheet the reader trimmed down still parses.
    private static func parseCSV(_ text: String) -> Result<[ImportedEntry], ImportError> {
        let rows = csvRows(text)
        guard let header = rows.first, !header.isEmpty else { return .failure(.invalidFormat) }
        var columns: [String: Int] = [:]
        for (index, name) in header.enumerated() { columns[name] = index }
        guard let seriesIndex = columns["seriesId"], let stateIndex = columns["state"]
        else { return .failure(.invalidFormat) }

        func field(_ row: [String], _ name: String) -> String? {
            guard let index = columns[name], index < row.count, !row[index].isEmpty else { return nil }
            return row[index]
        }

        var entries: [ImportedEntry] = []
        for row in rows.dropFirst() {
            guard row.count > seriesIndex, row.count > stateIndex else { continue }
            guard let seriesId = Int(row[seriesIndex]) else { continue }
            // Work-list 90: an unrecognised state used to drop the whole row,
            // which is worse than the decoder's behaviour on the same value —
            // a CSV exported by a newer build lost every entry in a state
            // added since. Coerced the same way `LibraryEntry.State`'s own
            // decoder coerces it, keeping the spelling to write back.
            let rawStateText = row[stateIndex]
            let state = LibraryEntry.State(rawValue: rawStateText) ?? .considering
            entries.append(ImportedEntry(
                seriesId: seriesId,
                malId: nil,
                title: rearmed(field(row, "title")),
                state: state,
                progressChapter: field(row, "progressChapter").flatMap(Double.init),
                progressVolume: field(row, "progressVolume").flatMap(Double.init),
                rating: field(row, "rating").flatMap(Double.init),
                note: rearmed(field(row, "note")),
                isPrivate: field(row, "isPrivate").map { $0 == "true" },
                rawState: state.rawValue == rawStateText ? nil : rawStateText
            ))
        }
        guard !entries.isEmpty else { return .failure(.empty) }
        return .success(entries)
    }

    /// Undoes `LibraryExport.defused`.
    ///
    /// Work-list 28: the export prefixes a title or note beginning `=`, `+`,
    /// `-` or `@` with an apostrophe so a spreadsheet does not run it as a
    /// formula, and nothing here ever took it off. `defused`'s own comment
    /// said the importer "sees it only in a field that could not have been a
    /// number anyway", which is true and is not the point — `apply` sends the
    /// note back to the server, so exporting and re-importing spent a real
    /// PATCH writing `'=hello` into the reader's account, and doing it twice
    /// wrote `''=hello`.
    ///
    /// Exactly one apostrophe, and only when the next character is one of the
    /// four `defused` acts on: a note the reader really did begin with an
    /// apostrophe is their text and is left alone.
    private static func rearmed(_ field: String?) -> String? {
        guard let field, field.first == "'" else { return field }
        let rest = field.dropFirst()
        guard let next = rest.first, "=+-@".contains(next) else { return field }
        return String(rest)
    }

    /// A small RFC 4180 state machine, not a line-splitter — a quoted field
    /// can legitimately contain the newline that a `components(separatedBy:)`
    /// approach would mistake for a row break, which is exactly the case
    /// `LibraryExport.csv` produces for a note like "Great,\nread again".
    private static func csvRows(_ text: String) -> [[String]] {
        var state = CSVParseState()
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if state.inQuotes {
                index = state.consumeQuoted(chars, at: index)
            } else {
                state.consumeUnquoted(chars[index])
            }
            index += 1
        }
        state.finish()
        return state.rows
    }

    /// The state a CSV scan carries between characters, pulled out of
    /// `csvRows` itself so that function reads as the two things it does —
    /// walk the characters, dispatch on whether a quote is open — rather
    /// than the whole state machine in one body.
    private struct CSVParseState {
        var rows: [[String]] = []
        private var row: [String] = []
        private var field = ""
        private(set) var inQuotes = false
        private var sawAnyField = false

        /// Handles one character while inside a quoted field. Returns the
        /// index to resume from — advanced by one extra when a doubled quote
        /// consumed its escape partner.
        mutating func consumeQuoted(_ chars: [Character], at index: Int) -> Int {
            guard chars[index] == "\"" else {
                field.append(chars[index])
                return index
            }
            if index + 1 < chars.count, chars[index + 1] == "\"" {
                field.append("\"")
                return index + 1
            }
            inQuotes = false
            return index
        }

        mutating func consumeUnquoted(_ character: Character) {
            switch character {
            case "\"":
                inQuotes = true
                sawAnyField = true
            case ",":
                endField()
                sawAnyField = true
            case "\r":
                break
            // Swift folds CRLF into ONE grapheme cluster, so "\r\n" is a single
            // Character here and matches neither "\r" nor "\n" alone — the
            // export writes CRLF (RFC 4180) and every row ran together.
            case "\n", "\r\n":
                endField()
                rows.append(row)
                row = []
                sawAnyField = false
            default:
                field.append(character)
                sawAnyField = true
            }
        }

        mutating func finish() {
            if sawAnyField || !field.isEmpty {
                endField()
            }
            if !row.isEmpty {
                rows.append(row)
            }
        }

        private mutating func endField() {
            row.append(field)
            field = ""
        }
    }

    // MARK: - MyAnimeList XML (best-effort)

    /// MangaBaka's `Series.source` dictionary has no MyAnimeList entry to key
    /// a lookup off (verified by grep across the model and every fixture in
    /// this repo, 2026-09-13; only `manga_updates` is populated), and no
    /// endpoint here was found that searches by a foreign tracker's id. So a
    /// MAL row parses — the reader's status, chapters and score are all
    /// read — but `seriesId` stays nil and `apply`/the UI report it as
    /// needing a match this app cannot make yet, rather than silently
    /// dropping it or guessing.
    private static func parseMALXML(_ data: Data) -> Result<[ImportedEntry], ImportError> {
        let delegate = MALXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return .failure(.invalidFormat) }
        guard !delegate.entries.isEmpty else { return .failure(.empty) }
        return .success(delegate.entries)
    }

    private final class MALXMLDelegate: NSObject, XMLParserDelegate {
        var entries: [ImportedEntry] = []
        private var currentText = ""
        private var malId: Int?
        private var status: String?
        private var chapters: Double?
        private var score: Double?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            currentText = ""
            if elementName == "manga" {
                malId = nil
                status = nil
                chapters = nil
                score = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "manga_mangadb_id":
                malId = Int(text)
            case "my_status":
                status = text
            case "my_read_chapters":
                chapters = Double(text)
            case "my_score":
                score = Double(text)
            case "manga":
                if let malId {
                    // MAL scores 0-10; MangaBaka's rating is 0-100 throughout
                    // (see `LibraryEntry.rating`). `if let`, not `score!` —
                    // this reads a file the reader picked off their phone,
                    // which CLAUDE.md's no-force-unwrap rule treats as real
                    // input regardless of the `> 0` guard just above it.
                    var mappedRating: Double?
                    if let score, score > 0 { mappedRating = score * 10 }

                    entries.append(ImportedEntry(
                        seriesId: nil,
                        malId: malId,
                        title: nil,
                        state: Self.mappedState(status),
                        progressChapter: (chapters ?? 0) > 0 ? chapters : nil,
                        progressVolume: nil,
                        rating: mappedRating,
                        note: nil,
                        isPrivate: nil
                    ))
                }
            default:
                break
            }
            currentText = ""
        }

        /// MAL's own status strings, mapped onto the nearest MangaBaka state.
        /// "On-Hold" -> `.paused` and everything unrecognised -> `.planToRead`
        /// are the two calls made without a documented mapping — **a guess**.
        private static func mappedState(_ status: String?) -> LibraryEntry.State {
            switch status?.lowercased() {
            case "reading": .reading
            case "completed": .completed
            case "on-hold", "on hold": .paused
            case "dropped": .dropped
            case "plan to read": .planToRead
            default: .planToRead
            }
        }
    }
}

// MARK: - Applying an import

/// What one call to `LibraryImport.apply` did.
struct ImportReport: Sendable, Equatable {
    var added = 0
    var updated = 0
    /// Includes both "nothing in the row actually differed" and "the row's
    /// progress was behind what MangaBaka already has" — the never-downgrade
    /// rule below.
    var skipped = 0
    var failures = 0
    /// Rows `apply` could not act on at all — today, always a MyAnimeList row
    /// with no MangaBaka id. See `LibraryImport.parseMALXML`.
    var unresolved = 0
    /// R21/P21: the index into the entries this run was given, of the first
    /// row not attempted because a real server rate limit was hit — nil when
    /// every row was attempted. Before this, hitting the 180/min window
    /// partway through a 939-row restore made every remaining row count as a
    /// `failures`, one per second, with nothing marking where a retry should
    /// pick back up. A caller can slice `entries` from this index and call
    /// `apply` again once the window has cleared.
    var stoppedAt: Int?
}

/// Progress for one `LibraryImport.apply` run, observed by the import sheet.
///
/// `@MainActor` because it drives SwiftUI state directly, the same shape as
/// `RetryGate` (`FailureState.swift`) — a plain `@Observable` object rather
/// than view `@State`, so it can be driven and asserted on from a test with
/// no view on screen at all.
@MainActor
@Observable
final class LibraryImportProgress {
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var isCancelled = false

    func begin(total: Int) {
        self.total = total
        completed = 0
        isCancelled = false
    }

    func advance() {
        completed += 1
    }

    /// Checked once per entry inside `apply`; does not interrupt a request
    /// already in flight, only the ones queued after it.
    func cancel() {
        isCancelled = true
    }
}

extension LibraryImport {
    /// Applies parsed rows to the reader's real library, one request per row.
    ///
    /// Never downgrades progress: a row whose chapter is behind what
    /// `existing` already has for that series is skipped rather than sent —
    /// an old export re-imported, or a MAL list that has not been touched in
    /// months, must not walk a reader's progress backwards. A row identical
    /// to what is already there (no field actually differs) is also counted
    /// as skipped rather than spent as a write.
    ///
    /// `@MainActor` so it can call `progress`'s methods directly without
    /// hopping actors per entry; `library.add`/`.update` remain awaited calls
    /// into whatever actor backs them.
    @MainActor
    static func apply(
        _ entries: [ImportedEntry],
        to library: any LibraryProviding,
        existing: [LibraryEntry],
        progress: LibraryImportProgress? = nil
    ) async -> ImportReport {
        var report = ImportReport()
        // `uniquingKeysWith`, not `uniqueKeysWithValues` (work-list 17): the
        // latter traps on a repeated key, and `existing` is whatever the
        // library walk produced. The walk dedupes now, but a trap inside an
        // import is the worst place to rely on a caller's invariant, and
        // first-wins matches the walk's own rule.
        let existingBySeries = Dictionary(
            existing.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        progress?.begin(total: entries.count)

        entryLoop: for (index, entry) in entries.enumerated() {
            if progress?.isCancelled == true { break }

            defer { progress?.advance() }

            guard let seriesId = entry.seriesId else {
                report.unresolved += 1
                continue
            }

            let current = existingBySeries[seriesId]
            if let current, let currentChapter = current.progressChapter,
               let importedChapter = entry.progressChapter, importedChapter < currentChapter {
                report.skipped += 1
                continue
            }

            let change = changeSet(for: entry, comparedTo: current)
            let outcome = await sendOne(
                seriesId: seriesId, entry: entry, isNew: current == nil, change: change, to: library
            )
            switch outcome {
            case .added: report.added += 1
            case .updated: report.updated += 1
            case .skipped: report.skipped += 1
            case .failed: report.failures += 1
            case .rateLimited:
                // A real 429 means the window is full — every remaining row
                // would earn the same refusal, one per `requestSpacing`, and
                // used to be recorded as `failures` that way for up to 939
                // rows with nothing marking where to pick back up. Stop here
                // instead, and say where, so a caller can retry `entries`
                // from `stoppedAt` once the window clears.
                report.stoppedAt = index
                break entryLoop
            }

            // No point spacing the request that just went out from one that
            // will never be sent.
            if index < entries.count - 1 {
                try? await Task.sleep(for: requestSpacing)
            }
        }

        return report
    }

    /// What sending one row did. Factored out of `apply` to keep its
    /// cyclomatic complexity under SwiftLint's cap — the branching below is
    /// the whole point of the function, not something to compress further.
    private enum SendOutcome {
        case added, updated, skipped, failed, rateLimited
    }

    private static func sendOne(
        seriesId: Int, entry: ImportedEntry, isNew: Bool, change: LibraryChange,
        to library: any LibraryProviding
    ) async -> SendOutcome {
        do {
            if isNew {
                try await library.add(
                    seriesId: seriesId, state: entry.state, rawState: entry.rawState
                )
                // R21/P21: `add` and `update` are two real requests for one
                // new row, and the loop used to space only *between*
                // entries — so a new row spent two requests back to back
                // with no gap, at up to double `requestSpacing`'s intended
                // rate (~240/min against MangaBaka's 180/min general limit,
                // not the 120/min the comment above claims). Spaced here
                // too, only when a second request is actually about to be
                // sent.
                if !change.isEmpty { try? await Task.sleep(for: requestSpacing) }
            }
            if !change.isEmpty {
                try await library.update(seriesId: seriesId, change: change)
            }
            if isNew { return .added }
            return change.isEmpty ? .skipped : .updated
        } catch {
            if case .rateLimited = error { return .rateLimited }
            return .failed
        }
    }

    /// The write `apply` sends for one row, on top of whatever `add` already
    /// did for a brand-new entry.
    ///
    /// `comparedTo` is nil for a new entry: `add` already set `state` via the
    /// POST, so nothing here repeats it, and every other field the row
    /// carries is included outright — there is nothing on the server yet to
    /// compare against. For an existing entry, every field is only included
    /// when it actually differs from what is already there, the same rule
    /// `LibraryEditSheet.changes` applies to a reader's own edit — otherwise
    /// re-importing an unchanged file would count every row as "updated" and
    /// spend a write PATCHing each one back to the value it already held,
    /// defeating the point of `report.skipped` naming a no-op.
    private static func changeSet(
        for entry: ImportedEntry, comparedTo current: LibraryEntry?
    ) -> LibraryChange {
        var change = LibraryChange()
        // Work-list 90: compared on the raw spellings, not the enums. Two
        // different states this build cannot name both coerce to
        // `.considering`, so an enum comparison called them equal and quietly
        // declined to restore the file's real value.
        if let current, entry.stateValue != current.exportedState {
            change.state = entry.state
            change.rawState = entry.rawState
        }
        if let chapter = entry.progressChapter, chapter != current?.progressChapter {
            change.progressChapter = .some(chapter)
        }
        if let volume = entry.progressVolume, volume != current?.progressVolume {
            change.progressVolume = .some(volume)
        }
        if let rating = entry.rating, rating != current?.rating {
            change.rating = .some(rating)
        }
        if let note = entry.note, note != current?.note {
            change.note = .some(note)
        }
        if let isPrivate = entry.isPrivate, isPrivate != current?.isPrivate {
            change.isPrivate = isPrivate
        }
        return change
    }
}
