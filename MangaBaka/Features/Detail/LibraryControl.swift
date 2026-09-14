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
    /// The shared library has no credentials to walk with at all. Rendered
    /// as one muted line saying so, where the button would be. It used to
    /// be set here and read nowhere: the control drew nothing at all for a
    /// reader with no token — no button, no explanation — while the Library
    /// tab had a whole screen for the same state (review item 31,
    /// 2026-09-14). Still not a place to ask for a token; it only says
    /// where one goes.
    private(set) var needsAccount = false

    var isKnown: Bool { entry != nil }
    var current: LibraryEntry? { entry.flatMap { $0 } }

    /// What the control shows, decided in one place so the decision can be
    /// tested — the body used to chain `if let` branches that silently fell
    /// through for the no-account case.
    enum ControlState: Equatable {
        /// The library has not answered yet: nothing is claimed.
        case unknown
        case noAccount
        case checkFailed(APIError)
        case saved(LibraryEntry)
        case canAdd
    }

    var state: ControlState {
        if let current { return .saved(current) }
        if let checkFailure { return .checkFailed(checkFailure) }
        if needsAccount { return .noAccount }
        return isKnown ? .canAdd : .unknown
    }

    /// The one line shown instead of the button when there is no account.
    nonisolated static let noAccountLine = "Add a MangaBaka token in Settings to track this"

    /// The id a row added from this control carries until the next walk
    /// replaces it with the server's. **A guess**: server ids are positive
    /// and nowhere near `Int.max`, so this cannot collide with a real row
    /// — the trap `ForEach` would spring on two equal ids — and sorts as
    /// the newest under `LibrarySort`'s "recently added", which is what a
    /// row just added is.
    nonisolated static func placeholderID(for seriesId: Int) -> Int { Int.max - seriesId }

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
        // `id` is not known until the next full read — see `placeholderID`.
        // Written into the shared `store` too, so the Library tab lists the
        // series now rather than after its next walk (item 72); it used to
        // update only this control's own `entry`.
        let placeholder = LibraryEntry(
            id: Self.placeholderID(for: seriesId), seriesId: seriesId, state: state, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: series
        )
        store.insert(placeholder)
        entry = .some(store.entries.first { $0.seriesId == seriesId } ?? placeholder)
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
    /// confirm it — same reasoning as `apply(_:)`. The shared `store` drops
    /// the row too (item 72): it used to keep it until its own next reload,
    /// so the Library tab still listed a series the reader had just removed.
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
        store.remove(seriesId: seriesId)
        entry = .some(nil)
    }

    /// Whether a state change from `old` to `new` is the reader finishing a
    /// series, worth the one-shot checkmark and `Haptics.success` — versus
    /// every other write, which only gets `Haptics.committed`.
    ///
    /// `old == nil` is deliberately excluded: that is the control's own
    /// first look at an entry (`load()` populating `entry` for the first
    /// time, or `add(state:)` creating one), not a reader finishing
    /// something mid-session. Without the guard, opening a series page for a
    /// title already marked Completed on the website would celebrate on
    /// first render — the checkmark exists to mark a transition, not a fact.
    nonisolated static func shouldCelebrate(old: LibraryEntry.State?, new: LibraryEntry.State?) -> Bool {
        guard let old else { return false }
        return new == .completed && old != .completed
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
    /// The last state this control actually saw, set once `load()` (or a
    /// write) settles — the baseline `shouldCelebrate` compares against, kept
    /// outside the model because it is a view-level "what did we last show",
    /// not library data.
    @State private var lastKnownState: LibraryEntry.State?
    /// Bumped once per genuine "just finished" transition. Drives both the
    /// checkmark's one-shot trim and `Haptics.success`, so neither can fire
    /// on a re-render — only `onChange` below ever touches it.
    @State private var completionPulse = 0
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
            switch model.state {
            case let .saved(entry):
                saved(entry)
            case let .checkFailed(checkFailure):
                // Gap 86: this used to be indistinguishable from "the walk
                // finished and this series is not in it", which offered
                // "Add to library" live for a series the reader already had.
                InlineFailure(error: checkFailure) { await model.load() }
            case .noAccount:
                // Not a sign-in prompt — a series page is not where the
                // reader is asked for a token — and not "Add to library"
                // with no account to add it to. One line saying where to go,
                // as the Library tab does for the same state (item 31).
                Text(LibraryControlModel.noAccountLine)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case .canAdd:
                addButton
            case .unknown:
                EmptyView()
            }
        }
        // The chosen state's chip (the "saved" row swapping in for the "Add"
        // button, and the chip's own label changing) answers the tap rather
        // than cutting to it.
        .animation(Motion.reduced(Motion.snappy), value: model.current?.state)
        .task {
            await model.load()
            // Seeds the baseline *after* the first load lands, not before —
            // so the transition load() itself performs (nil to whatever the
            // server already has) is never mistaken for the reader finishing
            // something just now.
            lastKnownState = model.current?.state
        }
        // Adding a series, changing its state or advancing a chapter all write
        // to the reader's real account over the network. The tap and the result
        // are seconds apart, and until now nothing marked the moment it landed.
        // `Haptics.committed` marks the write itself; `Haptics.success` below
        // is reserved for the one case that is a reward rather than a receipt.
        .sensoryFeedback(Haptics.committed, trigger: model.current?.state) { old, _ in old != nil }
        .sensoryFeedback(Haptics.success, trigger: completionPulse)
        .onChange(of: model.current?.state) { _, new in
            if LibraryControlModel.shouldCelebrate(old: lastKnownState, new: new) {
                completionPulse += 1
            }
            lastKnownState = new
        }
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
            .frame(minHeight: Metrics.ctaPrimary)
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
                    if entry.state == .completed {
                        CompletionCheckmark(trigger: completionPulse)
                    }
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
                .frame(minHeight: Metrics.ctaPrimary)
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
                                    .typeCTA()
                                Text(nextChapter(entry))
                                    .typeMicroLabel()
                                    .opacity(0.75)
                                    // The number this button will land on rolls
                                    // rather than cutting, same as every other
                                    // figure on screen that can change.
                                    .countsNotCuts()
                            }
                        }
                    }
                    .frame(minWidth: Metrics.ctaPrimary, minHeight: Metrics.ctaPrimary)
                    .foregroundStyle(Palette.onAccent)
                    .background(
                        Palette.accent,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    )
                }
                // `Haptics.tick` on the tap itself — the reader felt the finger
                // move a number, distinct from `Haptics.committed` above, which
                // marks the write that tap kicked off actually landing.
                .buttonStyle(.press(haptic: Haptics.tick))
                .disabled(model.isWorking)
                .accessibilityLabel("Read one more chapter")
            }
        }
    }
}

/// The checkmark that draws itself once beside "Completed" — a `Path`
/// stroked from nothing to whole on `Motion.celebrate`, not a glyph that
/// simply appears. Keyed on `trigger` (`LibraryControl`'s `completionPulse`,
/// bumped only by a genuine `LibraryControlModel.shouldCelebrate` result), so
/// re-rendering this view — a parent re-laying-out, Dynamic Type changing —
/// never redraws it: only a real transition into Completed bumps `trigger`.
///
/// Reduce Motion draws the full mark at once rather than skipping it: the
/// checkmark itself is information (this entry is Completed), unlike the
/// scale bounce `.celebrates(on:)` gives up entirely under the setting.
private struct CompletionCheckmark: View {
    let trigger: Int
    @State private var trim: CGFloat = 1

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 5))
            path.addLine(to: CGPoint(x: 4, y: 9))
            path.addLine(to: CGPoint(x: 11, y: 0))
        }
        .trim(from: 0, to: trim)
        .stroke(Palette.positive, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .frame(width: 11, height: 9)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, new in
            guard new > 0 else { return }
            guard !Motion.isReduced else {
                trim = 1
                return
            }
            trim = 0
            withAnimation(Motion.celebrate) { trim = 1 }
        }
    }
}
