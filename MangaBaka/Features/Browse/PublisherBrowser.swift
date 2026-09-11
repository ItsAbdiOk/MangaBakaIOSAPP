import SwiftUI

/// Publishers as a way in.
///
/// "Everything Seven Seas licenses" is a real question and the API answers it —
/// `publisher=Seven Seas` returns 1,265 of 304,096, and a name it does not know
/// returns nothing rather than being ignored, checked live on 2026-09-10.
///
/// It is a search rather than a list because `/v1/publishers` itself answers
/// with a 503 database error, while `/v1/publishers/search?q=` works. Their
/// bug, not one to design around: a browsable A-Z of publishers would need the
/// endpoint that is down.
struct PublisherBrowser: View {
    let catalogue: CatalogueService
    let onOpen: (PublisherRecord) -> Void

    @State private var query = ""
    @State private var results: [PublisherRecord] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var didFail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Publishers")

            InlineSearchField(prompt: "Find a publisher", text: $query)
                .padding(.horizontal, Metrics.gutter)
                .onChange(of: query) { _, _ in schedule() }

            if isSearching {
                ProgressView()
                    .tint(Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if didFail {
                Text("Could not search publishers just now.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, Metrics.gutter)
            } else if hasSearched && results.isEmpty {
                Text("No publisher by that name.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(results) { publisher in
                        chip(publisher)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
        }
    }

    private func chip(_ publisher: PublisherRecord) -> some View {
        Button { onOpen(publisher) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(publisher.name)
                    .typeChip()
                    .foregroundStyle(Palette.textPrimary)
                if let note = note(publisher) {
                    Text(note)
                        .typeFootnote()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Palette.surfaceChip, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Everything from \(publisher.name)")
    }

    /// "Imprint · closed 2019", and only what the API said.
    ///
    /// Whether a publisher has shut down matters here more than it looks: a
    /// reader who picks one and gets nothing newer than 2019 should have been
    /// told why before they tapped.
    private func note(_ publisher: PublisherRecord) -> String? {
        var parts: [String] = []
        if let type = publisher.type, type != "publisher" { parts.append(type.capitalized) }
        if publisher.closed == true { parts.append("closed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Debounced, because this is a request per keystroke otherwise and the
    /// rate limit is shared with strangers on the same network.
    @State private var pending: Task<Void, Never>?

    private func schedule() {
        pending?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count > 1 else {
            results = []
            hasSearched = false
            didFail = false
            return
        }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await catalogue.searchPublishers(text)
            isSearching = false
            hasSearched = true
            // A failure is said, not shown as "no publisher by that name".
            didFail = found == nil
            results = found ?? []
        }
    }
}
