import Foundation
import Testing
@testable import MangaBaka

/// Fixture builders shared by the Wrapped suites, which were one file until
/// it outgrew the length limit.
protocol WrappedFixtures {}

extension WrappedFixtures {
    func tag(_ id: Int, _ name: String, world: Int, spoiler: Bool = false) -> SeriesTag {
        SeriesTag(
            id: id, name: name, namePath: nil, isGenre: false, isSpoiler: spoiler,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: "core", seriesCount: world
        )
    }

    func libraryEntry(
        _ id: Int,
        state: LibraryEntry.State = .completed,
        read: Double? = nil,
        total: Double? = nil,
        rating: Double? = nil,
        crowdRating: Double? = nil,
        ratingCount: Int? = nil,
        start: Date? = nil,
        finish: Date? = nil,
        type: String = "manhwa",
        year: Int? = nil,
        authors: [String]? = nil,
        tags: [SeriesTag] = []
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: read,
            progressVolume: nil, rating: rating, note: nil,
            startDate: start, finishDate: finish,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil,
            series: SeriesFactory.make(
                id: id, title: "S\(id)", authors: authors, rating: crowdRating,
                type: type, totalChapters: total, year: year,
                ratingCount: ratingCount, tagsV2: tags.isEmpty ? nil : tags
            )
        )
    }

    func day(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: iso) ?? .distantPast
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

}
