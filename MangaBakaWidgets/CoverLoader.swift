import UIKit

/// Fetches cover art for a timeline entry before it is handed to WidgetKit.
///
/// A widget's view is rendered once into a static snapshot, not kept alive as
/// a live view — `AsyncImage` never gets a chance to finish loading before
/// that render is captured, so it draws its placeholder forever. Every cover
/// a widget shows has to already be in hand by the time the entry is built.
enum CoverLoader {
    /// Matches how many rows either widget ever draws (`systemMedium`'s three
    /// plus one to spare) — nothing here needs to fetch a cover for a row that
    /// will never be shown.
    static let maxCovers = 4

    static func covers(
        for items: [WidgetSnapshotData.Item],
        session: URLSession = .shared
    ) async -> [Int: UIImage] {
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for item in items.prefix(maxCovers) {
                guard let url = item.coverURL else { continue }
                group.addTask {
                    guard let (data, _) = try? await session.data(from: url) else {
                        return (item.seriesID, nil)
                    }
                    return (item.seriesID, UIImage(data: data))
                }
            }
            var result: [Int: UIImage] = [:]
            for await (seriesID, image) in group {
                if let image { result[seriesID] = image }
            }
            return result
        }
    }
}
