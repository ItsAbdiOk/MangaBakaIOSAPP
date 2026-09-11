import SwiftUI

/// Adding a series, setting its state, rating it and recording progress, from
/// the screen where the reader is actually looking at the series.
///
/// Every one of these existed already but only inside `LibraryEditSheet`, and
/// the only route to that sheet was Library → a shelf → a row. So a series
/// found through Discover, Search, the Stack or a Mix could be read about at
/// length and never added to anything. This is that route.
@MainActor
@Observable
final class LibraryControlModel {
    private let library: any LibraryProviding
    /// The app's one copy of the reader's library, shared with the Library tab.
    private let store: LibraryModel
    private let seriesId: Int

    /// Nil while unknown, `.some(nil)` once we know it is not in the library.
    private(set) var entry: LibraryEntry??
    private(set) var isWorking = false
    private(set) var failure: String?

    var isKnown: Bool { entry != nil }
    var current: LibraryEntry? { entry.flatMap { $0 } }

    init(library: any LibraryProviding, store: LibraryModel, seriesId: Int) {
        self.library = library
        self.store = store
        self.seriesId = seriesId
    }

    /// Looks the series up in the shared library rather than fetching its own.
    ///
    /// This used to ask for one page of 500 and treat the answer as the whole
    /// library. It is not: `/v1/my/series` is paged, which is why `LibraryModel`
    /// loops until a short page. On a 937-entry library the control therefore
    /// saw at most the first page and offered "Add to library" for series the
    /// reader was already reading — the write would then 409, having told them
    /// something false first.
    ///
    /// Sharing the store also means one paging pass per session instead of one
    /// per series page opened, against a rate limit shared with strangers.
    func load() async {
        guard entry == nil else { return }
        await store.load()
        entry = .some(store.entries.first { $0.seriesId == seriesId })
    }

    func add(state: LibraryEntry.State) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await library.add(seriesId: seriesId, state: state)
        } catch {
            failure = error.userFacingMessage
            return
        }
        failure = nil
        await refresh()
    }

    func apply(_ change: LibraryChange) async -> String? {
        guard !change.isEmpty else { return nil }
        do {
            try await library.update(seriesId: seriesId, change: change)
        } catch {
            return error.userFacingMessage
        }
        await refresh()
        return nil
    }

    /// Re-reads the shared library after a write, so both this control and the
    /// Library tab show what the server now holds rather than what was typed.
    private func refresh() async {
        await store.reload()
        entry = .some(store.entries.first { $0.seriesId == seriesId })
    }

    /// One tap for the commonest edit there is. A reader who has just finished
    /// a chapter should not have to open a sheet, retype a number they already
    /// know, and save it.
    func advanceChapter() async {
        guard let current = current else { return }
        let next = (current.progressChapter ?? 0) + 1
        isWorking = true
        defer { isWorking = false }
        failure = await apply(LibraryChange(progressChapter: .some(next)))
    }

    func remove() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await library.remove(seriesId: seriesId)
        } catch {
            failure = error.userFacingMessage
            return
        }
        failure = nil
        await refresh()
    }
}

/// The control itself. Renders nothing until the library has answered, because
/// flashing "Add" at someone who already has the series saved and then
/// swapping it for their real state reads as the app losing their data.
struct LibraryControl: View {
    let series: Series
    @State private var model: LibraryControlModel
    @State private var isEditing = false
    @State private var isChoosingState = false

    init(series: Series, library: any LibraryProviding, store: LibraryModel) {
        self.series = series
        _model = State(initialValue: LibraryControlModel(
            library: library,
            store: store,
            seriesId: series.id
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = model.current {
                saved(entry)
            } else if model.isKnown {
                addButton
            }
            if let failure = model.failure {
                Text(failure)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.load() }
        // Adding a series, changing its state or advancing a chapter all write
        // to the reader's real account over the network. The tap and the result
        // are seconds apart, and until now nothing marked the moment it landed.
        .sensoryFeedback(.success, trigger: model.current?.state)
        .sensoryFeedback(.error, trigger: model.failure) { _, new in new != nil }
        .sheet(isPresented: $isEditing) {
            if let entry = model.current {
                LibraryEditSheet(entry: entry, series: series) { change in
                    await model.apply(change)
                }
            }
        }
        .confirmationDialog("Add to library", isPresented: $isChoosingState) {
            ForEach(LibraryEntry.State.allCases, id: \.self) { state in
                Button(state.title) { Task { await model.add(state: state) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var addButton: some View {
        Button { isChoosingState = true } label: {
            Text("Add to library")
                .typeCTA()
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.ctaPrimary)
                .foregroundStyle(Palette.onAccent)
                .background(
                    Palette.accent,
                    in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                )
        }
        .buttonStyle(.press)
        .disabled(model.isWorking)
    }

    /// "CH 69" — where one tap takes you.
    ///
    /// The number rather than the word, because "next chapter" on a control
    /// this size wraps, and the number is the part that makes the button
    /// unambiguous.
    private func nextChapter(_ entry: LibraryEntry) -> String {
        let current = Int(entry.progressChapter ?? 0)
        return "CH \(current + 1)"
    }

    private func saved(_ entry: LibraryEntry) -> some View {
        HStack(spacing: Metrics.gapChips) {
            Button { isEditing = true } label: {
                HStack(spacing: 8) {
                    Text(entry.state.title)
                        .typeCTA()
                    if let rating = entry.rating {
                        Text("· " + String(Int((rating / 20).rounded())) + "★")
                            .typeSmallMeta()
                    }
                    if entry.state.tracksProgress, let chapter = entry.progressChapter {
                        Text("· ch \(Int(chapter))")
                            .typeSmallMeta()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.ctaPrimary)
                .foregroundStyle(Palette.textPrimary)
                .background(
                    Palette.surfaceChip,
                    in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                )
            }
            .buttonStyle(.press)
            .accessibilityLabel("Edit this entry. \(entry.state.title).")

            if entry.state.tracksProgress {
                Button { Task { await model.advanceChapter() } } label: {
                    // Labelled, not a bare plus. Abdi read it as "add to
                    // library" on a series that says "Paused · ch 68" right
                    // beside it — which is fair: it was the loudest control on
                    // the row and the only one that did not say what it did.
                    // It says the chapter it will take you to.
                    VStack(spacing: -1) {
                        Text("+1")
                            .font(.system(size: 15, weight: .bold))
                        Text(nextChapter(entry))
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.75)
                    }
                    .frame(width: Metrics.ctaPrimary, height: Metrics.ctaPrimary)
                    .foregroundStyle(Palette.onAccent)
                    .background(
                        Palette.accent,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    )
                }
                .buttonStyle(.press)
                .disabled(model.isWorking)
                .accessibilityLabel("Read one more chapter")
            }
        }
    }
}
