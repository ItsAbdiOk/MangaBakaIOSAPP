import SwiftUI

/// What the reader has hidden by theme rather than by rating.
///
/// **Shown even when empty.** It used to disappear entirely with nothing
/// blocked, which meant the one place you would look to find out what you have
/// hidden from yourself was missing exactly when the answer was "nothing" —
/// indistinguishable, from the outside, from the feature not existing.
///
/// The empty state carries no icon and no illustration, deliberately: an empty
/// blocked list is the normal state, so it should read as an invitation rather
/// than as something gone wrong.
struct BlockedTagsSection: View {
    let blockedTags: BlockedTagsStore
    let catalogue: CatalogueService

    @State private var isPicking = false

    var body: some View {
        SettingsSection(title: "Blocked tags", caption: caption) {
            FlowLayout(spacing: 7) {
                ForEach(Array(blockedTags.blocked.tags.enumerated()), id: \.element.id) { index, tag in
                    chip(tag).arrives(index: index)
                }
                addControl
            }
        }
        .sheet(isPresented: $isPicking) {
            BlockTagPicker(blockedTags: blockedTags, catalogue: catalogue)
        }
    }

    private var caption: String {
        blockedTags.blocked.isEmpty
            ? """
            Nothing is blocked. Add a tag here and it is hidden everywhere, \
            whatever a series is rated.
            """
            : "Hidden everywhere, whatever a series is rated."
    }

    /// The × gets its own roundel rather than sitting bare in the chip.
    ///
    /// A bare × inside a pill has no edge to aim at, and the whole chip is
    /// already a tap target for the same action — so at small sizes people miss
    /// and hit nothing. The roundel is the thing to aim at.
    private func chip(_ tag: BlockedTags.Blocked) -> some View {
        Button {
            Task { await blockedTags.toggle(id: tag.id, name: tag.name) }
        } label: {
            HStack(spacing: 7) {
                Text(tag.name).typeChip()
                Image(systemName: "xmark")
                    .typeSymbol(size: 8, weight: .bold)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Palette.surfaceField, in: Circle())
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(minHeight: Metrics.headerPill)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
            .contentShape(Capsule())
            .tapTarget()
        }
        .buttonStyle(.press)
        .accessibilityLabel("Unblock \(tag.name)")
    }

    /// Dashed, because it is a slot rather than a thing — the same reason a
    /// mix seed's empty slot is dashed.
    private var addControl: some View {
        Button { isPicking = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .typeSymbol(size: 10, weight: .bold)
                    .foregroundStyle(Palette.accent)
                Text("Block a tag").typeChip()
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.headerPill)
            .overlay(Capsule().strokeBorder(Palette.borderDashed, style: StrokeStyle(
                lineWidth: 0.5, dash: [3]
            )))
            .contentShape(Capsule())
            .tapTarget()
        }
        .buttonStyle(.press)
    }
}

/// Search the tag list and block one.
///
/// Blocking used to be possible only from Browse, where the tags are. That is
/// still the natural place to block one you have just met — but a reader who
/// came to Settings specifically to hide something should not be sent on a tour
/// of the app to do it.
struct BlockTagPicker: View {
    let blockedTags: BlockedTagsStore
    let catalogue: CatalogueService

    /// What the vocabulary fetch produced, so the picker can tell "still
    /// asking", "asking failed with a bundled copy to fall back on", and
    /// "asking failed with nothing at all" apart — a blank list used to be
    /// the only outcome a failed fetch ever showed (gap 40, 68).
    ///
    /// Its own type rather than reusing `TagPickerSheet`'s — that sheet
    /// belongs to a sibling agent working on it in parallel, and the two
    /// pickers' status is the same *shape* of problem without being the same
    /// code.
    enum Status: Equatable {
        case loading
        /// The live fetch answered — nothing is stale.
        case live
        /// The live fetch failed, but the bundled taxonomy filled the list.
        case bundledOnly(APIError)
        /// The live fetch failed and there is nothing bundled either.
        case failed(APIError)
    }

    @State private var query = ""
    @State private var tags: [Tag] = []
    @State private var status: Status = .loading
    @State private var search: TagSearch?
    @Environment(\.dismiss) private var dismiss

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var matches: [Tag] {
        guard isSearching else { return Array(tags.prefix(40)) }
        return Array((search?.results ?? []).prefix(40))
    }

    var body: some View {
        NavigationStack {
            List {
                if case let .failed(error) = status {
                    InlineFailure(error: error) { await load() }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(matches) { tag in
                    row(tag)
                }
                if isSearching, matches.isEmpty, search?.isSearching == false {
                    // Never a blank screen. Typing a real tag used to empty the
                    // list with no explanation, which reads as broken rather
                    // than as an answer.
                    Text(search?.emptyMessage(for: query) ?? "")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .listRowBackground(Color.clear)
                }
                if status == .loading {
                    HStack {
                        Spacer()
                        ProgressView().tint(Palette.textTertiary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                if case let .bundledOnly(error) = status {
                    // A footnote, not a full failure: the list on screen is
                    // real and usable, just a year-old bundled copy rather
                    // than today's answer (gap 68) — mirrors what the
                    // vocabulary fetch's other pickers do, in this picker's
                    // own state rather than one shared across screens.
                    Text("Showing a bundled copy of the tag list — \(error.headline.lowercased()).")
                        .typeFootnote()
                        .foregroundStyle(Palette.textMuted)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .searchable(text: $query, prompt: "Search all tags")
            .onChange(of: query) { _, new in search?.update(query: new) }
            .navigationTitle("Block a tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
        .task {
            let search = TagSearch(catalogue: catalogue)
            self.search = search
            await load()
        }
    }

    /// Bundled first, so the sheet opens instantly and offline, mirroring
    /// `TagPickerSheet`'s own local strategy; the live fetch then either
    /// confirms the bundled copy was enough or replaces it, and `status`
    /// records which of the two happened for the footnote above.
    private func load() async {
        status = .loading
        let bundled = TagTaxonomy.bundled().filter(\.isUsable)
        if !bundled.isEmpty {
            tags = bundled
            search?.loaded = tags
        }

        let fetched = await catalogue.tags(limit: 500)
        status = Self.status(bundled: bundled, fetched: fetched)
        if let value = fetched.value, !value.isEmpty {
            tags = value.filter(\.isUsable)
            search?.loaded = tags
        }
    }

    /// The pure classification behind `status`, pulled out of `load()` so it
    /// can be driven directly from a test — this project has no
    /// ViewInspector, so logic that only lives inside a `@State` mutation
    /// cannot be proven any other way. `nonisolated` because a test calls it
    /// off the main actor without wanting to spin up a whole view.
    nonisolated static func status(bundled: [Tag], fetched: Fetched<[Tag]>) -> Status {
        if let value = fetched.value, !value.isEmpty { return .live }
        if let error = fetched.error {
            return bundled.isEmpty ? .failed(error) : .bundledOnly(error)
        }
        // Asked and got nothing back, rather than asked and failed — an
        // empty vocabulary is a real, if strange, answer.
        return .live
    }

    private func row(_ tag: Tag) -> some View {
        let isBlocked = blockedTags.blocked.contains(tag.id)
        return Button {
            Task { await blockedTags.toggle(id: tag.id, name: tag.name) }
        } label: {
            HStack {
                Text(tag.name)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                if isBlocked {
                    Image(systemName: "checkmark")
                        .typeSymbol(size: 12, weight: .bold)
                        .foregroundStyle(Palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .listRowBackground(Color.clear)
        .accessibilityLabel(isBlocked ? "\(tag.name), blocked" : tag.name)
    }
}
