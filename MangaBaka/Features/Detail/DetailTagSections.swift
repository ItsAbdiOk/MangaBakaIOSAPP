import SwiftUI

/// A series' tags, grouped and weighted, in the app's own idiom.
///
/// MangaBaka's own site groups them, marks spoilers and shows what implied
/// what, and that structure is the only thing that makes 146 tags legible. The
/// flat list this replaces was alphabetical noise: "Language Barrier" sat
/// beside "Level System" as though they described the series equally well.
///
/// Three things carried over from their layout, none of their styling:
///
/// - **Groups.** Genres first, then what it is about, then where, then who.
/// - **Weight.** Core and defining tags lead their group; the rest follow.
/// - **Spoilers, hidden as a group.** One "4 spoilers" chip per section rather
///   than four identical covered ones, which said nothing and took the space of
///   four real tags. Printing them and colouring them differently — one way to
///   read their design — still spoils the story for anyone who reads before
///   noticing the colour.
struct DetailTagSections: View {
    let groups: [TagGroup]
    let favouredIDs: Set<Int>
    let onOpen: (SeriesTag) -> Void

    /// Groups collapse past this. Genres has six tags; Character Types has
    /// twenty-eight, and a reader scanning for the shape of a series does not
    /// want twenty-eight of anything.
    private static let collapsedPerGroup = 8

    @State private var expandedGroups: Set<String> = []
    /// Groups whose spoilers the reader has chosen to see.
    @State private var revealedSpoilers: Set<String> = []

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    section(group)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private func section(_ group: TagGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.name)
        let spoilersShown = revealedSpoilers.contains(group.name)
        // Spoilers are held back as a group, not one chip each. Rendering them
        // individually put four identical "Spoiler" chips in a row, which is
        // noise that says nothing and takes the space of four real tags.
        let safe = group.tags.filter { !$0.spoils || spoilersShown }
        let spoilerCount = group.tags.count - group.tags.filter { !$0.spoils }.count
        let visible = isExpanded ? safe : Array(safe.prefix(Self.collapsedPerGroup))
        let hidden = safe.count - visible.count

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow(text: group.name)
                Spacer(minLength: 0)
                if hidden > 0 || isExpanded {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { toggle(group.name) }
                    } label: {
                        Text(isExpanded ? "Less" : "+\(hidden)")
                            .typeChip()
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            FlowLayout(spacing: Metrics.gapChips) {
                ForEach(visible) { tag in
                    chip(tag)
                }
                if spoilerCount > 0, !spoilersShown {
                    spoilerToggle(group.name, count: spoilerCount)
                }
            }
        }
    }

    /// One chip for however many spoilers the group holds.
    private func spoilerToggle(_ group: String, count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { _ = revealedSpoilers.insert(group) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count) spoiler\(count == 1 ? "" : "s")")
                    .typeChip()
            }
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.headerPill)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.borderDashed, style: StrokeStyle(
                lineWidth: 0.5, dash: [3]
            )))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) spoiler tag\(count == 1 ? "" : "s") in \(group), hidden")
        .accessibilityHint("Reveals them")
    }

    private func chip(_ tag: SeriesTag) -> some View {
        let isMine = favouredIDs.contains(tag.id)

        return Button { onOpen(tag) } label: {
            HStack(spacing: 5) {
                // An implied tag is one the API derived from another, and
                // saying so is the difference between "this series has both"
                // and "this one follows from that one".
                if tag.isImplied {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textQuaternary)
                }
                Text(tag.name)
                    .typeChip()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(isMine ? Palette.accent : Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.headerPill)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isMine ? Palette.accent.opacity(0.45) : Palette.border,
                    lineWidth: 0.5
                )
            )
            // Weight shown as presence, not as a label. A core tag reads as
            // more solid than an incidental one without a row of badges saying
            // "CORE" that nobody would look up the meaning of.
            .opacity(opacity(for: tag))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(tag, isMine: isMine))
        .accessibilityHint("Search for this tag")
    }

    private func opacity(for tag: SeriesTag) -> Double {
        switch tag.importance {
        case .core, .defining: 1
        case .recurrent: 0.88
        case .incidental, .unweighted: 0.72
        }
    }

    private func accessibilityLabel(_ tag: SeriesTag, isMine: Bool) -> String {
        var parts = [tag.name]
        if let lineage = tag.lineage { parts.append("in \(lineage)") }
        if isMine { parts.append("one of your interests") }
        if tag.isImplied { parts.append("implied by another tag") }
        return parts.joined(separator: ", ")
    }

    private func toggle(_ group: String) {
        if expandedGroups.contains(group) {
            expandedGroups.remove(group)
        } else {
            expandedGroups.insert(group)
        }
    }
}
