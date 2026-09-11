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
                            .frame(height: Metrics.ctaSecondary)
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
                    if let flag = LanguageFlag.emoji(for: language) {
                        Text(flag)
                            .typeGridMeta()
                            .accessibilityHidden(true)
                    }
                    Text(language.uppercased())
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.ctaSecondary)
        }
        .buttonStyle(.press)
        .accessibilityHint("Opens \(link.title) in the browser")
    }
}

/// Recent news mentioning the series.
struct NewsSection: View {
    let items: [NewsItem]

    @Environment(\.openURL) private var openURL

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("News")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)

                ForEach(items.prefix(4)) { item in
                    Button {
                        if let url = item.safeURL { openURL(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .typeRowTitle()
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let date = item.publishedAt {
                                Text(date.formatted(.relative(presentation: .named)))
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
