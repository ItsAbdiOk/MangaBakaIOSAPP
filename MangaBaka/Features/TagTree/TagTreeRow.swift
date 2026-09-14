import SwiftUI

/// One row of the tag tree: a name, its series count, and — via
/// `NavigationLink(value:)` — the push into `TagTreeLevelView` that
/// `TagTreeView`/`TagTreeLevelView` register `.navigationDestination(for:)`
/// for. Its own file so both hosts can share one row rather than drawing it
/// twice slightly differently, the way `BrowseView.sectionView` draws a
/// similar row inline because it has only the one place to use it.
struct TagTreeRow: View {
    let tag: Tag
    /// How many children this node has, for the accessibility label only —
    /// `List` already draws a disclosure indicator, so the sighted row does
    /// not repeat the count `BrowseView`'s hand-rolled chevron row did.
    let childCount: Int

    var body: some View {
        NavigationLink(value: tag) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tag.name)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    if tag.isSpoiler == true {
                        Text("Spoiler tag")
                            .typeFootnote()
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer(minLength: 8)
                // Dimmed below 100, matching BrowseView.sectionView's own
                // threshold and colour: a tag on nineteen series should not
                // read with the same weight as one on nine thousand.
                //
                // A node with no series of its own but children says how
                // many children instead: every root but one read "0" on the
                // 2026-09-14 walk (the taxonomy's top level is categories,
                // not tags), and "0" beside "Locations" reads as empty.
                if let count = tag.seriesCount, count > 0 || childCount == 0 {
                    Text(count.formatted())
                        .typeSmallMeta()
                        .foregroundStyle(count < 100 ? Palette.textMuted : Palette.textSecondary)
                        .countsNotCuts()
                } else if childCount > 0 {
                    Text("\(childCount) sub-tags")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TagTreeModel.accessibilityLabel(for: tag, childCount: childCount))
        .accessibilityAddTraits(.isButton)
    }
}
