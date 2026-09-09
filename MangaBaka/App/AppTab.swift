import Foundation

/// Named AppTab, not Tab: SwiftUI's own Tab view is used below and the two
/// names collide.
enum AppTab: Hashable, CaseIterable {
    case discover, stack, mix, library, search

    var title: String {
        switch self {
        case .discover: "Discover"
        case .stack: "Stack"
        case .mix: "Mix"
        // The mockup's fourth tab. It still shows the local shelf until the
        // designed Library screen is built, so the label leads and the
        // contents follow rather than the other way round.
        case .library: "Library"
        case .search: "Search"
        }
    }

    /// Chosen to read like the mockup's line-art glyphs.
    var symbol: String {
        switch self {
        case .discover: "circle.circle"
        case .stack: "line.3.horizontal"
        case .mix: "circle.on.circle"
        case .library: "chart.bar.fill"
        case .search: "magnifyingglass"
        }
    }
}
