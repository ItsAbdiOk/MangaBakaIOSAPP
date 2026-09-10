import SwiftUI

/// A series' covers, full screen, one swipe apart.
///
/// Cover art is the reason half of these series get picked up, and the page
/// shows it at 126pt. This is the same artwork at the size it was drawn for.
struct CoverGallery: View {
    let series: Series
    let images: [SeriesImage]
    @State private var selection: Int
    @State private var scrolledIndex: Int?
    @Environment(\.dismiss) private var dismiss

    init(series: Series, frontCover: Cover, images: [SeriesImage], startAt: Int = 0) {
        self.series = series
        self.frontCover = frontCover
        self.images = images
        _selection = State(initialValue: startAt)
        _scrolledIndex = State(initialValue: startAt)
        _progress = State(initialValue: Double(startAt))
    }

    let frontCover: Cover

    /// The cover shown on the page leads, then every other cover it has.
    ///
    /// Modelled as a caption plus a `Cover` rather than as `[SeriesImage]`
    /// because the first entry is not one — it comes from the series itself and
    /// has no volume, language or id of its own.
    private var pages: [(caption: String?, cover: Cover)] {
        [(nil, frontCover)] + images.map { ($0.caption, $0.image) }
    }

    /// Fractional page position, so the background can follow the drag rather
    /// than snap when the page changes.
    @State private var progress: Double = 0

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                pager
            }
            .background(Palette.ground)
            // The whole screen, not the space under the navigation bar.
            //
            // Ignoring only the bottom edge left the cover centred inside a
            // frame that started below the bar and ran past the home
            // indicator — so its middle sat about seventy points below the
            // screen's, which reads as the card having slipped downwards. The
            // bar floats over the artwork instead, which is what it is for.
            .ignoresSafeArea()
            .navigationTitle(caption)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// A paged scroll view rather than a `TabView`.
    ///
    /// `TabView` gives no access to where the drag has got to, so the only
    /// thing it can drive is a change of page — and a background that changes
    /// on a page boundary is a slideshow. A scroll view reports its offset
    /// continuously, which is what lets the light behind the cards move with
    /// the reader's thumb.
    private var pager: some View {
        GeometryReader { outer in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        ZoomableCover(cover: page.cover, title: series.displayTitle)
                            .frame(width: outer.size.width, height: outer.size.height)
                            .id(index)
                            // The glide: a card settles as it reaches the
                            // middle and leans back as it leaves, so the stack
                            // reads as objects moving over a surface rather
                            // than as pictures being swapped.
                            .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                                view
                                    .scaleEffect(1 - abs(phase.value) * 0.10)
                                    .opacity(1 - abs(phase.value) * 0.35)
                                    .rotation3DEffect(
                                        .degrees(phase.value * -14),
                                        axis: (x: 0, y: 1, z: 0),
                                        perspective: 0.5
                                    )
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrolledIndex)
            .onScrollGeometryChange(for: Double.self) { geometry in
                guard outer.size.width > 0 else { return 0 }
                return geometry.contentOffset.x / outer.size.width
            } action: { _, position in
                progress = position
            }
        }
    }

    /// The light behind the cards.
    ///
    /// Two washes, the covers on either side of the drag, blended by how far
    /// through the drag the reader is. Nothing switches at a page boundary:
    /// halfway between two covers the background is halfway between their
    /// colours, which is what makes it read as one lit surface the cards are
    /// sliding over rather than a picture behind each one.
    private var backdrop: some View {
        let lower = Int(progress.rounded(.down))
        let upper = lower + 1
        let blend = progress - Double(lower)

        return ZStack {
            if let cover = pages[safe: lower]?.cover {
                DetailBackdrop(cover: cover, height: 1000)
                    .opacity(1 - blend)
            }
            if let cover = pages[safe: upper]?.cover {
                DetailBackdrop(cover: cover, height: 1000)
                    .opacity(blend)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// "Vol. 3 · EN", or the count when the cover has nothing to say about
    /// itself. Never "1 of 1" — a gallery of one has nothing to count.
    private var caption: String {
        let index = scrolledIndex ?? selection
        if let own = pages[safe: index]?.caption { return own }
        guard pages.count > 1 else { return "Cover" }
        return "\(index + 1) of \(pages.count)"
    }
}

/// One cover, inset and rounded, floating on a wash of itself.
///
/// Edge to edge, the artwork ran into the bezel and the corners fought the
/// screen's own radius. Inset with a glass rim it reads as the object it is —
/// a book cover. The wash behind it belongs to the gallery, not to this view —
/// see `backdrop`.
private struct ZoomableCover: View {
    let cover: Cover
    let title: String?

    /// Enough that the artwork clearly stops before the screen does. Less and
    /// it reads as a rendering mistake rather than a margin.
    private static let inset: CGFloat = 26
    private static let radius: CGFloat = 24

    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: proxy.size.width - Self.inset * 2,
                height: proxy.size.height - Self.inset * 2
            )
            card(fitting: available)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityLabel(title.map { "Cover art for \($0)" } ?? "Cover art")
    }

    /// The card is sized to the artwork, not to the space around it.
    ///
    /// `scaledToFit` inside a larger frame leaves the frame the size it was, so
    /// the rounded rim and the shadow were drawn around the available area and
    /// floated above and below the image. Here the fitted size is worked out
    /// first, from the cover's own reported ratio, and the frame is that.
    ///
    /// Per-cover ratio is right here and wrong in a row: a grid of covers at
    /// their own ratios comes out ragged, which is why `CoverImage` fixes 2:3 —
    /// but there is only one cover on this screen and cropping it would be
    /// showing the reader less of the thing they tapped to see.
    private func fitted(in available: CGSize) -> CGSize {
        let ratio = cover.aspectRatio ?? Double(Metrics.coverAspect)
        guard ratio > 0 else { return available }
        let byWidth = CGSize(width: available.width, height: available.width / ratio)
        return byWidth.height <= available.height
            ? byWidth
            : CGSize(width: available.height * ratio, height: available.height)
    }

    private func card(fitting available: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let size = fitted(in: available)
        return AsyncImage(
            url: cover.url(forHeight: available.height, scale: displayScale)
        ) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFit()
            case .failure:
                Image(systemName: "photo")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.textQuaternary)
            default:
                ProgressView().tint(Palette.textQuaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // The rim is what makes it read as glass rather than as a cropped
        // image: a bright hairline along the top edge falling to nothing at the
        // bottom, which is how a lit pane of glass actually catches light.
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.45),
                        .white.opacity(0.10),
                        .white.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
        }
        .shadow(color: .black.opacity(0.6), radius: 30, y: 18)
        .scaleEffect(scale)
        .gesture(
            MagnifyGesture()
                .onChanged { scale = max(1, committed * $0.magnification) }
                .onEnded { _ in committed = scale }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy(duration: 0.25)) {
                scale = scale > 1 ? 1 : 2.5
                committed = scale
            }
        }
    }
}

/// The hero cover, with the series' other covers fanned out behind it.
///
/// The fan is the point: a series with twenty-four volume covers looked exactly
/// like one with a single cover, so nobody would ever have found them. Two
/// cards leaning out to the right say "there is more here" without a label
/// explaining it.
struct CoverStack: View {
    let series: Series
    /// What sits on top. Not always `series.cover` — see `preferredCover`.
    let frontCover: Cover
    let extraCovers: [SeriesImage]
    let width: CGFloat
    let onOpen: (Int) -> Void

    /// Two, however many there are. A third adds no information and starts
    /// eating the space the title needs.
    private var peeking: [SeriesImage] { Array(extraCovers.prefix(2)) }

    private var height: CGFloat { width / Metrics.coverAspect }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(peeking.enumerated().reversed()), id: \.element.id) { index, image in
                let step = CGFloat(index + 1)
                Button { onOpen(index + 1) } label: {
                    CoverImage(cover: image.image, width: width, radius: 14)
                        // Dimmed and slightly small, so the front cover stays
                        // the one being looked at.
                        .brightness(-0.12 * step)
                        .scaleEffect(1 - 0.04 * step)
                }
                .buttonStyle(.plain)
                .offset(x: 13 * step, y: 5 * step)
                .rotationEffect(.degrees(2.2 * Double(step)), anchor: .bottomLeading)
                .accessibilityLabel("Another cover for this series")
                .accessibilityHint("Opens the covers")
            }

            Button { onOpen(0) } label: {
                CoverImage(cover: frontCover, width: width, radius: 14)
                    .shadow(color: .black.opacity(0.65), radius: 20, y: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(series.displayTitle.map { "Cover art for \($0)" } ?? "Cover art")
            .accessibilityHint("Opens it full screen")
        }
        // The fan leans right and down, so the frame has to make room for it or
        // the leaning cards are clipped by whatever is beside them.
        .frame(
            width: width + (peeking.isEmpty ? 0 : 13 * CGFloat(peeking.count) + 6),
            height: height + (peeking.isEmpty ? 0 : 5 * CGFloat(peeking.count)),
            alignment: .topLeading
        )
    }
}

extension Collection {
    /// Bounds-checked access, for indices that come from view state rather than
    /// from the collection itself — a page index outlives the page count when a
    /// filter changes underneath it.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// An `Int` that can drive `fullScreenCover(item:)`.
///
/// A bare index cannot: `Identifiable` on `Int` would make every equal index
/// the same identity, so opening the gallery at cover 0 twice in a row would
/// not reopen it.
struct GalleryStart: Identifiable, Equatable {
    let value: Int
    var id: String { "cover-\(value)" }
}
