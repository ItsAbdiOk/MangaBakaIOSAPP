import Foundation
import os

/// An array that decodes what it can and drops what it cannot.
///
/// `getWithPagination` decodes a page of thirty `Series` as one value, so a
/// single row with an unexpected shape — one of the four "model disagrees
/// with the payload" defects the 2026-09-11 review found — fails the whole
/// page, and the reader sees a decode failure instead of twenty-nine
/// results (search review E F12). Each element is decoded on its own here;
/// the ones that throw are counted in `dropped` so a caller can log the
/// loss rather than never learn of it.
struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    var elements: [Element]
    var dropped: Int
    /// The first `DecodingError`'s own description, kept rather than
    /// discarded. Before this, all `getLossy` could ever say was "3 rows
    /// dropped" — a count with no key name — so a `tags_v2` or `works`
    /// shape change reached Abdi with nothing to grep for. A
    /// `DecodingError`'s description names the coding path and the key that
    /// changed, which is exactly what charter §1's history of shape changes
    /// needs (wire review W10/P10, 2026-09-15). Only the first is kept: a
    /// page of thirty bad rows from the same shape change would otherwise
    /// write thirty near-identical strings nobody reads past the first.
    var firstDropReason: String?

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        var firstDropReason: String?
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                if firstDropReason == nil { firstDropReason = String(describing: error) }
                // `Blank` advances the container past the element that
                // failed; without it the same bad element is read forever.
                _ = try? container.decode(Blank.self)
                dropped += 1
            }
        }
        self.elements = elements
        self.dropped = dropped
        self.firstDropReason = firstDropReason
    }

    private struct Blank: Decodable {}
}

/// One `Logger` per file, per the brief — `Core/Networking` had none before
/// today (wire review W10/W11, 2026-09-15).
private let lossyLogger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "wire")

extension APIClient {
    /// `get`, but decoding the array element by element and counting what it
    /// had to throw away.
    ///
    /// Every `[T]` decode outside `search` used to fail the whole array on one
    /// bad row. That has emptied a section in production twice — `SeriesWork`
    /// (the volumes row) and `PublisherRecord` — and on a library walk one bad
    /// entry kills the page *and* the walk that was paging through it. The
    /// drop count goes to `NetworkLedger` rather than to a log line because
    /// the question it answers ("is the app quietly showing nineteen of
    /// twenty?") is the same shape as the request counts already kept there,
    /// and because a log line is only read by someone already looking.
    func getLossy<Element: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        priority: RequestPriority = .userInitiated,
        as _: Element.Type = Element.self
    ) async throws(APIError) -> [Element] {
        let box: LossyArray<Element> = try await get(path, query: query, priority: priority)
        await Self.recordLoss(box, path: path)
        return box.elements
    }

    /// The same, keeping the envelope's `pagination`. A page short by one
    /// dropped row still reports the server's own `next`, which is what ends
    /// a walk — counting survivors would end it early.
    func getLossyWithPagination<Element: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        priority: RequestPriority = .userInitiated,
        as _: Element.Type = Element.self
    ) async throws(APIError) -> (elements: [Element], pagination: Pagination?) {
        let (box, pagination): (LossyArray<Element>, Pagination?) =
            try await getWithPagination(path, query: query, priority: priority)
        await Self.recordLoss(box, path: path)
        return (box.elements, pagination)
    }

    /// The conditional fetch, decoded leniently. `.notModified` carries no
    /// body, so there is nothing to drop and nothing to count.
    func getLossyConditional<Element: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        priority: RequestPriority = .userInitiated,
        ifModifiedSince: String?,
        as _: Element.Type = Element.self
    ) async throws(APIError) -> Conditional<[Element]> {
        let conditional: Conditional<LossyArray<Element>> = try await get(
            path, query: query, ifModifiedSince: ifModifiedSince, priority: priority
        )
        guard case let .fresh(box, lastModified) = conditional else { return .notModified }
        await Self.recordLoss(box, path: path)
        return .fresh(box.elements, lastModified: lastModified)
    }

    /// One place for what every `getLossy*` variant does with its dropped
    /// rows: a `Logger` line naming the reason (nothing did before today,
    /// W11/P11), and the count plus that same reason into `NetworkLedger` so
    /// Settings can show it without anyone having to be watching the console
    /// (W10/P10, 2026-09-15).
    private static func recordLoss<Element: Decodable & Sendable>(
        _ box: LossyArray<Element>, path: String
    ) async {
        guard box.dropped > 0 else { return }
        if let reason = box.firstDropReason {
            lossyLogger.error(
                """
                \(path, privacy: .public) dropped \(box.dropped, privacy: .public) \
                row(s): \(reason, privacy: .public)
                """
            )
        }
        await NetworkLedger.shared.recordDropped(path: path, count: box.dropped, reason: box.firstDropReason)
    }
}
