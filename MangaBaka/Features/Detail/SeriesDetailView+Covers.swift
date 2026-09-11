import SwiftUI

/// The covers behind the front one, for the fan and the gallery. Its own
/// file for the lint's ceiling on `SeriesDetailView`.
extension SeriesDetailView {
    var otherCovers: [SeriesImage] {
        var out = covers
        if let preferred { out.removeAll { $0.id == preferred.id } }
        // The platform's image last, and only when it is not one MangaBaka
        // already holds.
        if let platformCoverURL,
           platformCoverURL != shown.cover.raw,
           !out.contains(where: { $0.image.raw == platformCoverURL }) {
            out.append(SeriesImage(
                imageID: nil, seriesId: shown.id, type: "platform", index: nil, indexNumeric: nil,
                language: nil, contentRating: shown.contentRating,
                image: Cover(raw: platformCoverURL, x150: nil, x250: nil, x350: nil,
                             blurhash: nil, width: nil, height: nil)
            ))
        }
        return out
    }
}
