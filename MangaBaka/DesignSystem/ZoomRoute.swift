import SwiftUI

/// Which cover a detail page should grow out of.
///
/// The zoom transition needs two things to agree: a source view marked with
/// an id, and the destination's `.navigationTransition(.zoom(sourceID:))`
/// naming the same id. The destination is built by `RootView` after the tap,
/// so the tapped id has to be recorded somewhere both can reach. This is
/// that somewhere, put in the environment so every screen that pushes a
/// series — Search, Mix, Library, the stack, the related rows — can mark its
/// covers without threading a binding and a namespace through six inits.
///
/// The same series can appear twice on one screen (rising and hidden gems
/// share entries constantly), so the id is `row#seriesId`, never the series
/// alone: two views claiming one id is an ambiguous match, and the
/// transition falls back to a slide.
@MainActor
@Observable
final class ZoomRoute {
    /// The id of the cover last tapped, or nil for an ordinary push.
    var source: String?

    static func id(_ row: String, _ seriesId: Int) -> String { "\(row)#\(seriesId)" }
}

extension EnvironmentValues {
    /// The one namespace every zoom source and destination share.
    @Entry var zoomNamespace: Namespace.ID?
    @Entry var zoomRoute: ZoomRoute?
}

extension View {
    /// Marks this view as the cover a detail page can grow out of. A no-op
    /// where no namespace is in the environment, so previews and tests stay
    /// simple.
    func zoomSource(_ row: String, _ seriesId: Int) -> some View {
        modifier(ZoomSourceMark(id: ZoomRoute.id(row, seriesId)))
    }
}

private struct ZoomSourceMark: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}
