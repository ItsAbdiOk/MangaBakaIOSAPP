import SwiftUI

/// Discover, built out of Apple's components rather than around them.
///
/// The app's own version draws its title inside a `ScrollView` with a flat
/// 24pt padding and no navigation bar. That is why it needed a hand-built
/// scroll edge, and why "Discover" does not shrink as you scroll, and why the
/// title cannot be tapped to return to the top.
///
/// This one asks for `.navigationTitle` and gets all three for nothing — plus
/// whatever Apple does to large titles next, without anyone here rewriting
/// anything. That is the whole argument of the experiment, in one modifier.
struct AppleDiscoverView: View {
    @State private var model: DiscoverModel
    @Binding private var path: [Series]

    init(model: DiscoverModel, path: Binding<[Series]>) {
        _model = State(initialValue: model)
        _path = path
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                ForEach(model.rows) { row in
                    section(row)
                }
            }
            .padding(.vertical, 8)
        }
        // A real large title: it shrinks on scroll, it carries the scroll edge
        // effect for free, and tapping the status bar returns to the top.
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground))
        .refreshable { await model.load(forceRefresh: true) }
        .task { await model.load() }
    }

    private func section(_ row: DiscoverModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // `Section`-style header type, taken from the system rather than
            // chosen: `.title2` is what Apple uses for a shelf heading in
            // Books and the App Store.
            Text(row.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(row.series) { series in
                        Button { path.append(series) } label: {
                            AppleCoverCard(series: series)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            // Apple's own paging for a shelf of cards. The app's version
            // free-scrolls; this snaps card to card, which is what Books does.
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}
