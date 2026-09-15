import UIKit
import os

/// Fetches cover art for a timeline entry before it is handed to WidgetKit.
///
/// A widget's view is rendered once into a static snapshot, not kept alive as
/// a live view — `AsyncImage` never gets a chance to finish loading before
/// that render is captured, so it draws its placeholder forever. Every cover
/// a widget shows has to already be in hand by the time the entry is built.
enum CoverLoader {
    /// S19: no `Logger` existed anywhere in the widget target — a cover
    /// fetch failing here (timeout, a 403, a bad image) was invisible, with
    /// nothing a production report could point at.
    private static let logger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "widget")

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
    /// WidgetKit's rationed reloads. No cookies for the same reasons
    /// `ThirdPartySession` gives in the app target. (`.ephemeral` still has an
    /// in-memory `URLCache`; "no cache" here means nothing on disk.)
    ///
    /// **User-Agent.** This session sent none until 2026-09-14 — the one
    /// client outside `ThirdPartySession`, because it lives in the other
    /// target. `AppUserAgent.swift` is compiled into this extension
    /// (`project.yml`) rather than the string being copied.
    ///
    /// MEASURED 2026-09-14, `curl -sI` against a real
    /// `cdn.mangabaka.dev/imgproxy/...` cover, one request per agent:
    /// no `User-Agent` header at all → **200**; a CFNetwork-shaped default
    /// (`MangaBakaWidgetsExtension/1 CFNetwork/… Darwin/…`) → **200**;
    /// `AppUserAgent.value` → **200**; `Python-urllib/3.11` → **403**. The
    /// same four against `api.mangabaka.org/v1/genres` gave the same answers,
    /// which reproduces the 2026-09-08 measurement in `AppUserAgent` and is
    /// the control for this one. So both hosts run a **blocklist of known bot
    /// agents, not a requirement to identify** — the widget's covers were
    /// *not* failing, and the review's inference that they were is wrong.
    /// The header is set anyway: it is what `AppUserAgent` exists for, the
    /// blocklist is someone else's to change, and a `try?`-swallowed cover is
    /// the one failure here nobody would ever see.
    /// S15: the extension process is short-lived, so `.ephemeral`'s in-memory
    /// `URLCache` died with it, and the same four covers (~30 KB each) were
    /// downloaded again on every hourly reload — up to 288 downloads a day
    /// for pixels the phone already had, per the review's arithmetic. A disk
    /// cache in the App Group container survives across the extension's
    /// process launches the way an in-memory one cannot, and
    /// `.useProtocolCachePolicy` (the default policy, restored explicitly
    /// here since `.ephemeral`'s own default is `.reloadIgnoringLocalCacheData`)
    /// lets the CDN's own cache headers decide when a cover is still good,
    /// rather than the app choosing a duplicate freshness window. Cheaper
    /// than the alternative the review also names — the app writing four
    /// thumbnails beside the snapshot — because it needs no new write path
    /// and no second copy of "which four covers", only a cache the session
    /// already knows how to fill.
    private static let diskCacheDirectory: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotData.appGroupID)?
        .appendingPathComponent("CoverCache", isDirectory: true)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["User-Agent": AppUserAgent.value]
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // 8 MB disk / 2 MB memory: a handful of thumbnails at ~30 KB each,
        // generously rounded — not a general-purpose cache.
        configuration.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,
            diskCapacity: 8 * 1024 * 1024,
            directory: diskCacheDirectory
        )
        return URLSession(configuration: configuration)
    }()

    static func covers<Row: WidgetCoverRow>(
        for items: [Row],
        session: URLSession = CoverLoader.session
    ) async -> [Int: UIImage] {
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for item in items.prefix(maxCovers) {
                guard let url = item.coverURL else { continue }
                // Two values, not the row: capturing `item` drags the generic
                // `Row.Type` into the child task, which Swift 6 rejects as
                // non-Sendable.
                let seriesID = item.seriesID
                group.addTask {
                    let data: Data
                    do {
                        (data, _) = try await session.data(from: url)
                    } catch {
                        logger.error("cover \(seriesID, privacy: .public) failed: \(error, privacy: .public)")
                        return (seriesID, nil)
                    }
                    let full = UIImage(data: data)
                    return (seriesID, await full?.byPreparingThumbnail(ofSize: thumbnailSize) ?? full)
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

/// What `CoverLoader.covers(for:)` needs from a snapshot row — just enough to
/// fetch and key an image, so it does not care whether it was handed a
/// `dueThisWeek`/`pickBackUp` row or a `nextVolumes` one.
///
/// Added 2026-09-14 alongside `NextVolumeEntry`: before this, `covers(for:)`
/// took `[WidgetSnapshotData.Item]` by name, which is the due/pick-back-up
/// shape only — a second, near-identical copy of this whole function is the
/// duplication this project's standards reject, for two structs that already
/// agree on the two fields that matter here.
protocol WidgetCoverRow: Sendable {
    var seriesID: Int { get }
    var coverURL: URL? { get }
}

extension WidgetSnapshotData.Item: WidgetCoverRow {}
extension WidgetSnapshotData.NextVolumeEntry: WidgetCoverRow {}
