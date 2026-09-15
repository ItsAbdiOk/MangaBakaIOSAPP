import SwiftUI

/// One drilled-into tag: its breadcrumb, a "Browse N series" action, and its
/// own children — pushed by `TagTreeRow` and registered once, on
/// `TagTreeView`, so tapping a child here pushes the same view again for the
/// next level down.
struct TagTreeLevelView: View {
    let tag: Tag
    let model: TagTreeModel
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]

    private var children: [Tag] { TagTreeModel.children(of: tag.id, in: model.tags) }
    private var breadcrumb: [Tag] { TagTreeModel.path(to: tag.id, in: model.tags) }

    var body: some View {
        List {
            Section {
                if breadcrumb.count > 1 {
                    Text(breadcrumb.map(\.name).joined(separator: " › "))
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                browseAction
            }
            .listRowSeparator(.hidden)
            if !children.isEmpty {
                Section("Sub-tags") {
                    ForEach(children) { child in
                        TagTreeRow(
                            tag: child,
                            childCount: TagTreeModel.children(of: child.id, in: model.tags).count
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Browse 1,204 series" for a node with series of its own. A category
    /// node (own count 0, children below) gets no button: the API has no
    /// working tag-OR (`SearchQuery.tagMode`'s doc), so "browse this
    /// category" would search the category tag alone and answer nothing.
    ///
    /// There was a toggle here, "Include sub-tags in the count", from the
    /// first version on 2026-09-14. It changed the number on the button and
    /// never what the button searched — the honest thing about it was the
    /// word "roughly", and a control that changes a label but not the
    /// result is the kind of thing this project's reviews call
    /// "computed and discarded" from the reader's side. Removed 2026-09-15;
    /// `TagTreeModel.descendantIDs` stays: its tests hold, and a future
    /// server-side OR would want it.
    @ViewBuilder
    private var browseAction: some View {
        if let count = tag.seriesCount, count > 0 {
            NavigationLink(value: TagBrowseRequest(tag: tag)) {
                Text("Browse \(count.formatted()) series")
                    .typeInstruction()
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Metrics.headerPill + 8)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browse \(count.formatted()) series")
            .padding(.vertical, 4)
        } else if !children.isEmpty {
            Text("Pick a sub-tag to browse — this one is a category, not a tag on any series.")
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
                .padding(.vertical, 4)
        }
    }
}
