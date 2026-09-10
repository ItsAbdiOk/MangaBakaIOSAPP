import SwiftUI

/// Choosing tags to filter by, out of seven thousand of them.
///
/// Search first, because a reader adding a tag almost always knows its name.
/// Browsing is the fallback, grouped by the tag tree's own roots, one group
/// open at a time.
///
/// **The bar is not what the board drew, and the difference matters.** The
/// board shows a four-step weight bar per tag — core, defining, recurrent,
/// incidental. That weighting says how central a tag is to *one series*, and
/// there is no series here: this is a filter picker. The number that does exist
/// for a bare tag is how many series carry it, and that is the bar drawn here.
/// It answers a real question a filter picker raises — is this a narrow tag or
/// a broad one — and it sorts the list the same way the board's does. Anything
/// else would be a bar with nothing behind it.
struct TagPickerSheet: View {
    let catalogue: CatalogueService
    @Binding var selected: [String]
    @Binding var mode: String?

    @State private var query = ""
    @State private var tags: [Tag] = []
    @State private var isLoading = true
    @State private var openGroup: Int?
    @Environment(\.dismiss) private var dismiss

    /// How many tags a group shows before asking.
    private static let perGroup = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field
                    if !selected.isEmpty {
                        chosen
                        matchMode
                    }
                    if query.isEmpty {
                        groups
                    } else {
                        matches
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Palette.ground)
            .navigationTitle("Add tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            tags = await catalogue.tags(limit: 500).filter(\.isUsable)
            isLoading = false
        }
    }

    // MARK: - Pieces

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            // The count is in the placeholder because it is the honest scale of
            // the thing: "Search tags" invites browsing a list nobody could
            // browse.
            TextField(placeholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.field)
        .background(Palette.surfaceField, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
    }

    private var placeholder: String {
        isLoading ? "Search tags" : "Search \(tags.count.formatted()) tags"
    }

    private var chosen: some View {
        FlowLayout(spacing: 8) {
            ForEach(selected, id: \.self) { name in
                Button { toggle(name) } label: {
                    HStack(spacing: 6) {
                        Text(name).typeChip()
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: Metrics.headerPill)
                    .background(Palette.accentTint, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
    }

    /// Deliberately grey when selected, where a chosen tag is accent.
    ///
    /// The accent means "this is one of your filters". All-versus-any is not a
    /// filter, it is how the filters combine — and colouring it the same would
    /// make it look like a third tag.
    private var matchMode: some View {
        HStack(spacing: 8) {
            modeButton("Match all", value: "and")
            modeButton("Match any", value: nil)
        }
    }

    private func modeButton(_ title: String, value: String?) -> some View {
        let isOn = mode == value
        return Button { mode = value } label: {
            Text(title)
                .typeChip()
                .foregroundStyle(isOn ? Palette.textPrimary : Palette.textTertiary)
                .padding(.horizontal, 14)
                .frame(minHeight: Metrics.headerPill)
                .background(isOn ? Palette.surfaceField : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    isOn ? .clear : Palette.borderPill, lineWidth: 0.5
                ))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var matches: some View {
        let found = tags
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
        return VStack(spacing: 0) {
            ForEach(Array(found.prefix(40))) { tag in
                TagPickerRow(tag: tag, breadth: breadth(tag), isOn: selected.contains(tag.name)) {
                    toggle(tag.name)
                }
            }
        }
    }

    private var groups: some View {
        VStack(spacing: 0) {
            ForEach(roots) { root in
                group(root)
            }
        }
    }

    private var roots: [Tag] {
        tags.filter(\.isRoot).sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private func group(_ root: Tag) -> some View {
        let children = tags
            .filter { $0.parentId == root.id }
            .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
        let isOpen = openGroup == root.id
        let chosenHere = children.filter { selected.contains($0.name) }.count

        VStack(spacing: 0) {
            Button {
                // One group open at a time: four open groups is the wall this
                // screen exists to avoid.
                withAnimation(.snappy(duration: 0.2)) {
                    openGroup = isOpen ? nil : root.id
                }
            } label: {
                HStack(spacing: 10) {
                    Text(root.name)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 8)
                    Text(chosenHere > 0 ? "\(chosenHere) · \(children.count)" : "\(children.count)")
                        .typeSmallMeta()
                        .foregroundStyle(chosenHere > 0 ? Palette.accent : Palette.textTertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textQuaternary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                ForEach(Array(children.prefix(Self.perGroup))) { tag in
                    TagPickerRow(
                        tag: tag,
                        breadth: breadth(tag),
                        isOn: selected.contains(tag.name)
                    ) {
                        toggle(tag.name)
                    }
                }
                if children.count > Self.perGroup {
                    Text("\(children.count - Self.perGroup) more in search")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textQuaternary)
                        .padding(.bottom, 12)
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 0.5)
        }
    }

    // MARK: - Behaviour

    private func breadth(_ tag: Tag) -> Int { TagBreadth.step(for: tag, among: tags) }

    private func toggle(_ name: String) {
        if let index = selected.firstIndex(of: name) {
            selected.remove(at: index)
        } else {
            selected.append(name)
        }
    }
}

/// One tag: its name, how broad it is, and whether it is chosen.
struct TagPickerRow: View {
    let tag: Tag
    /// 1 to 4. See `TagPickerSheet.breadth`.
    let breadth: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(tag.name)
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                bar
                checkbox
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Four steps, drawn as one bar rather than four blocks — the board's own
    /// choice, and the right one: four separate pips read as a rating out of
    /// four, which invites the question "out of what?".
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceChip)
                Capsule()
                    .fill(Palette.accent.opacity(0.35 + 0.2 * Double(breadth)))
                    .frame(width: proxy.size.width * Double(breadth) / 4)
            }
        }
        .frame(width: 44, height: 3)
        .accessibilityHidden(true)
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isOn ? Palette.accent : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isOn ? .clear : Palette.borderPill, lineWidth: 1)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        let breadthWord = switch breadth {
        case 4: "very common"
        case 3: "common"
        case 2: "uncommon"
        default: "rare"
        }
        guard let count = tag.seriesCount else { return isOn ? "Selected" : "Not selected" }
        return "\(breadthWord), \(count.formatted()) series. \(isOn ? "Selected" : "Not selected")"
    }
}

/// How broad a tag is, as one of four steps.
///
/// Its own type so the rule can be tested. It was wrong first time round in a
/// way no test would have caught by construction — see `step(for:among:)`.
enum TagBreadth {
    /// Which quarter of the loaded tags this one is broader than.
    ///
    /// **By rank, not by value.** Scaling against the largest count put every
    /// bar on step one, because tag counts are wildly skewed: a handful of
    /// genres carry tens of thousands of series and the long tail carries
    /// dozens, so everything but the giants rounded to the bottom quarter and
    /// the bar became decoration. Seen on device as eight identical bars in a
    /// row.
    ///
    /// Rank spreads them evenly by construction, which is what a four-step bar
    /// has to do to say anything at all.
    static func step(for tag: Tag, among tags: [Tag]) -> Int {
        guard let count = tag.seriesCount else { return 1 }
        let counts = tags.compactMap(\.seriesCount).sorted()
        guard counts.count > 1 else { return 1 }
        let below = counts.firstIndex(where: { $0 >= count }) ?? 0
        let percentile = Double(below) / Double(counts.count - 1)
        return max(1, min(4, Int((percentile * 4).rounded(.up))))
    }
}
