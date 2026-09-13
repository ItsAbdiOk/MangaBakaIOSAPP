import SwiftUI

/// Loading the release section.
///
/// Its own file for the same reason `SeriesDetailView+Store.swift` exists:
/// `SeriesDetailView` is at the lint's body-length ceiling.
extension SeriesDetailView {
    /// One request per provider, after the page is readable and after
    /// `extras` has loaded — `extras.links` is what tells the providers which
    /// publisher, if any, actually carries this series.
    func loadReleases() async {
        guard let releaseFeeds else { return }
        isReleasesLoading = true
        defer { isReleasesLoading = false }
        releases = await releaseFeeds.report(for: shown, links: extras.links)
    }
}
