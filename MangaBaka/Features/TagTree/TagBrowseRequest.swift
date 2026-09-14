import Foundation

/// The push value for "Browse N series" from any tag-tree node. A wrapper
/// around `Tag` rather than pushing `Tag` itself: `TagTreeView` already
/// registers `.navigationDestination(for: Tag.self)` for drilling *into* a
/// node, and a second destination for the same type would be ambiguous —
/// this type exists only to give "open the results for this tag" its own
/// identity on the stack.
struct TagBrowseRequest: Hashable {
    let tag: Tag
}
