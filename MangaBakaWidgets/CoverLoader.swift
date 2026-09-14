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

    /// Three times the 32x44 frame `SeriesWidgetView` draws into — enough for
    /// a 3x screen and nothing more.
    ///
    /// The decode used to be whatever the CDN sent. A widget extension has a
    /// memory ceiling in the low tens of MB, and four cover images at
    /// 1,200x1,800 are roughly 8 MB each once decoded: enough to be killed
    /// mid-`getTimeline`, which shows up to the reader as a widget that simply
    /// stops updating. `preparingThumbnail` decodes at the size actually
    /// needed.
    static let thumbnailSize = CGSize(width: 96, height: 132)

    /// **A guess: 10 seconds.** Shorter than the app's own 20, because this
    /// runs inside `getTimeline`: a hung CDN on `URLSession.shared`'s 60 s
    /// default turned the hourly reload into a no-op that also spent one of
    /// WidgetKit's rationed reloads. No cookies and no cache for the same
    /// reasons `ThirdPartySession` gives in the app target.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    static func covers(
        for items: [WidgetSnapshotData.Item],
        session: URLSession = CoverLoader.session
    ) async -> [Int: UIImage] {
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for item in items.prefix(maxCovers) {
                guard let url = item.coverURL else { continue }
                group.addTask {
                    guard let (data, _) = try? await session.data(from: url) else {
                        return (item.seriesID, nil)
                    }
                    let full = UIImage(data: data)
                    return (item.seriesID, await full?.byPreparingThumbnail(ofSize: thumbnailSize) ?? full)
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
