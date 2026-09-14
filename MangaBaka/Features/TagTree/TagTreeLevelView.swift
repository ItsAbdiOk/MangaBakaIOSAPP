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

    /// Whether the count beside "Browse" adds up the whole branch instead of
    /// just this node. Default off — **a guess**, not measured: a reader who
    /// has drilled down to one specific node most likely wants that node,
    /// not every series scattered across everything beneath it, and a big
    /// number that then filters down to a small one on tap would read as a
    /// bug. See `browseCountLabel` for why the toggle only ever changes the
    /// label, never what "Browse" actually searches.
    @State private var includesDescendants = false

    private var children: [Tag] { TagTreeModel.children(of: tag.id, in: model.tags) }
    private var breadcrumb: [Tag] { TagTreeModel.path(to: tag.id, in: model.tags) }
    private var descendantIDs: Set<Int> { TagTreeModel.descendantIDs(of: tag.id, in: model.tags) }

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

    @ViewBuilder
    private var browseAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !descendantIDs.isEmpty {
                Toggle("Include sub-tags in the count", isOn: $includesDescendants)
                    .typeInstruction()
                    .tint(Palette.accent)
            }
            NavigationLink(value: TagBrowseRequest(tag: tag)) {
                Text("Browse \(browseCountLabel)")
                    .typeInstruction()
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Metrics.headerPill + 8)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browse \(browseCountLabel)")
        }
        .padding(.vertical, 4)
    }

    /// "1,204 series" for the node itself, or "roughly 8,600 series" once the
    /// toggle adds its descendants in.
    ///
    /// The "roughly" is load-bearing, not decoration: this sums each
    /// descendant's own `seriesCount` with no de-duplication for a series
    /// that carries more than one of them — a series tagged both "Boxing"
    /// and "Wrestling" counts twice here. `TagTreeModel.descendantIDs`'s doc
    /// comment covers why an exact, de-duplicated number is not available at
    /// all: the API has no working tag-OR to ask for one, so this is the
    /// nearest honest estimate rather than a real total. What "Browse"
    /// itself searches never changes with the toggle — see
    /// `TagTreeSeriesModel.init`, which always searches this one tag alone.
    private var browseCountLabel: String {
        guard includesDescendants, !descendantIDs.isEmpty else {
            return "\((tag.seriesCount ?? 0).formatted()) series"
        }
        let ids = descendantIDs.union([tag.id])
        let total = model.tags
            .filter { ids.contains($0.id) }
            .reduce(0) { $0 + ($1.seriesCount ?? 0) }
        return "roughly \(total.formatted()) series"
    }
}
