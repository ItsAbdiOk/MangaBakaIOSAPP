import Foundation
import GRDB

/// A cached series row: MangaBaka's ID, the raw JSON we received, and when.
struct CachedSeries: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "series"

    var id: Int
    var payload: Data
    var cachedAt: Date
}

/// One position in an ordered feed.
struct FeedEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "feedEntry"

    var feedKey: String
    var position: Int
    var seriesId: Int
}

/// When a feed was last fetched.
struct FeedMetadata: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "feedMetadata"

    var feedKey: String
    var cachedAt: Date
}
