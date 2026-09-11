import SwiftUI

/// Browse by genre, or by the tag tree underneath.
struct BrowseView: View {
    @State private var model: BrowseModel
    private let onPickGenre: (Genre) -> Void
    private let onPickTag: (Tag) -> Void
    private let blocked: BlockedTagsStore
    /// Publishers are searched rather than listed, so this needs the service
    /// directly. Absent where a caller has no route out of a publisher.
    let catalogue: CatalogueService?
    let onOpenPublisher: ((PublisherRecord) -> Void)?

    init(
        model: BrowseModel,
        blocked: BlockedTagsStore,
        onPickGenre: @escaping (Genre) -> Void,
        onPickTag: @escaping (Tag) -> Void,
        catalogue: CatalogueService? = nil,
        onOpenPublisher: ((PublisherRecord) -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.blocked = blocked
        self.onPickGenre = onPickGenre
        self.onPickTag = onPickTag
        self.catalogue = catalogue
        self.onOpenPublisher = onOpenPublisher
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                genreChips

                // Publishers, above the tag tree: "everything Seven Seas
                // licenses" is a coarser question than any tag, and a reader
                // who came here to browse should meet the coarse ones first.
                if let catalogue, let onOpenPublisher {
                    PublisherBrowser(catalogue: catalogue, onOpen: onOpenPublisher)
                        .padding(.horizontal, -Metrics.gutter)
                        .padding(.bottom, 24)
                }

                tagHeader
                blockedSummary
                ForEach(model.sections, id: \.name) { section in
                    sectionView(section.name, tags: section.tags)
                }
                Text("""
                Counts dim below 100. Spoiler tags stay hidden until asked for, \
                and merged tags are never listed — they lead nowhere.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.top, 20)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browse")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            Text(model.subtitle)
                .typeSubtitle()
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.horizontal, 2)
    }

    private var genreChips: some View {
        FlowLayout(spacing: 7) {
            ForEach(model.genres) { genre in
                Button { onPickGenre(genre) } label: {
                    Text(genre.label)
                        .typeChip()
                        .foregroundStyle(Palette.textBody)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(Palette.surfaceChip, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 20)
    }

    private var tagHeader: some View {
        HStack(spacing: 12) {
            Text("All tags")
                .typeSectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            Button { model.showsSpoilers.toggle() } label: {
                Text(model.spoilerLabel)
                    .typeChip()
                    .foregroundStyle(
                        model.showsSpoilers ? Palette.onAccent : Palette.textSecondary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        model.showsSpoilers ? Palette.accent : Palette.surfaceChip,
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, Metrics.sectionGap)
    }

    private func blockLabel(_ tag: Tag) -> String {
        blocked.blocked.contains(tag.id) ? "Unblock \(tag.name)" : "Block \(tag.name)"
    }

    /// "Boxing, 19 series" — and it says when a tag is a spoiler, since that is
    /// the reason a reader might not want to hear it.
    static func label(for tag: Tag) -> String {
        var parts = [tag.name]
        if let count = tag.seriesCount {
            parts.append("\(count) series")
        }
        if tag.isSpoiler == true { parts.append("spoiler tag") }
        return parts.joined(separator: ", ")
    }

    /// What the reader has hidden from themselves, by name. A count alone
    /// would leave them unable to work out why something is missing.
    @ViewBuilder
    private var blockedSummary: some View {
        if !blocked.blocked.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Blocked")
                Text(blocked.blocked.summary)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Hidden everywhere. Press and hold a tag to unblock it.")
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .hairlineBorder(Palette.border, radius: 15)
            .padding(.top, 14)
        }
    }

    private func sectionView(_ name: String, tags: [Tag]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 9)
                .padding(.bottom, 6)

            ForEach(tags) { tag in
                Button { onPickTag(tag) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.name)
                                .typeRowTitle()
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            if tag.isSpoiler == true {
                                Text("Spoiler tag")
                                    .typeFootnote()
                                    .foregroundStyle(Palette.textMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Dimmed below 100: a tag on nineteen series is not
                        // worth the same weight as one on nine thousand.
                        Text((tag.seriesCount ?? 0).formatted())
                            .typeSmallMeta()
                            .foregroundStyle(
                                (tag.seriesCount ?? 0) < 100
                                    ? Palette.textQuaternary
                                    : Palette.textSecondary
                            )
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.textQuaternary)
                    }
                    .padding(.vertical, 13)
                    .frame(minHeight: 48)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Palette.hairline).frame(height: 0.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // One stop reading "Boxing, 19 series", not three reading
                // "Boxing", "19" and an unlabelled chevron.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.label(for: tag))
                .accessibilityAddTraits(.isButton)
                // Blocking is the other thing a reader wants from a tag list,
                // and it is the only control that works at theme level rather
                // than by content rating.
                .accessibilityAction(named: blockLabel(tag)) {
                    Task { await blocked.toggle(id: tag.id, name: tag.name) }
                }
                .contextMenu {
                    Button(
                        blockLabel(tag),
                        systemImage: blocked.blocked.contains(tag.id) ? "eye" : "eye.slash"
                    ) {
                        Task { await blocked.toggle(id: tag.id, name: tag.name) }
                    }
                }
            }
        }
    }
}
