import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Turns the reader's library into a file they hold themselves.
///
/// A safety net, not a sync mechanism: MangaBaka is the only account this app
/// writes to, and this is the one way a reader gets their own copy of what is
/// in it — to keep, to move somewhere else, or to restore from if their
/// account is ever lost. Both functions are pure: the same entries always
/// produce the same bytes, which is what makes them testable without a
/// server, a clock, or a filesystem.
enum LibraryExport {
    static let formatName = "mangabaka-library"
    static let formatVersion = 1

    /// The versioned envelope written to JSON. `Codable` so `LibraryImport`
    /// can decode the same shape back out — see its doc comment.
    struct Envelope: Codable, Equatable {
        var format: String
        var version: Int
        var exportedAt: Date
        var entries: [Entry]
    }

    /// One exported entry: the series it names, and every field
    /// `LibraryEntry` carries about the reader's relationship to it.
    ///
    /// Carries more than `LibraryChange` can send back (`startDate`,
    /// `finishDate`, `numberOfRereads`) so the JSON/CSV files are a faithful
    /// backup of what MangaBaka holds, even though `LibraryImport.apply`
    /// can only restore the subset `LibraryChange` supports — see that
    /// file's doc comment.
    struct Entry: Codable, Equatable {
        var seriesId: Int
        var title: String?
        var state: LibraryEntry.State
        /// The server's own spelling of `state`, when it is one this build
        /// does not know. Work-list 90: `state` coerces an unrecognised value
        /// to `considering`, so without this a backup taken on an older build
        /// silently rewrote every entry in a state added since. Absent — and
        /// omitted from the file — whenever it agrees with `state`.
        var rawState: String?
        var progressChapter: Double?
        var progressVolume: Double?
        var rating: Double?
        var note: String?
        var startDate: Date?
        var finishDate: Date?
        var numberOfRereads: Int?
        var priority: Int?
        var isPrivate: Bool?

        init(_ entry: LibraryEntry) {
            seriesId = entry.seriesId
            title = entry.series?.displayTitle
            state = entry.state
            rawState = entry.exportedState == entry.state.rawValue ? nil : entry.exportedState
            progressChapter = entry.progressChapter
            progressVolume = entry.progressVolume
            rating = entry.rating
            note = entry.note
            startDate = entry.startDate
            finishDate = entry.finishDate
            numberOfRereads = entry.numberOfRereads
            priority = entry.priority
            isPrivate = entry.isPrivate
        }

        init(
            seriesId: Int, title: String?, state: LibraryEntry.State,
            progressChapter: Double?, progressVolume: Double?, rating: Double?,
            note: String?, startDate: Date?, finishDate: Date?,
            numberOfRereads: Int?, priority: Int?, isPrivate: Bool?,
            rawState: String? = nil
        ) {
            self.seriesId = seriesId
            self.title = title
            self.state = state
            self.progressChapter = progressChapter
            self.progressVolume = progressVolume
            self.rating = rating
            self.note = note
            self.startDate = startDate
            self.finishDate = finishDate
            self.numberOfRereads = numberOfRereads
            self.priority = priority
            self.isPrivate = isPrivate
            self.rawState = rawState
        }
    }

    static let dateEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Alphabetical rather than declaration order, but the same order
        // every time — a stable key order is the property that matters for a
        // file meant to be diffed or re-imported, not the alphabet itself.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let dateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `exportedAt` is a parameter, not `Date()` inlined, so a test can pin it
    /// and check the exact bytes rather than only "it parsed back the same".
    static func json(_ entries: [LibraryEntry], exportedAt: Date = Date()) -> Data {
        let envelope = Envelope(
            format: formatName,
            version: formatVersion,
            exportedAt: exportedAt,
            entries: entries.map(Entry.init)
        )
        // Encoding this app's own types into JSON does not fail in practice —
        // there is no such thing as a `Date` or `String` this encoder cannot
        // represent — so an empty file on the one path that could theoretically
        // throw is preferable to `try!` crashing a reader's export.
        return (try? dateEncoder.encode(envelope)) ?? Data()
    }

    private static let csvHeader = [
        "seriesId", "title", "state", "progressChapter", "progressVolume",
        "rating", "note", "startDate", "finishDate", "numberOfRereads",
        "priority", "isPrivate"
    ]

    /// `Date.ISO8601FormatStyle` is a value type, so it is Sendable where
    /// `ISO8601DateFormatter` (a class) is not.
    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static func iso(_ date: Date) -> String { date.formatted(isoStyle) }

    /// RFC 4180: CRLF line endings, a quoted field wherever a comma, quote or
    /// newline appears in it, and doubled quotes inside a quoted field.
    static func csv(_ entries: [LibraryEntry]) -> Data {
        var lines = [csvHeader.map(quoteIfNeeded).joined(separator: ",")]
        for entry in entries {
            lines.append(row(for: entry).map(quoteIfNeeded).joined(separator: ","))
        }
        // RFC 4180 rows end in CRLF, including the last one.
        let text = lines.map { $0 + "\r\n" }.joined()
        return Data(text.utf8)
    }

    private static func row(for entry: LibraryEntry) -> [String] {
        [
            String(entry.seriesId),
            defused(entry.series?.displayTitle ?? ""),
            entry.exportedState,
            entry.progressChapter.map(numberText) ?? "",
            entry.progressVolume.map(numberText) ?? "",
            entry.rating.map(numberText) ?? "",
            defused(entry.note ?? ""),
            entry.startDate.map(iso) ?? "",
            entry.finishDate.map(iso) ?? "",
            entry.numberOfRereads.map(String.init) ?? "",
            entry.priority.map(String.init) ?? "",
            entry.isPrivate.map { $0 ? "true" : "false" } ?? ""
        ]
    }

    /// A whole chapter prints as "12", not "12.0" — matching how the app's
    /// own chapter field (`LibraryEditSheet.chapterText`) renders the same
    /// value everywhere else it appears.
    private static func numberText(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }

    private static func quoteIfNeeded(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Stops a spreadsheet treating an exported note as a formula.
    ///
    /// RFC 4180 quoting is about parsing, not about what Excel and Numbers do
    /// afterwards: a field beginning `=`, `+`, `-` or `@` is read as a formula
    /// and executed when the reader opens their own backup (work-list 91).
    /// The note is the reader's own text, but pasted text is real input and
    /// this file is meant to be opened in exactly those two apps. A leading
    /// apostrophe is the conventional defusal — spreadsheets strip it on
    /// display, and `LibraryImport` sees it only in a field that could not
    /// have been a number anyway. Applied to the title and the note only:
    /// every other column is a number, a date or an enum, and a negative
    /// priority is `-1`, not a formula.
    private static func defused(_ field: String) -> String {
        guard let first = field.first, "=+-@".contains(first) else { return field }
        return "'" + field
    }

    /// "MangaBaka library 2026-09-13" — the base name both export formats
    /// share, before their extension.
    static func filenameStem(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return "MangaBaka library \(formatter.string(from: date))"
    }
}

/// The JSON file `ShareLink` hands off. A fixed content type per type is what
/// `Transferable`'s `FileRepresentation` needs — see `LibraryExportCSVFile`
/// for the CSV twin, which cannot share this one because the export format
/// is chosen by the reader's tap, not known until then.
struct LibraryExportJSONFile: Transferable, Sendable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.filename)
            try export.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// The CSV twin of `LibraryExportJSONFile`.
struct LibraryExportCSVFile: Transferable, Sendable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.filename)
            try export.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
