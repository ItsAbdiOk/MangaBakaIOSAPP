import SwiftUI

/// The tag tree as a browsing surface — `docs/designs/api-opportunities.md`
/// §4. Drills into MangaBaka's taxonomy one level at a time, the shape the
/// data actually has (`TagTaxonomy`'s `parentId`/`level`), rather than the
/// single alphabetical-by-root list `BrowseView`'s "All tags" section
/// already shows — that list stays; this is a different way into the same
/// vocabulary, closer to wandering a library than scanning a flat list.
///
/// Registers both push destinations this feature needs —
/// `.navigationDestination(for: Tag.self)` (drill into a node) and
/// `.navigationDestination(for: TagBrowseRequest.self)` (open its results)
/// — on its own root, so wherever a host pushes `TagTreeView` onto its own
/// `NavigationStack` (the way `RootView+Tabs.swift` pushes `BrowseDestination`
/// today), every level below resolves without the host declaring anything
/// extra. `NavigationLink(value:)`/`.navigationDestination(for:)` resolve
/// against the nearest ancestor stack regardless of nesting depth, so this
/// works whether `TagTreeView` is the pushed screen itself or embedded
/// inside one.
struct TagTreeView: View {
    let model: TagTreeModel
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]

    var body: some View {
        content
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Tag.self) { tag in
                TagTreeLevelView(tag: tag, model: model, repository: repository, path: $path)
            }
            .navigationDestination(for: TagBrowseRequest.self) { request in
                TagTreeSeriesView(request: request, repository: repository, path: $path)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            // Not a blank list: `TagTaxonomy.loadFailed` (a packaging bug) and
            // an intentionally empty test fixture both answer `isEmpty`, and
            // either way the reader is owed a reason rather than a screen
            // that looks like it is still loading (BrowseModel.subtitle, gap
            // 39, draws the same line for the same reason).
            EmptyState(
                title: "No tags loaded",
                message: "The bundled tag taxonomy didn't load. Try Browse instead."
            )
        } else {
            List(model.roots) { tag in
                TagTreeRow(tag: tag, childCount: TagTreeModel.children(of: tag.id, in: model.tags).count)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
        }
    }
}
