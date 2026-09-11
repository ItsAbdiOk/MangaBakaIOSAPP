import SwiftUI

/// A series page in Apple's idiom.
///
/// The differences worth looking at:
///
/// - The title is the navigation bar's, at `.large`. It scrolls away and the
///   inline copy fades in as it goes — the effect the shipping app now builds
///   by hand in `DetailBarTitle`, and which iOS has always provided.
/// - Statistics are a `LabeledContent` grid rather than a custom strip, so
///   they align the way every other iOS app's do and reflow at accessibility
///   sizes without a `ViewThatFits`.
/// - The synopsis uses `Text` with no line-height override, so it takes
///   Apple's own leading for the reader's chosen size.
struct AppleSeriesDetailView: View {
    let series: Series

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CoverImage(
                        cover: series.cover,
                        width: 96,
                        radius: 8,
                        accessibilityText: series.displayTitle ?? "Untitled series"
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        if let type = series.type?.capitalized {
                            Text(type)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(series.displayTitle ?? "Untitled series")
                            .font(.title3.weight(.semibold))
                        if let status = series.status?.capitalized {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let rating = series.rating {
                    LabeledContent("Rating", value: String(format: "%.1f", rating / 10))
                }
                if let chapters = series.totalChapters, chapters > 0 {
                    LabeledContent("Chapters", value: Int(chapters).formatted())
                }
                if let publisher = series.publishers?.first?.name {
                    LabeledContent("Publisher", value: publisher)
                }
            }

            if let description = series.description, !description.isEmpty {
                Section("Synopsis") {
                    Text(description)
                        .font(.body)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(series.displayTitle ?? "Series")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Label("Add to library", systemImage: "plus")
                }
            }
        }
    }
}
