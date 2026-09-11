import SwiftUI

/// "Read in English": the official platforms carrying the series in the
/// reader's language, one chip each, directly under the page's actions.
///
/// The links section further down lists everywhere the series lives, in every
/// language, grouped by kind — thirteen platforms on series 3397. That is the
/// reference. This is the shortcut: someone who opened the page to start
/// reading should not have to scroll past the synopsis and the cast to find
/// the four that are in their language.
///
/// Each chip opens MangaBaka's link for this exact title, through the system,
/// so a platform that registers universal links (Webtoons and Tapas do) opens
/// its app on the title when installed and Safari on the same page when not.
/// The link is the title's own page either way — there is no "open Webtoons"
/// that lands somewhere else. Not verified on a phone with Webtoons installed
/// yet; the simulator has no such app, so there it opens Safari.
///
/// Absent when nothing is carried in the reader's language: an empty heading
/// would be a claim about availability the data does not make.
struct ReadRow: View {
    let links: [SeriesLink]
    /// The reader's language, as a BCP 47 tag. Injectable for tests.
    var language: String = Locale.current.language.languageCode?.identifier ?? "en"

    @Environment(\.openURL) private var openURL

    var body: some View {
        let readable = SeriesLink.readable(links, in: language)
        if !readable.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(heading)
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.gapChips) {
                        ForEach(readable) { link in
                            chip(link)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// "Read in English". The language's name in the reader's own locale, so
    /// the heading reads naturally rather than as a code.
    private var heading: String {
        let code = SeriesLink.primarySubtag(language)
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "Read in \(name)"
    }

    private func chip(_ link: SeriesLink) -> some View {
        Button {
            if let url = link.safeURL { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Text(link.title)
                    .typeChip()
                    .lineLimit(1)
                if let cost = link.costNote {
                    Text(cost)
                        .typeGridMeta()
                        // Secondary, not muted: Apple's audit failed "Free"
                        // for contrast at this size over the chip's fill
                        // (2026-09-11 run).
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.headerPill + 8)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .accessibilityLabel([link.title, link.costNote].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens \(link.title), in its app if installed")
    }
}
