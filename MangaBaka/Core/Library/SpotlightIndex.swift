import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The reader's library, in iOS search.
///
/// Typing a title into Spotlight finds the series and opens its page in the
/// app, with the reader's own state on it. Nothing leaves the phone: Core
/// Spotlight is an on-device index, and only library entries go in — the
/// catalogue is thousands of series the reader has no relationship with, and
/// indexing it would make Spotlight a worse search than the app's own.
///
/// No cover thumbnails yet. `CSSearchableItemAttributeSet.thumbnailData`
/// wants the bytes, and the covers live in `URLCache` rather than in files;
/// pulling 900 of them through it on every launch is a cost worth measuring
/// before paying.
struct SpotlightIndex: Sendable {
    /// Every item this app writes lives in one domain, so a sign-out can
    /// remove them all in one call without touching anything else.
    static let domain = "library"
    private static let prefix = "series-"

    private let index: @Sendable () -> CSSearchableIndex

    init(index: @escaping @Sendable () -> CSSearchableIndex = { .default() }) {
        self.index = index
    }

    /// Replaces the index with the library as it stands.
    ///
    /// Delete-then-index rather than an incremental update: entries leave the
    /// library as well as join it, and the walk that produces `entries` is
    /// already the whole library.
    func reindex(_ entries: [LibraryEntry]) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let items = Self.items(from: entries)
        try? await index().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        guard !items.isEmpty else { return }
        try? await index().indexSearchableItems(items)
    }

    /// Everything out. Called on sign-out: the entries name another account's
    /// library, and a Spotlight result that opens a page you can no longer
    /// act on is worse than none.
    func clear() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        try? await index().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
    }

    /// One searchable item per entry that carries a series. An entry whose
    /// series did not decode has no title to search for.
    static func items(from entries: [LibraryEntry]) -> [CSSearchableItem] {
        entries.compactMap { entry in
            guard let series = entry.series, let title = series.displayTitle else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = title
            attributes.contentDescription = description(for: entry)
            // Alternative titles, so the romanised or native name finds it
            // too — the reason `Series.matches` searches them in the app.
            attributes.alternateNames = series.titles?.map(\.title)
            attributes.keywords = [series.type].compactMap { $0 }
            return CSSearchableItem(
                uniqueIdentifier: identifier(for: series.id),
                domainIdentifier: domain,
                attributeSet: attributes
            )
        }
    }

    /// "Reading · chapter 53 of 120" — the reader's own state, which is what
    /// makes this result different from a web search for the same title.
    static func description(for entry: LibraryEntry) -> String {
        var parts = [entry.state.title]
        if entry.state.tracksProgress, let chapter = entry.progressChapter, chapter > 0 {
            let total = entry.series?.totalChapters.map { " of \(Int($0))" } ?? ""
            parts.append("chapter \(Int(chapter))\(total)")
        }
        if let type = entry.series?.type, !type.isEmpty { parts.append(type.capitalized) }
        return parts.joined(separator: " · ")
    }

    static func identifier(for seriesID: Int) -> String { "\(prefix)\(seriesID)" }

    /// The series a tapped Spotlight result names, from the activity iOS
    /// hands the app. Nil for anything that is not one of ours.
    static func seriesID(from activity: NSUserActivity) -> Int? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix(prefix)
        else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }
}
