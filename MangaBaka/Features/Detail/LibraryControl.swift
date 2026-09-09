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
    private let seriesId: Int

    /// Nil while unknown, `.some(nil)` once we know it is not in the library.
    private(set) var entry: LibraryEntry??
    private(set) var isWorking = false
    private(set) var failure: String?

    var isKnown: Bool { entry != nil }
    var current: LibraryEntry? { entry ?? nil }

    init(library: any LibraryProviding, seriesId: Int) {
        self.library = library
        self.seriesId = seriesId
    }

    /// The library is paged and there is no by-series lookup, so this reads
    /// the reader's own entries and finds the one for this series. It is the
    /// same call `LibraryModel` makes, and the response is small enough that a
    /// second read costs less than threading shared state through every screen
    /// that can push a detail view.
    func load() async {
        guard entry == nil else { return }
        let entries = await library.library(page: 1, limit: 500)
        entry = .some(entries.first { $0.seriesId == seriesId })
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
        entry = nil
        await load()
    }

    func apply(_ change: LibraryChange) async -> String? {
        guard !change.isEmpty else { return nil }
        do {
            try await library.update(seriesId: seriesId, change: change)
        } catch {
            return error.userFacingMessage
        }
        entry = nil
        await load()
        return nil
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
        entry = .some(nil)
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

    init(series: Series, library: any LibraryProviding) {
        self.series = series
        _model = State(initialValue: LibraryControlModel(library: library, seriesId: series.id))
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
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.load() }
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
        .buttonStyle(.plain)
        .disabled(model.isWorking)
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
            .buttonStyle(.plain)
            .accessibilityLabel("Edit this entry. \(entry.state.title).")

            if entry.state.tracksProgress {
                Button { Task { await model.advanceChapter() } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: Metrics.ctaPrimary, height: Metrics.ctaPrimary)
                        .foregroundStyle(Palette.onAccent)
                        .background(
                            Palette.accent,
                            in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                .accessibilityLabel("Read one more chapter")
            }
        }
    }
}
