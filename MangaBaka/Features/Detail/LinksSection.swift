import SwiftUI

/// Where a series lives on the rest of the internet, grouped by what each link
/// is for.
///
/// The API returns four kinds and the app showed six links of any kind under
/// one heading, "Read it". On a real series that meant six of twenty-one, with
/// a publisher's page and an official store listing thrown in among the
/// reading platforms and no way to tell them apart. Verified against series
/// 3397 on 2026-09-11: 13 webplatform, 4 publisher, 3 info, 1 social.
///
/// Opens in the browser rather than an in-app view: these are third-party
/// sites, and framing someone else's page inside the app misrepresents whose
/// it is.
struct LinksSection: View {
    let links: [SeriesLink]

    /// How many links of one kind are shown before the group folds.
    ///
    /// Thirteen reading platforms is a wall. Six is enough to see that the
    /// series is widely available and short enough to read past.
    private static let collapsedLimit = 6

    @State private var expanded: Set<String> = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        let groups = SeriesLink.grouped(links)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    section(group.heading, links: group.links, key: group.heading)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private func section(_ heading: String, links: [SeriesLink], key: String) -> some View {
        let isExpanded = expanded.contains(key)
        let shown = isExpanded ? links : Array(links.prefix(Self.collapsedLimit))
        return VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .typeDetailSectionHeader()
                .foregroundStyle(Palette.textPrimary)

            VStack(spacing: 0) {
                ForEach(shown) { link in
                    row(link)
                    if link.id != shown.last?.id || links.count > shown.count {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
                if links.count > Self.collapsedLimit {
                    Button {
                        Motion.run(.snappy(duration: 0.22)) {
                            if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
                        }
                    } label: {
                        Text(isExpanded
                             ? "Show fewer"
                             : "Show \(links.count - Self.collapsedLimit) more")
                            .typeSmallMeta()
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Metrics.ctaSecondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                }
            }
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
        }
    }

    private func row(_ link: SeriesLink) -> some View {
        Button {
            if let url = link.safeURL { openURL(url) }
        } label: {
            HStack {
                Text(link.title)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if let language = link.language {
                    Text(LanguageFlag.name(for: language))
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                    Text(LanguageFlag.emoji(for: language) ?? "")
                        .typeGridMeta()
                        .frame(width: Metrics.flagColumn, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Image(systemName: "arrow.up.right")
                    .typeSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.ctaSecondary)
        }
        .buttonStyle(.press)
        .accessibilityHint("Opens \(link.title) in the browser")
    }
}

/// Recent news mentioning the series.
struct NewsSection: View {
    let items: [NewsItem]
    /// The series this detail page is showing, so "Also mentions N other
    /// series" can subtract it out of `mentionedSeries`. Optional because the
    /// caller may not have it in hand; when nil this view falls back to
    /// counting every id minus one, which undercounts by exactly one on any
    /// article that does not mention the current series at all — unsure how
    /// often that happens, so prefer passing this when possible.
    var currentSeriesID: Int?

    /// How many of the fetched items are shown before the rest are dropped —
    /// same shape as `DetailEditions.collapsedLimit`, just never labelled
    /// (P16). There is no "show more" here, unlike editions: `/news` is
    /// already the tail of the page (P1), so a longer list would cost more
    /// than it is worth reading.
    private static let shownLimit = 4

    @Environment(\.openURL) private var openURL

    /// One formatter, reused for every item and every pass, instead of a
    /// fresh one behind `.formatted(.relative(presentation:))` per item per
    /// body pass — the pattern `ScheduleModel` was fixed for once already
    /// (P14). Static rather than an `@State`: it holds no per-instance state
    /// of its own, so every `NewsSection` on screen shares it.
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "Also mentions 2 other series", or nothing for an article that only
    /// mentions the one series already on screen. Not `private`: exercised
    /// directly from `EditionAndNewsFieldsTests`.
    func otherMentionsLabel(_ item: NewsItem) -> String? {
        Self.otherMentionsLabel(item, currentSeriesID: currentSeriesID)
    }

    /// `nonisolated static`, so a test can call it off the main actor — the
    /// instance form above is main-actor-bound like every SwiftUI view, and
    /// calling it from a test crashed the whole test host (2026-09-15,
    /// `dispatch_assert_queue_fail`).
    nonisolated static func otherMentionsLabel(_ item: NewsItem, currentSeriesID: Int?) -> String? {
        guard let ids = item.mentionedSeries else { return nil }
        let others = if let currentSeriesID {
            ids.filter { $0 != currentSeriesID }.count
        } else {
            max(0, ids.count - 1)
        }
        guard others > 0 else { return nil }
        return "Also mentions \(others) other series"
    }

    /// "ann · Wonhee Cho", "ann", "3 hours ago" — whatever of source, author
    /// and date the item actually has, verbatim. Source names arrive
    /// lowercase on the wire ("ann"); shown as received rather than guessing
    /// at a display form ("ANN") nothing has confirmed for every source.
    private func newsMetaLine(_ item: NewsItem) -> String {
        var parts: [String] = []
        if let sourceName = item.sourceName, !sourceName.isEmpty {
            if let author = item.author, !author.isEmpty {
                parts.append("\(sourceName) · \(author)")
            } else {
                parts.append(sourceName)
            }
        } else if let author = item.author, !author.isEmpty {
            parts.append(author)
        }
        if let date = item.publishedAt {
            parts.append(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    /// Gap 78: an item whose URL `safeURL` refused (a `javascript:` scheme, an
    /// unparseable string) used to reach the row anyway, drawn identically to
    /// a live link — a dead control with no way for a reader to tell it apart
    /// before tapping it and having nothing happen.
    nonisolated static func visible(_ items: [NewsItem]) -> [NewsItem] {
        items.filter { $0.safeURL != nil }
    }

    var body: some View {
        let shown = Self.visible(items)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("News")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)

                ForEach(shown.prefix(Self.shownLimit)) { item in
                    Button {
                        if let url = item.safeURL { openURL(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .typeRowTitle()
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if item.publishedAt != nil || item.sourceName != nil || item.author != nil {
                                Text(newsMetaLine(item))
                                    .typeSmallMeta()
                                    .foregroundStyle(Palette.textMuted)
                            }
                            if let mentions = otherMentionsLabel(item) {
                                Text(mentions)
                                    .typeSmallMeta()
                                    .foregroundStyle(Palette.textMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Palette.surface, in: RoundedRectangle(
                            cornerRadius: Metrics.radiusThumb, style: .continuous
                        ))
                    }
                    .buttonStyle(.press)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }
}
