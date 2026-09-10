import XCTest
@testable import MangaBaka

/// How long the app's own work takes, with baselines.
///
/// **XCTest rather than Swift Testing**, because `measure(metrics:)` and its
/// saved baselines only exist there. The rest of the suite is Swift Testing and
/// stays that way; this is the one thing it cannot do.
///
/// **Not in the scheme's test action.** These are slow and they are sensitive
/// to whatever else the machine is doing. A test that fails because a laptop
/// was busy teaches people to ignore failures, and the point of a baseline is
/// to be believed.
///
/// What is measured is the app's own work — decoding, grouping, sorting,
/// filtering — with the network stubbed. Network time is measured separately by
/// `NetworkLedger` against the real API, because a stub cannot tell you
/// anything true about how fast MangaBaka is.
final class JourneyPerformanceTests: XCTestCase {
    /// A realistic library. Abdi's is 939; a thousand is the round number just
    /// past it, and the size at which sorting stops being free.
    private static let librarySize = 1_000

    private func entries(_ count: Int) throws -> [LibraryEntry] {
        let states = LibraryEntry.State.allCases
        return try (0..<count).map { index in
            try JSONDecoder.performance.decode(LibraryEntry.self, from: Data("""
            {"id": \(index), "series_id": \(index),
             "state": "\(states[index % states.count].rawValue)",
             "rating": \(index % 101),
             "Series": {"id": \(index), "state": "active", "cover": {},
                        "title": "The Series \(index % 26 == 0 ? "A" : "M")\(index)"}}
            """.utf8))
        }
    }

    /// Sorting a thousand entries by title, which is what the jump index needs
    /// and what a reader does whenever they go looking for something.
    func testLibrarySortByTitle() throws {
        let rows = try entries(Self.librarySize)
        measure {
            _ = rows.sorted(by: LibrarySort.title.comparator)
        }
    }

    /// The shape bar and the state filter both count the whole library on every
    /// redraw. If that is slow, every tap on a filter pill is slow.
    func testLibraryShapeCounting() throws {
        let rows = try entries(Self.librarySize)
        measure {
            for state in LibraryEntry.State.allCases {
                _ = rows.count { $0.state == state }
            }
        }
    }

    /// Grouping a real tag list. Solo Leveling carries 146 tags across
    /// seventeen groups, and this runs on every render of a series page.
    func testTagGrouping() {
        let tags = (0..<146).map { index in
            SeriesTag(
                id: index,
                name: "Tag \(index)",
                namePath: "Group \(index % 17) > Middle > Tag \(index)",
                isGenre: index < 6,
                isSpoiler: index % 11 == 0,
                isExplicit: false,
                impliedByTagIds: index % 5 == 0 ? [index - 1] : nil,
                contentRating: "safe",
                weight: ["core", "defining", "recurrent", "incidental"][index % 4],
                seriesCount: index * 37
            )
        }
        measure {
            _ = TagGrouping.groups(from: tags, allowedRatings: ["safe"], favouredIDs: [1, 2, 3])
        }
    }

    /// Decoding a feed. Every screen in the app starts here, and `Series` has a
    /// hand-written decoder that has grown a lot.
    func testFeedDecoding() throws {
        let rows = (0..<20).map { index in
            """
            {"id": \(index), "state": "active", "cover": {}, "type": "manhwa",
             "title": "Series \(index)", "rating": 82.5, "total_chapters": "179",
             "tags": ["Regression", "Murim"], "content_rating": "safe"}
            """
        }
        let payload = Data("""
        {"status": 200, "data": [\(rows.joined(separator: ","))]}
        """.utf8)

        measure {
            _ = try? JSONDecoder.performance.decode(APIEnvelope<[Series]>.self, from: payload)
        }
    }

    /// The taste ledger walks every tag of every library entry. This is the one
    /// piece of work in the app that is genuinely proportional to library size
    /// times tag count, so it is the one most likely to bite first.
    func testTasteLedgerAbsorb() throws {
        let database = try AppDatabase.inMemory()
        let tags = (0..<40).map { index in
            SeriesTag(
                id: index, name: "Tag \(index)", namePath: nil, isGenre: false,
                isSpoiler: false, isExplicit: false, impliedByTagIds: nil,
                contentRating: nil, weight: "core", seriesCount: nil
            )
        }
        let rows = try entries(200).map { entry in
            LibraryEntry(
                id: entry.id, seriesId: entry.seriesId, state: .completed,
                progressChapter: nil, progressVolume: nil, rating: nil, note: nil,
                startDate: nil, finishDate: nil, numberOfRereads: nil, priority: nil,
                isPrivate: nil, readLink: nil,
                series: SeriesFactoryStub.make(id: entry.seriesId, tags: tags)
            )
        }

        measure {
            let ledger = TasteLedger(database: database)
            let expectation = expectation(description: "absorbed")
            Task {
                try? await ledger.clear()
                try? await ledger.absorb(rows)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30)
        }
    }
}

private extension JSONDecoder {
    static var performance: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// A minimal series builder, so this target does not depend on the other test
/// target's factory.
private enum SeriesFactoryStub {
    static func make(id: Int, tags: [SeriesTag]) -> Series {
        Series(
            id: id, state: "active", mergedWith: nil, titles: nil,
            cover: Cover(raw: nil, x150: nil, x250: nil, x350: nil,
                         blurhash: nil, width: nil, height: nil),
            description: nil, authors: nil, artists: nil, status: nil, rating: nil,
            type: "manhwa", contentRating: nil, totalChapters: nil, finalVolume: nil,
            publishers: nil, anime: nil, source: nil, year: nil, ratingCount: nil,
            tags: nil, tagsV2: tags
        )
    }
}
