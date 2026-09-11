import SwiftUI

/// Where the series can actually be read.
///
/// Opens in the browser rather than an in-app view: these are third-party
/// sites, and framing someone else's page inside the app misrepresents whose
/// it is.
struct LinksSection: View {
    let links: [SeriesLink]

    @Environment(\.openURL) private var openURL

    private var readable: [SeriesLink] {
        Array(links.filter { $0.safeURL != nil }.prefix(6))
    }

    var body: some View {
        if !readable.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Read it")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)

                VStack(spacing: 0) {
                    ForEach(readable) { link in
                        row(link)
                        if link.id != readable.last?.id {
                            Rectangle()
                                .fill(Palette.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(Palette.surface, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusCard, style: .continuous
                ))
                .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            }
            .padding(.horizontal, Metrics.gutter)
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
                    Text(language.uppercased())
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.ctaSecondary)
        }
        .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }
}
