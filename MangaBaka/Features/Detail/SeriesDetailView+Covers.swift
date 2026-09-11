import SwiftUI

/// The covers behind the front one, for the fan and the gallery. Its own
/// file for the lint's ceiling on `SeriesDetailView`.
extension SeriesDetailView {
    var otherCovers: [SeriesImage] {
        var out = covers
        if let preferred { out.removeAll { $0.id == preferred.id } }
        return out
    }
}
