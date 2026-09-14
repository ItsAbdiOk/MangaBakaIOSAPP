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
    let onOpen: (PublisherRecord) -> Void

    @State private var query = ""
    @State private var search: PublisherSearch

    init(catalogue: CatalogueService, onOpen: @escaping (PublisherRecord) -> Void) {
        self.onOpen = onOpen
        _search = State(initialValue: PublisherSearch(catalogue: catalogue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Publishers")

            InlineSearchField(prompt: "Find a publisher", text: $query)
                .padding(.horizontal, Metrics.gutter)
                .onChange(of: query) { _, new in search.update(query: new) }

            if search.isSearching {
                ProgressView()
                    .tint(Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if search.didFail {
                Text("Could not search publishers just now.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, Metrics.gutter)
            } else if search.hasSearched && search.results.isEmpty {
                Text("No publisher by that name.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(search.results) { publisher in
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
        .buttonStyle(.press)
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
        if publisher.closed != nil { parts.append("closed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The publisher field's debounce and its answer, out of the view so the
/// spinner's lifecycle can be tested — the same split `TagSearch` has.
///
/// Debounced, because this is a request per keystroke otherwise and the
/// rate limit is shared with strangers on the same network.
@MainActor
@Observable
final class PublisherSearch {
    private(set) var results: [PublisherRecord] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var didFail = false

    /// A function rather than the service, so the debounce and the
    /// cancellation path can be driven without a network.
    private let search: (String) async -> [PublisherRecord]?
    private var pending: Task<Void, Never>?
    /// Bumped by every request that goes out. A request answering after a
    /// newer one started must not touch the spinner that newer one owns.
    private var requestGeneration = 0

    /// How long typing settles before a request goes out. 350 ms arrived
    /// undated and underived (a guess), matching `FilterPanel.countDebounce`.
    static let debounce: Duration = .milliseconds(350)

    /// What the debounce sleeps against. Injected so a test can move time
    /// rather than sleep through it.
    ///
    /// Spelled with its module because this one does not: `MangaBaka` has its
    /// own `Clock` protocol (`Core/Persistence/Clock.swift`).
    nonisolated let clock: any _Concurrency.Clock<Duration>

    init(catalogue: CatalogueService, clock: any _Concurrency.Clock<Duration> = ContinuousClock()) {
        self.search = { await catalogue.searchPublishers($0) }
        self.clock = clock
    }

    init(
        search: @escaping (String) async -> [PublisherRecord]?,
        clock: any _Concurrency.Clock<Duration> = ContinuousClock()
    ) {
        self.search = search
        self.clock = clock
    }

    func update(query: String) {
        pending?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count > 1 else {
            results = []
            hasSearched = false
            didFail = false
            // The task cancelled above may have had a request in the air and
            // the spinner up. It returns at its own cancellation guard without
            // touching `isSearching`, and nothing else on this branch did
            // either: type "se", wait for the request, delete to "s" — spinner
            // forever (screens F14, 2026-09-14). Nothing is searching now.
            isSearching = false
            return
        }
        pending = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            isSearching = true
            requestGeneration += 1
            let mine = requestGeneration
            let found = await search(text)
            // Reset before the cancellation guard, but only by the request
            // that still owns the spinner: a keystroke mid-flight cancels this
            // task and lets its continuation run on. Resetting unconditionally
            // here cleared the spinner under the replacement's request (item
            // 48); not resetting at all left it up when the replacement never
            // searched (F14). A newer request resets it when it lands.
            if mine == requestGeneration { isSearching = false }
            // The cancelled answer is for text the reader no longer has: it
            // used to write `didFail = true, results = []` — "Could not search
            // publishers just now." flashing between letters (item 48).
            guard !Task.isCancelled else { return }
            hasSearched = true
            // A failure is said, not shown as "no publisher by that name".
            didFail = found == nil
            results = found ?? []
        }
    }
}
