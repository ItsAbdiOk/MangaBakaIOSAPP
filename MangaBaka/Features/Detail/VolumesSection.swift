import SwiftUI

/// The volumes a series has actually been published in.
///
/// A row of spines, because that is how a collection is looked at. Each one
/// carries its number and the year it arrived, and opens a sheet with the
/// things you would want before buying: what it costs, how long it is, its
/// ISBN, and where the publisher sells it.
///
/// **Editions are gathered, not listed.** Solo Leveling volume 1 exists twice
/// in the API — paperback at $9.99 and hardcover at $20, told apart only by
/// their ISBNs. Twenty-five entries for thirteen volumes reads as a bug; the
/// grouping happens in `SeriesWork.volumes(from:)` and the sheet is where the
/// two editions become visible, which is where the difference matters.
struct VolumesSection: View {
    let volumes: [SeriesWork.Volume]
    /// The series' own cover, dimmed in as a stand-in for a volume with no
    /// artwork of its own — see `MissingVolumeCover`.
    var seriesCover: Cover = .empty
    /// Why this is MangaBaka's shelf rather than the store's, when there is
    /// a reason worth saying: "Apple Books couldn't be reached". A failure
    /// shown as silence looks like the feature does not exist — gap 21: with
    /// no volumes here either, this used to be the whole section's only
    /// reason to exist, and it was dropped exactly when it was needed most.
    var note: String?
    /// A store is still being asked, so the final shape (its shelf, or this
    /// one with `note`) is not decided yet. Shown as a skeleton rather than
    /// letting MangaBaka's own shelf flash on screen and then be replaced —
    /// gap 22, "shelf swaps content under the reader".
    var isCheckingStore: Bool = false
    /// Covers `OpenLibraryCovers` found for a volume with none of its own,
    /// keyed by volume number — see `isbnsNeedingCovers` and
    /// `SeriesDetailView+Store.loadOpenLibraryCovers`. Empty for a page that
    /// has not run that pass yet, or found nothing.
    var openLibraryCovers: [Int: URL] = [:]
    /// Whether the `OpenLibraryCovers` gap-fill pass has been asked at all
    /// this page load, still out, or done — section-wide, not per volume,
    /// because `loadOpenLibraryCovers` is one batched pass that finishes for
    /// every ISBN it was given at once, never volume by volume. Drives
    /// `MissingVolumeCover.caption` so "No cover from the publisher" is only
    /// ever said once that pass has actually had its say.
    var openLibraryStatus: MissingVolumeCover.SourceState = .notAsked

    @State private var opened: SeriesWork.Volume?

    /// Whether there is anything worth a "Volumes" header for: real volumes,
    /// a reason there are none from the store, or a check still running.
    /// Zero volumes and no note is the one case with nothing to say.
    nonisolated static func shows(
        volumes: [SeriesWork.Volume], note: String?, isCheckingStore: Bool = false
    ) -> Bool {
        isCheckingStore || !volumes.isEmpty || note != nil
    }

    var body: some View {
        if Self.shows(volumes: volumes, note: note, isCheckingStore: isCheckingStore) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Volumes")
                        .typeDetailSectionHeader()
                        .foregroundStyle(Palette.textPrimary)
                    if !volumes.isEmpty {
                        Text("\(volumes.count)")
                            .typeChip()
                            .foregroundStyle(Palette.textMuted)
                    }
                    Spacer(minLength: 0)
                    if isCheckingStore {
                        Text("Checking Apple Books…")
                            .typeGridMeta()
                            .foregroundStyle(Palette.textMuted)
                    } else if let note {
                        Text(note)
                            .typeGridMeta()
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                .padding(.horizontal, Metrics.gutter)

                if isCheckingStore {
                    CoverSkeletonRow(count: 3, width: Metrics.coverSeedWidth)
                        .transition(.blurReplace)
                } else if !volumes.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Metrics.gapCovers) {
                            ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                                Button { opened = volume } label: {
                                    spine(volume)
                                }
                                .buttonStyle(.press(haptic: .selection))
                                .arrives(index: index)
                                .enterScale()
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }
                    .scrollIndicators(.hidden)
                    .transition(.blurReplace)
                }
                // Zero volumes, not checking, and a note: the header alone
                // says why (gap 21) — no empty row of spines to draw.
            }
            // The skeleton and the real shelf swap under this one animation
            // rather than popping: "Checking Apple Books…" is itself content
            // (gap 22, see `isCheckingStore`'s doc comment), so its own exit
            // deserves the same care its arrival got.
            .animation(Motion.reduced(Motion.settle), value: isCheckingStore)
            .sheet(item: $opened) { volume in
                VolumeSheet(volume: volume)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(Metrics.radiusSheet)
            }
        }
    }

    private func spine(_ volume: SeriesWork.Volume) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            volumeCover(volume)
            Text(volume.label)
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
            if let year = volume.date.map(Self.spineYear(for:)) {
                Text(String(year))
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(width: Metrics.coverSeedWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(volume))
        .accessibilityAddTraits(.isButton)
    }

    /// The volume's own artwork, or an Open Library fill for it, when there
    /// is one — but never a fill for a volume that already has art.
    private func resolvedCover(_ volume: SeriesWork.Volume) -> Cover? {
        if let own = volume.cover { return own }
        guard let number = volume.number.flatMap(Int.init), let url = openLibraryCovers[number] else {
            return nil
        }
        return Cover(raw: url, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil)
    }

    @ViewBuilder
    private func volumeCover(_ volume: SeriesWork.Volume) -> some View {
        switch MissingVolumeCover.choice(for: resolvedCover(volume)) {
        case let .artwork(cover):
            CoverImage(
                cover: cover, width: Metrics.coverSeedWidth, radius: Metrics.radiusSeed,
                accessibilityText: volume.label
            )
        case .seriesCover:
            MissingVolumeCover(
                seriesCover: seriesCover, width: Metrics.coverSeedWidth,
                // `.answered`: this spine is only ever drawn once
                // `isCheckingStore` has gone false, which only happens after
                // Apple's own shelf has already come back (empty, or this
                // screen would be showing `AppleVolumesRow` instead).
                apple: .answered, openLibrary: openLibraryStatus, numberLabel: volume.number ?? ""
            )
        }
    }

    /// The ISBN of every volume in `volumes` that has no cover of its own —
    /// the set worth asking `OpenLibraryCovers` about. A volume without an
    /// ISBN (no edition carries one) is simply left out: there is nothing to
    /// ask Open Library for.
    ///
    /// Numberless volumes ("Other editions") are excluded too — there is no
    /// single volume number to key a found cover back to on the shelf.
    nonisolated static func isbnsNeedingCovers(_ volumes: [SeriesWork.Volume]) -> [Int: String] {
        var isbnsByNumber: [Int: String] = [:]
        for volume in volumes where volume.cover == nil {
            guard let number = volume.number.flatMap(Int.init),
                  let isbn = volume.editions.compactMap(\.isbn).first
            else { continue }
            isbnsByNumber[number] = isbn
        }
        return isbnsByNumber
    }

    /// The volume's release year, read in UTC.
    ///
    /// `SeriesWork.date` parses a release date ("2021-01-01") as UTC
    /// midnight for exactly this reason — reading it back with the
    /// device's own zone rolls a 1 January release onto 31 December of the
    /// previous year for every reader west of UTC (S2, 2026-09-13).
    /// Release dates are UTC midnight on the wire, so the style carries the
    /// zone rather than the device's — `.timeZone(.gmt)` is a *symbol* that
    /// prints the zone, not a setting; the zone is set on the style itself.
    nonisolated static var utcMonthYear: Date.FormatStyle {
        Date.FormatStyle(timeZone: .gmt).month(.wide).year()
    }

    nonisolated static var utcDayMonthYear: Date.FormatStyle {
        Date.FormatStyle(timeZone: .gmt).day().month(.wide).year()
    }

    nonisolated static func spineYear(for date: Date) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return utc.component(.year, from: date)
    }

    private func accessibilityLabel(_ volume: SeriesWork.Volume) -> String {
        var parts = [volume.label]
        if case .seriesCover = MissingVolumeCover.choice(for: resolvedCover(volume)) {
            // The spine's own `.accessibilityElement(children: .ignore)`
            // means `MissingVolumeCover`'s label is never read — this is the
            // one place a VoiceOver user is told the box is a stand-in
            // rather than the volume's own art. Says the same thing the
            // caption on screen does, so a sighted and a VoiceOver reader
            // are told the identical story — "cover not available" alone
            // when there's nothing more specific to say yet.
            parts.append(
                MissingVolumeCover.accessibilityText(apple: .answered, openLibrary: openLibraryStatus)
            )
        }
        if let date = volume.date {
            parts.append(date.formatted(Self.utcMonthYear))
        }
        if volume.editions.count > 1 {
            parts.append("\(volume.editions.count) editions")
        }
        return parts.joined(separator: ", ")
    }
}

/// A volume's cover, or a stand-in when nothing — not Apple, not Google, not
/// MangaBaka's own images, not Open Library — has one.
///
/// The series' own cover, dimmed, with the volume number over it, in place
/// of a blank grey box. A grey box reads as broken; a dimmed familiar cover
/// reads as "this one just doesn't have its own picture yet". Shared between
/// `VolumesSection` (MangaBaka's own volumes) and `AppleVolumesRow` (the
/// store shelf) so the two never drift into two different "missing" looks.
struct MissingVolumeCover: View {
    let seriesCover: Cover
    var width: CGFloat = Metrics.coverSeedWidth
    var radius: CGFloat = Metrics.radiusSeed
    /// Where Apple's shelf stands for this volume. Both call sites only ever
    /// reach `MissingVolumeCover` after Apple has already answered — a
    /// `VolumesSection` spine because Apple's own shelf came back empty, an
    /// `AppleVolumesRow` spine because Apple answered but sent no art for
    /// this one number — so `.answered` is the only value either passes
    /// today. Kept as a parameter, not hard-coded, so `caption(apple:
    /// openLibrary:)` reads the same rule `AppleVolumesRow`'s own future
    /// loading state (if it ever gets one) would need.
    var apple: SourceState = .answered
    /// Where the `OpenLibraryCovers` gap-fill pass stands for this volume —
    /// see `SeriesDetailView+Store.loadOpenLibraryCovers`, which runs once
    /// for every ISBN a screen still needs and only ever finishes as a whole
    /// pass, not volume by volume.
    var openLibrary: SourceState = .notAsked

    /// What to draw for a volume's artwork slot: its own cover, when it has
    /// one, or the series' cover as a stand-in.
    enum Choice: Equatable {
        case artwork(Cover)
        case seriesCover
    }

    /// One source's standing on a volume's cover. Reaching `MissingVolumeCover`
    /// at all already means no cover was found — the only open question is
    /// why: nobody has looked (`.notAsked`), someone is still looking
    /// (`.loading`), or every source that could have one has already said no
    /// (`.answered`).
    enum SourceState: Equatable {
        case notAsked
        case loading
        case answered
    }

    /// `nonisolated static` so `VolumesSectionTests`/`AppleVolumesRowTests`-
    /// style suites can call it directly, off the main actor, the way
    /// `VolumesSection.shows` already is.
    nonisolated static func choice(for artwork: Cover?) -> Choice {
        artwork.map(Choice.artwork) ?? .seriesCover
    }

    /// The line under the dimmed placeholder, when there is one worth
    /// saying. A blank box with no explanation reads as the app being
    /// broken (the actual bug report: The Beginning After the End, Yen
    /// Press — no Apple Books listing, no Open Library ISBN cover) — but
    /// saying so before both sources have actually answered would be a
    /// caption a moment later proves wrong, so a source still `.loading`
    /// (or never asked at all) says nothing rather than guess.
    nonisolated static func caption(apple: SourceState, openLibrary: SourceState) -> String? {
        guard apple == .answered, openLibrary == .answered else { return nil }
        return "No cover from the publisher"
    }

    /// What a VoiceOver reader is told in place of the on-screen caption —
    /// the same words when there is a caption to say, and the older, more
    /// general "cover not available" the rest of the time, so a reader who
    /// cannot see the box is still told there is no cover at all even
    /// before both sources have finished answering. Both call sites'
    /// accessibility labels go through this one function so the spoken text
    /// can never drift from `caption(apple:openLibrary:)`.
    nonisolated static func accessibilityText(apple: SourceState, openLibrary: SourceState) -> String {
        caption(apple: apple, openLibrary: openLibrary) ?? "cover not available"
    }

    private var isLoading: Bool { apple == .loading || openLibrary == .loading }

    private var caption: String? { Self.caption(apple: apple, openLibrary: openLibrary) }

    var body: some View {
        if isLoading {
            // A plain skeleton, not the dimmed series cover: showing the
            // stand-in before a source has actually finished answering
            // would flash "no cover" content that a moment later might be
            // replaced by real art, the same swap `VolumesSection`'s own
            // `isCheckingStore` skeleton exists to avoid at the row level.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Palette.imagePlaceholder)
                .frame(width: width, height: width / Metrics.coverAspect)
                .shimmering()
                .accessibilityHidden(true)
        } else {
            CoverImage(
                cover: seriesCover, width: width, radius: radius, accessibilityText: "Cover not available"
            )
                // A GUESS: dim enough to read as a stand-in rather than the
                // volume's actual art, not so dim the series is unrecognisable.
                .opacity(0.35)
                .overlay(alignment: .bottomLeading) {
                    Text(numberLabel)
                        .typeCardTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(6)
                        // The caller's own accessibility element (both call
                        // sites wrap the whole spine in one) already speaks
                        // "cover not available" — this would only repeat it.
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .bottom) {
                    if let caption {
                        Text(caption)
                            .typeFootnote()
                            .foregroundStyle(Palette.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                            // Same reasoning as the number label above: the
                            // spine's own accessibility element speaks this
                            // text already, via `caption(apple:openLibrary:)`.
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    /// Set by the caller so this view stays store-agnostic — `VolumesSection`
    /// has "Vol. 2"-style labels, `AppleVolumesRow` bare numbers.
    var numberLabel: String = ""
}

/// One volume, and the editions of it.
struct VolumeSheet: View {
    let volume: SeriesWork.Volume

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Bumped per ISBN copy, for the haptic; see `Haptics`.
    @State private var copies = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ForEach(volume.editions) { edition in
                        editionCard(edition, label: volume.editionLabels[edition.id])
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Palette.ground)
            .navigationTitle(volume.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(
                cover: volume.cover ?? Cover.empty,
                width: Metrics.coverSeedWidth,
                radius: Metrics.radiusSeed,
                accessibilityText: volume.label
            )
            VStack(alignment: .leading, spacing: 6) {
                if let subTitle = volume.subTitle {
                    Text(subTitle)
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let date = volume.date {
                    // `.timeZone(.gmt)`: `date` is UTC midnight (S2) — the
                    // device zone would print 31 December for a 1 January
                    // release west of UTC.
                    Text(date.formatted(VolumesSection.utcDayMonthYear))
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                if let pages = volume.pages {
                    Text("\(pages.formatted()) pages")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One edition. The ISBN is shown because it is the only thing that tells
    /// a paperback from a hardcover when the covers and titles are identical —
    /// and because it is what a reader takes to a bookshop.
    ///
    /// `label` comes from `SeriesWork.Volume.editionLabels`: without a price,
    /// it replaces the repeated "Price not listed" headline (three identical
    /// cards for Hunter x Hunter vol. 8 was the bug report); with a price,
    /// it sits on the meta line instead so the price still leads.
    /// The price when there is one; otherwise the label that tells this
    /// edition from its siblings, so three cards never read the same.
    private func headline(_ edition: SeriesWork, label: String?) -> some View {
        Text(edition.price ?? label ?? "Price not listed")
            .typeDetailSectionHeader()
            .foregroundStyle(edition.price == nil ? Palette.textMuted : Palette.textPrimary)
    }

    private func editionCard(_ edition: SeriesWork, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                headline(edition, label: label)
                Spacer(minLength: 8)
                if let pages = edition.pages {
                    Text("\(pages.formatted()) pp")
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            if edition.price != nil, let label {
                Text(label)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }

            if let isbn = edition.isbn {
                Button {
                    UIPasteboard.general.string = isbn
                    copies += 1
                } label: {
                    HStack(spacing: 6) {
                        Text("ISBN \(isbn)")
                            .typeGridMeta()
                            .foregroundStyle(Palette.textMuted)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.textMuted)
                    }
                    .frame(minHeight: Metrics.tapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .haptic(Haptics.copied, onEach: copies)
                .accessibilityLabel("ISBN \(isbn)")
                .accessibilityHint("Copies the ISBN")
            }

            if let link = edition.buyLink {
                Button { openURL(link) } label: {
                    HStack(spacing: 6) {
                        Text("Buy from the publisher")
                            .typeCTA()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Metrics.tapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityHint("Opens the publisher's page in the browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
    }
}
