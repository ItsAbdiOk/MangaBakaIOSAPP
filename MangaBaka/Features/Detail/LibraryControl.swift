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
    /// So a freshly-added entry can be shown locally before the server's own
    /// copy of it is known — see `add(state:)`.
    private let series: Series?

    /// Nil while unknown, `.some(nil)` once we know it is not in the library.
    private(set) var entry: LibraryEntry??
    private(set) var isWorking = false
    private(set) var failure: String?
    /// Set when the shared library couldn't say whether this series is
    /// saved — offline, throttled, a walk still in flight and none of it
    /// arrived yet. Gap 86: this used to be indistinguishable from "asked,
    /// and it is not saved", so a series the reader already had showed "Add
    /// to library" the moment the library's own walk had trouble — live.
    private(set) var checkFailure: APIError?
    /// The shared library has no credentials to walk with at all. The
    /// control renders nothing for this rather than offering to add a series
    /// nothing can be added to yet — a series page is not the place to ask
    /// for a token.
    private(set) var needsAccount = false

    var isKnown: Bool { entry != nil }
    var current: LibraryEntry? { entry.flatMap { $0 } }

    init(library: any LibraryProviding, store: LibraryModel, seriesId: Int, series: Series? = nil) {
        self.library = library
        self.store = store
        self.seriesId = seriesId
        self.series = series
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
    ///
    /// A prior call that ended in `checkFailure` or `needsAccount` leaves
    /// `entry` at `nil`, so calling this again — the retry `InlineFailure`
    /// offers — walks the shared store again rather than being a no-op.
    func load() async {
        guard entry == nil else { return }
        await store.load()
        applyStoreState()
    }

    private func applyStoreState() {
        switch store.screenState {
        case .noAccount:
            needsAccount = true
            checkFailure = nil
        case let .failed(error):
            // Gap 86: this used to fall through to the line below, which
            // read `store.entries.first { … }` against an empty array and
            // reported "not in the library" for a series that may well be —
            // the walk simply never got far enough to say.
            checkFailure = error
            needsAccount = false
        case .loading, .empty, .list:
            checkFailure = nil
            needsAccount = false
            entry = .some(store.entries.first { $0.seriesId == seriesId })
        }
    }

    func add(state: LibraryEntry.State) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await library.add(seriesId: seriesId, state: state)
        } catch {
            failure = error.userFacingMessage
            return
        }
        // Gap 87/96(j): patched locally rather than re-walking the whole
        // library to learn what was just written. The real server-assigned
        // `id` is not known until the next full read — **a guess**, used
        // only for this control's own display and never written into the
        // shared `store`, so nothing else in the app treats it as real.
        entry = .some(LibraryEntry(
            id: seriesId, seriesId: seriesId, state: state, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: series
        ))
    }

    /// Writes the change, then patches the shared store's own copy of this
    /// entry in place — `LibraryModel.apply(_:to:)` — instead of the full
    /// re-walk `refresh()` used to trigger. Gap 87: that re-walk paid 13
    /// requests for a one-field edit, and if it failed partway the control
    /// flipped from "Reading · ch 68" to "Add to library" despite the write
    /// itself having landed. Reading the patched entry back from `store`
    /// rather than applying it separately here keeps this control and the
    /// Library tab showing the same value.
    func apply(_ change: LibraryChange) async -> String? {
        guard !change.isEmpty else { return nil }
        do {
            try await library.update(seriesId: seriesId, change: change)
        } catch {
            return error.userFacingMessage
        }
        await store.apply(change, to: seriesId)
        entry = .some(store.entries.first { $0.seriesId == seriesId } ?? current?.applying(change))
        return nil
    }

    /// One tap for the commonest edit there is. A reader who has just finished
    /// a chapter should not have to open a sheet, retype a number they already
    /// know, and save it.
    func advanceChapter() async {
        guard let current = current else { return }
        let next = (current.progressChapter ?? 0) + 1
        isWorking = true
        failure = nil
        defer { isWorking = false }
        failure = await apply(LibraryChange(progressChapter: .some(next)))
    }

    /// Trusts the server's own acknowledgement rather than re-walking to
    /// confirm it — same reasoning as `apply(_:)`. The shared `store` still
    /// carries the row until its own next reload; only this control's
    /// display is updated immediately.
    func remove() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await library.remove(seriesId: seriesId)
        } catch {
            failure = error.userFacingMessage
            return
        }
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
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    init(series: Series, library: any LibraryProviding, store: LibraryModel) {
        self.series = series
        _model = State(initialValue: LibraryControlModel(
            library: library,
            store: store,
            seriesId: series.id,
            series: series
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = model.current {
                saved(entry)
            } else if let checkFailure = model.checkFailure {
                // Gap 86: this used to be indistinguishable from "the walk
                // finished and this series is not in it", which offered
                // "Add to library" live for a series the reader already had.
                InlineFailure(error: checkFailure) { await model.load() }
            } else if model.isKnown {
                addButton
            }
            // model.needsAccount: nothing rendered. A series page is not
            // where the reader is asked to sign in, and offering "Add to
            // library" with no account to add it to is the bug this
            // replaces.
        }
        .task { await model.load() }
        // Adding a series, changing its state or advancing a chapter all write
        // to the reader's real account over the network. The tap and the result
        // are seconds apart, and until now nothing marked the moment it landed.
        .sensoryFeedback(.success, trigger: model.current?.state)
        .sensoryFeedback(.error, trigger: model.failure) { _, new in new != nil }
        // Gap 109: a failure used to sit in the row forever in faint 12pt
        // type, with nothing to clear it and no spinner distinguishing a
        // write in flight from one that had already failed. A toast says it
        // once and then gets out of the way, the same as every other write
        // in the app.
        .onChange(of: model.failure) { _, failure in
            if let failure { toasts?.show(failure, kind: .failure) }
        }
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
            Group {
                if model.isWorking {
                    ProgressView().tint(Palette.onAccent)
                } else {
                    Text("Add to library")
                        .typeCTA()
                }
            }
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
        let current = Int(wholeOrClamped: entry.progressChapter ?? 0)
        return "CH \(current + 1)"
    }

    private func saved(_ entry: LibraryEntry) -> some View {
        HStack(spacing: Metrics.gapChips) {
            Button { isEditing = true } label: {
                HStack(spacing: 8) {
                    Text(entry.state.title)
                        .typeCTA()
                    if let rating = entry.rating {
                        Text("· " + String(Int(wholeOrClamped: (rating / 20).rounded())) + "★")
                            .typeSmallMeta()
                    }
                    if entry.state.tracksProgress, let chapter = entry.progressChapter {
                        Text("· ch \(Int(wholeOrClamped: chapter))")
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
                    Group {
                        if model.isWorking {
                            ProgressView().tint(Palette.onAccent)
                        } else {
                            VStack(spacing: -1) {
                                Text("+1")
                                    .font(.system(size: 15, weight: .bold))
                                Text(nextChapter(entry))
                                    .font(.system(size: 9, weight: .semibold))
                                    .opacity(0.75)
                            }
                        }
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
