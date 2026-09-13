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
    /// Settled on `pickedTagMode` whenever a tag is picked. The binding
    /// stays so the two callers' signatures do not change.
    @Binding var mode: String?

    @State private var query = ""
    /// Every usable tag, bundled and live folded together — including rows
    /// the reader's settings withhold. Filter through `visible`.
    @State private var tags: [Tag] = []
    /// Kept beside `tags` and set with it, see `TagBreadth.sortedCounts`.
    @State private var sortedCounts: [Int] = []
    @State private var isLoading = true
    @State private var openGroup: Int?
    @State private var search: TagSearch?
    /// Where `tags` came from, once loading finishes. See `TagPickerStatus`.
    @State private var status: TagPickerStatus = .nothing
    /// The live fetch's own failure, kept only for `.nothing`'s
    /// `FailureState` — a bundled fallback still on screen (`.bundledOnly`)
    /// gets a footnote instead, since there is something to show either way.
    @State private var liveFailure: APIError?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tagAudience) private var audience

    /// How many tags a group shows before asking. A guess: eight rows is
    /// about one screen under the field and the chosen chips on a 393pt
    /// phone; nothing measured it.
    private static let perGroup = 8

    /// The only value `tag_mode` can usefully take. The picker offered
    /// a Match-any button as well, which set `mode` to nil — never sent — and the
    /// API ignores `tag_mode` in any case: measured 2026-09-13,
    /// `tag=Isekai&tag=Regression` answers 164 with `tag_mode=or`, with
    /// `=and`, and with neither, while `tag=isekai` alone is 7,116. A control
    /// whose two states produce the same request is not a control; it is
    /// gone until the API honours it. Mix reads `"and"`/`"or"` and patched
    /// nil back to `"and"` itself, so writing it here settles both callers.
    nonisolated static let pickedTagMode = "and"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !isLoading, status == .nothing, let liveFailure {
                        // Both the bundled fallback and the live fetch failed
                        // — gap 42, where the sheet used to render a blank
                        // list with no explanation at all.
                        FailureState(error: liveFailure, retry: { await reload() })
                    } else if !isLoading, status == .nothing {
                        // No failure and still nothing: a real, if unlikely,
                        // "there is no tag catalogue" rather than a broken
                        // request. `EmptyState`, not `FailureState` with a
                        // guessed cause — the fix this whole family exists
                        // for is telling the two apart (systemic cause (m):
                        // no `?? .offline` standing in for an absent error).
                        EmptyState(
                            title: "No tags to show",
                            message: "Nothing came back from the catalogue. Try again in a moment.",
                            actionTitle: "Try again",
                            action: { Task { await reload() } }
                        )
                    } else {
                        field
                        if !selected.isEmpty {
                            chosen
                        }
                        if !isLoading, status == .bundledOnly {
                            bundledFootnote
                        }
                        breadthLegend
                        if query.isEmpty {
                            groups
                        } else {
                            matches
                        }
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
        .edgeSwipeToDismiss()
        .task { await load() }
        .onChange(of: query) { _, new in search?.update(query: new) }
    }

    // MARK: - Pieces

    /// Gap 41: the bundled fallback used to render with no label at all, so
    /// a reader filtering by a tag renamed or merged since 2026-08-27 had no
    /// idea the list in front of them might not match what the API would
    /// say today.
    private var bundledFootnote: some View {
        Text("Showing a bundled tag list from 2026-08-27 — the live catalogue couldn't be reached.")
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
    }

    /// What the little orange bar on each row means.
    ///
    /// VoiceOver was told ("Broad, 9,000 series") and a sighted reader was
    /// not. A reviewer looking straight at the bars concluded they were a
    /// leftover slider control, which is a fair reading of an unlabelled
    /// 44x3pt rectangle repeated down a list.
    private var breadthLegend: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceChip)
                Capsule().fill(Palette.accent.opacity(0.75)).frame(width: 30)
            }
            .frame(width: 44, height: 3)
            Text("how many series carry the tag")
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
            Spacer(minLength: 0)
        }
        // One element, and a sentence rather than a picture: reading a legend
        // aloud as "bar, how many series carry the tag" helps nobody, and each
        // row already announces its own breadth in words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Each row's bar shows how many series carry that tag.")
    }

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
            SearchClearButton(text: $query)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.field)
        .background(Palette.surfaceField, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
    }

    private var placeholder: String {
        isLoading ? "Search tags" : "Search \(visible.count.formatted()) tags"
    }

    /// What this reader may be offered. See `TagAudience`.
    private var visible: [Tag] { tags.filter(audience.isShown) }

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
                    .tapTarget()
                }
                .buttonStyle(.press)
                .accessibilityLabel("Remove \(name)")
            }
        }
    }

    /// Asked of the API, not filtered from the 500 loaded here — there are
    /// 7,127 tags and the popular list does not contain Romance. See `TagSearch`.
    @ViewBuilder
    private var matches: some View {
        let found = search?.results ?? []
        if found.isEmpty, search?.isSearching == false {
            Text(
                search?.emptyMessage(for: query) ?? ""
            )
            .typeSmallMeta()
            .foregroundStyle(Palette.textMuted)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(found.prefix(40))) { tag in
                    // The whole path above the leaf: "Fantasy" the Settings
                    // child and "Fantasy" the genre are otherwise the same
                    // row (C#4).
                    row(tag, subtitle: Self.parentPath(of: tag))
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
        visible.filter(\.isRoot).sorted { $0.name < $1.name }
    }

    /// Everything beneath a root, not just its direct children.
    ///
    /// Only level-2 rows were listed (`parentId == root.id`), which is 807 of
    /// the bundled 2,686: "Settings > Fantasy > Isekai" — 8,890 series, one
    /// of the most-searched tags on the site — was not browsable at all, and
    /// "25 more in search" under Settings counted siblings when the true
    /// number beneath it is in the hundreds (C#4). By path rather than
    /// walking `parentId`, since the bundled parent ids are derived from the
    /// path anyway.
    private func descendants(of root: Tag) -> [Tag] {
        let prefix = root.name + " > "
        return visible
            .filter { $0.namePath?.hasPrefix(prefix) == true }
            .sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }
    }

    /// The path between the group heading and the leaf — "Fantasy" for
    /// "Settings > Fantasy > Isekai", nothing for a direct child.
    private static func subtitle(for tag: Tag) -> String? {
        let inner = tag.namePath?.components(separatedBy: " > ").dropFirst().dropLast() ?? []
        return inner.isEmpty ? nil : inner.joined(separator: " > ")
    }

    /// The path minus the leaf, for a search hit shown out of its group.
    private static func parentPath(of tag: Tag) -> String? {
        let parents = tag.namePath?.components(separatedBy: " > ").dropLast() ?? []
        return parents.isEmpty ? nil : parents.joined(separator: " > ")
    }

    @ViewBuilder
    private func group(_ root: Tag) -> some View {
        let children = descendants(of: root)
        let isOpen = openGroup == root.id
        let chosenHere = children.filter { selected.contains($0.name) }.count

        VStack(spacing: 0) {
            Button {
                // One group open at a time: four open groups is the wall this
                // screen exists to avoid.
                Motion.run(.snappy(duration: 0.2)) {
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
                        .foregroundStyle(chosenHere > 0 ? Palette.accent : Palette.textMuted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)

            if isOpen {
                ForEach(Array(children.prefix(Self.perGroup))) { tag in
                    row(tag, subtitle: Self.subtitle(for: tag))
                }
                if children.count > Self.perGroup {
                    Text("\(children.count - Self.perGroup) more in search")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .padding(.bottom, 12)
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 0.5)
        }
    }

    // MARK: - Behaviour

    private func breadth(_ tag: Tag) -> Int { TagBreadth.step(for: tag, amongSortedCounts: sortedCounts) }

    private func row(_ tag: Tag, subtitle: String?) -> some View {
        TagPickerRow(
            tag: tag,
            subtitle: subtitle,
            breadth: breadth(tag),
            isOn: selected.contains(tag.name),
            isBlocked: audience.isBlocked(tag)
        ) {
            toggle(tag.name)
        }
    }

    private func toggle(_ name: String) {
        if let index = selected.firstIndex(of: name) {
            selected.remove(at: index)
        } else {
            selected.append(name)
        }
        // Written on a pick, not on appear: the sheet's callers re-count
        // results on every query change, and a mode flip with no tag behind
        // it would spend a request from the 30/min search window for nothing.
        mode = Self.pickedTagMode
    }
}

extension EnvironmentValues {
    /// Set once where the stores live (`RootView`), rather than threaded
    /// through `SearchView` → `FilterPanel` → here and again through
    /// `MixView` — two sheet call sites that would otherwise each grow three
    /// parameters. Until it is set, `TagAudience.default` applies.
    @Entry var tagAudience: TagAudience = .default
}

/// Split out of the struct body to stay under the lint's `type_body_length`
/// ceiling — not a widening of who is meant to touch these, same as the
/// repository's own `+Cache`/`+Count` splits.
extension TagPickerSheet {
    /// Bundled first, so the sheet opens instantly and offline; the network
    /// answer replaces it once it lands. Sets `status` from what actually
    /// ended up on screen (gap 41, 42), rather than leaving a stale or an
    /// unlabelled list with nothing saying which one the reader is looking
    /// at.
    func load() async {
        let searchState = search ?? TagSearch(catalogue: catalogue)
        search = searchState

        let bundled = TagTaxonomy.bundled().filter(\.isUsable)
        if !bundled.isEmpty {
            show(bundled, in: searchState)
            isLoading = false
            status = .bundledOnly
        }

        let fetched = await catalogue.tags(limit: 500)
        let live = (fetched.value ?? []).filter(\.isUsable)
        liveFailure = fetched.error
        if !live.isEmpty {
            // Folded into the bundled list, never swapped for it: the live
            // page is four roots of seventeen (C#3). See `TagTaxonomy.merge`.
            show(TagTaxonomy.merge(bundled: bundled, live: live), in: searchState)
        }
        status = TagPickerStatus.resolve(bundled: bundled, live: live)
        isLoading = false
    }

    /// One place that sets the three things that must move together.
    private func show(_ list: [Tag], in searchState: TagSearch) {
        tags = list
        sortedCounts = TagBreadth.sortedCounts(of: list)
        // The search filters what the reader may see, not the whole list —
        // a withheld tag found by typing its name is the same leak as one
        // found by browsing.
        searchState.loaded = list.filter(audience.isShown)
    }

    /// Retried from `FailureState` when both sources came back with nothing
    /// (gap 42) — the same load, run again.
    func reload() async {
        isLoading = true
        await load()
    }
}

/// One tag: its name, where it sits, how broad it is, and whether it is
/// chosen — or blocked in Settings, in which case it cannot be.
struct TagPickerRow: View {
    let tag: Tag
    /// The path above the leaf, when the leaf alone is ambiguous.
    var subtitle: String?
    /// 1 to 4. See `TagPickerSheet.breadth`.
    let breadth: Int
    let isOn: Bool
    /// Greyed with the reason rather than hidden or pickable: picked, it
    /// went to the wire as `tag=X&tag_not=<X>` and found nothing (C#5).
    var isBlocked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tag.name)
                        .typeBody()
                        .foregroundStyle(isBlocked ? Palette.textMuted : Palette.textPrimary)
                        .lineLimit(1)
                    if let caption {
                        Text(caption)
                            .typeFootnote()
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                bar
                checkbox
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(isBlocked)
        .accessibilityLabel(tag.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// The block outranks the path: a reader who cannot pick the row does
    /// not need to know where it sits.
    private var caption: String? {
        isBlocked ? "Blocked in Settings" : subtitle
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
        let state = isBlocked ? "Blocked in Settings" : (isOn ? "Selected" : "Not selected")
        guard let count = tag.seriesCount else { return state }
        return "\(breadthWord), \(count.formatted()) series. \(state)"
    }
}

/// How broad a tag is, as one of four steps.
///
/// Its own type so the rule can be tested. It was wrong first time round in a
/// way no test would have caught by construction — see `step(for:among:)`.
/// Whether `TagPickerSheet`'s tag list is fresh, a bundled fallback, or
/// nothing at all.
///
/// Three cases where there used to be none: the bundled 2026-08-27 list
/// rendered with no label saying it might be stale when the live fetch
/// failed (gap 41), and a blank sheet when both it and the fallback came
/// back empty (gap 42). Its own top-level type, not nested, so resolving it
/// is testable without pulling in the whole sheet's `type_body_length`
/// budget — `TagPickerSheet` is a NavigationStack-wrapped sheet already near
/// SwiftLint's 250-line ceiling on a type body.
enum TagPickerStatus: Equatable {
    /// The live catalogue answered with something to show.
    case live
    /// Only the bundled fallback has anything — the live fetch failed or
    /// returned nothing.
    case bundledOnly
    /// Neither source has anything at all.
    case nothing

    /// Pure, so it is testable without the network task in `TagPickerSheet`
    /// actually running.
    static func resolve(bundled: [Tag], live: [Tag]) -> TagPickerStatus {
        if !live.isEmpty { return .live }
        if !bundled.isEmpty { return .bundledOnly }
        return .nothing
    }
}

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
        step(for: tag, amongSortedCounts: sortedCounts(of: tags))
    }

    /// The sort, done once per tag list rather than once per row per body
    /// pass — forty rows each sorting five hundred counts while the reader
    /// typed, for an answer that was the same for every row.
    static func sortedCounts(of tags: [Tag]) -> [Int] {
        tags.compactMap(\.seriesCount).sorted()
    }

    static func step(for tag: Tag, amongSortedCounts counts: [Int]) -> Int {
        guard let count = tag.seriesCount else { return 1 }
        guard counts.count > 1 else { return 1 }
        let below = counts.firstIndex(where: { $0 >= count }) ?? 0
        let percentile = Double(below) / Double(counts.count - 1)
        return max(1, min(4, Int((percentile * 4).rounded(.up))))
    }
}
