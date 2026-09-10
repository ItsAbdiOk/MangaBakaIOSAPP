import SwiftUI

/// A series' covers, full screen, one swipe apart.
///
/// Cover art is the reason half of these series get picked up, and the page
/// shows it at 126pt. This is the same artwork at the size it was drawn for.
struct CoverGallery: View {
    let series: Series
    let images: [SeriesImage]
    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    init(series: Series, frontCover: Cover, images: [SeriesImage], startAt: Int = 0) {
        self.series = series
        self.frontCover = frontCover
        self.images = images
        _selection = State(initialValue: startAt)
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

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    ZoomableCover(cover: page.cover, title: series.displayTitle)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))
            .background(Palette.ground)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(caption)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// "Vol. 3 · EN", or the count when the cover has nothing to say about
    /// itself. Never "1 of 1" — a gallery of one has nothing to count.
    private var caption: String {
        if let own = pages[safe: selection]?.caption { return own }
        guard pages.count > 1 else { return "Cover" }
        return "\(selection + 1) of \(pages.count)"
    }
}

/// One cover, pinch and double-tap to zoom.
private struct ZoomableCover: View {
    let cover: Cover
    let title: String?

    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            AsyncImage(
                url: cover.url(forHeight: proxy.size.height, scale: displayScale)
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
            .frame(width: proxy.size.width, height: proxy.size.height)
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
        .accessibilityLabel(title.map { "Cover art for \($0)" } ?? "Cover art")
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
