import Foundation

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

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            // `Blank` advances the container past the element that failed;
            // without it the same bad element is read forever.
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Blank.self)
                dropped += 1
            }
        }
        self.elements = elements
        self.dropped = dropped
    }

    private struct Blank: Decodable {}
}
