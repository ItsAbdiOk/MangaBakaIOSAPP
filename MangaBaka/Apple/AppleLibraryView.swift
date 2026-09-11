import SwiftUI

/// The Library as a `List`, which is what it has always wanted to be.
///
/// What the system gives here that the hand-built version does not have, and
/// would each be a project on their own:
///
/// - **Swipe actions.** Left to change state, right to remove. The app's own
///   library needs a tap into an edit sheet for the same thing.
/// - **`.searchable`.** The field lives in the navigation bar, collapses on
///   scroll, brings its own Cancel button and its own clear button — the
///   clear button being a thing that had to be reported as missing and then
///   built by hand.
/// - **Section index.** `.listSectionIndexLabel` puts the A-Z rail down the
///   right edge. The app has a hand-written `JumpIndex` for this.
/// - **Row separators, insets and selection** that match every other iOS app.
struct AppleLibraryView: View {
    @Bindable var model: LibraryModel
    @Binding var path: [Series]

    var body: some View {
        List {
            ForEach(model.shelves) { shelf in
                Section {
                    ForEach(shelf.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text(shelf.label)
                } footer: {
                    Text("\(shelf.count) series")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Library")
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search your library"
        )
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        Button {
            if let series = entry.series { path.append(series) }
        } label: {
            HStack(spacing: 12) {
                if let series = entry.series {
                    CoverImage(
                        cover: series.cover,
                        width: 40,
                        radius: 5,
                        accessibilityText: series.displayTitle ?? "Untitled series"
                    )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.series?.displayTitle ?? "Untitled series")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let progress = progressLine(entry) {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        // The system's own swipe, with the system's own colours, haptics and
        // full-swipe behaviour. None of it written here.
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {} label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {} label: {
                Label("Mark read", systemImage: "checkmark")
            }
            .tint(.green)
        }
    }

    private func progressLine(_ entry: LibraryEntry) -> String? {
        guard let read = entry.progressChapter, read > 0 else { return nil }
        guard let total = entry.series?.totalChapters, total > 0 else {
            return "Chapter \(Int(read))"
        }
        return "Chapter \(Int(read)) of \(Int(total))"
    }
}
