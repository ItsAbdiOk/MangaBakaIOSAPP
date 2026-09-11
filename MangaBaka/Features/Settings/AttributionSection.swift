import SwiftUI

/// Credit for the data, which is a licence term rather than a courtesy.
///
/// MangaBaka's Data License §6.5, read on 2026-09-10:
/// *"Applications, websites, or services that display data obtained from the
/// MangaBaka API or database downloads must include a visible attribution to
/// MangaBaka."* Their API page accepts a link in a footer, a README, an About
/// page, or beside the series itself.
///
/// Two obligations, not one: MangaBaka, **and** the provider each piece of
/// third-party data came from, per that provider's own rules. The second one
/// belongs on the series page's tracker row, where the third-party data
/// actually is — that is a change to the detail screen and it has not been made
/// yet.
///
/// The link is the part that satisfies the licence. Plain text naming them does
/// not. Do not reduce this to a sentence.
struct AttributionSection: View {
    /// Their site, not the API host. The licence asks for somewhere a reader
    /// can go, and `api.mangabaka.org` is not that.
    private static let home = URL(string: "https://mangabaka.org")

    var body: some View {
        SettingsSection(title: "Data and credit", caption: nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                Series data comes from MangaBaka, and through it from AniList, \
                Kitsu, MangaUpdates, MyAnimeList and Anime-Planet.
                """)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                if let home = Self.home {
                    Link(destination: home) {
                        HStack(spacing: 5) {
                            Text("mangabaka.org")
                                .typeCTA()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Palette.accent)
                    }
                    .accessibilityLabel("Open mangabaka.org")
                }

                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 0.5)

                Text("""
                Licensed CC BY-NC-SA 4.0 — free for personal, non-commercial \
                use with attribution. This app is free and carries no ads or \
                purchases.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
