import SwiftUI

/// Browse by genre, or by the tag tree underneath.
struct BrowseView: View {
    @State private var model: BrowseModel
    private let onPickGenre: (Genre) -> Void
    private let onPickTag: (Tag) -> Void

    init(
        model: BrowseModel,
        onPickGenre: @escaping (Genre) -> Void,
        onPickTag: @escaping (Tag) -> Void
    ) {
        _model = State(initialValue: model)
        self.onPickGenre = onPickGenre
        self.onPickTag = onPickTag
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                genreChips
                tagHeader
                ForEach(model.sections, id: \.name) { section in
                    sectionView(section.name, tags: section.tags)
                }
                Text("""
                Counts dim below 100. Spoiler tags stay hidden until asked for, \
                and merged tags are never listed — they lead nowhere.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
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

    private func sectionView(_ name: String, tags: [Tag]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .typeSmallMeta()
                .foregroundStyle(Palette.textTertiary)
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
                                    .foregroundStyle(Palette.textTertiary)
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
            }
        }
    }
}
