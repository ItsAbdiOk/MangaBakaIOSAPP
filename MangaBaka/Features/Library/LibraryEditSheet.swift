import SwiftUI

/// Change one entry in the reader's own library.
///
/// This is the only screen in the app that writes to someone's real account, so
/// it is deliberately explicit: nothing is sent until Save is tapped, only the
/// fields actually touched are sent, and a failure says so rather than leaving
/// the sheet looking as though it worked.
struct LibraryEditSheet: View {
    let entry: LibraryEntry
    let series: Series
    let onSave: (LibraryChange) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    @State private var state: LibraryEntry.State
    // Not `private`: L3's test needs to drive this directly, the way
    // `LibraryModel.searchText` already is for the same reason elsewhere.
    @State var chapter: String
    @State private var rating: Int
    @State private var note: String
    @State private var isPrivate: Bool
    @State private var isSaving = false
    @State private var failure: String?

    init(entry: LibraryEntry, series: Series, onSave: @escaping (LibraryChange) async -> String?) {
        self.entry = entry
        self.series = series
        self.onSave = onSave
        _state = State(initialValue: entry.state)
        // Formatted without going through Int: a reader at 12.5 who edited
        // only the rating used to have 12 written back, unasked.
        _chapter = State(initialValue: entry.progressChapter.map(Self.chapterText) ?? "")
        // Stored 0-100, chosen as five steps.
        _rating = State(initialValue: entry.rating.map { Int(wholeOrClamped: ($0 / 20).rounded()) } ?? 0)
        _note = State(initialValue: entry.note ?? "")
        _isPrivate = State(initialValue: entry.isPrivate ?? false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    title
                    stateSection
                    progressSection
                    ratingSection
                    noteSection
                    privacyToggle
                    if let failure {
                        Text(failure)
                            .typeSmallMeta()
                            .foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    saveButton
                }
                .padding(Metrics.gutter)
            }
            .scrollIndicators(.hidden)
            .background(Palette.ground)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var title: some View {
        Text(series.displayTitle ?? "Untitled series")
            .typeDetailHeroTitle()
            .foregroundStyle(Palette.textEmphasis)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Shelf")
            FlowLayout(spacing: 7) {
                ForEach(LibraryEntry.State.allCases, id: \.rawValue) { option in
                    Button { state = option } label: {
                        Text(option.title)
                            .typeChip()
                            .foregroundStyle(
                                state == option ? Palette.onAccent : Palette.textSecondary
                            )
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                state == option ? Palette.accent : Palette.surfaceChip,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.press)
                    .accessibilityAddTraits(state == option ? [.isButton, .isSelected] : .isButton)
                }
            }
            // The chosen chip fills rather than cuts to its new colour.
            .animation(Motion.reduced(Motion.snappy), value: state)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: chapterEyebrow)
            HStack(spacing: Metrics.gapChips) {
                TextField("0", text: $chapter)
                    // Gap 111: `.numberPad` has no decimal point, so a half
                    // chapter ("12.5") could not be typed at all — only pasted
                    // or reached through +1 from a whole number. `.decimalPad`
                    // adds the point (and, on locales that use one, the comma
                    // `parseChapter` already normalises).
                    .keyboardType(.decimalPad)
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.field)
                    .background(Palette.surfaceField, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))
                    .accessibilityLabel("Chapters read")

                Button {
                    let current = Self.parseChapter(chapter) ?? 0
                    chapter = Self.chapterText(current.rounded(.down) + 1)
                } label: {
                    Text("+1")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 16)
                        .frame(height: Metrics.field)
                        .background(Palette.surfaceChip, in: RoundedRectangle(
                            cornerRadius: Metrics.radiusCard, style: .continuous
                        ))
                }
                // `Haptics.tick` per tap — the same feel `LibraryControl`'s own
                // +1 gives, so the two routes to the same edit do not feel
                // like two different controls.
                .buttonStyle(.press(haptic: Haptics.tick))
                .accessibilityLabel("Add one chapter")
            }
            // L3: an unparsable field used to become `nil` here too, which
            // `changes` then sent as `progress_chapter: null` on Save — the
            // reader's number silently gone. Now it just says so.
            if chapterIsInvalid {
                Text("Couldn't read that as a chapter number. Progress is unchanged.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.accent)
            }
        }
    }

    /// An ongoing series has no denominator, so the label carries the total only
    /// when there is one.
    private var chapterEyebrow: String {
        guard let total = series.totalChapters, total > 0 else { return "Chapter" }
        return "Chapter of \(Int(wholeOrClamped: total))"
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: rating == 0 ? "Not rated" : "Your rating")
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { step in
                    Button {
                        // Tapping the current rating clears it, which is the
                        // only way back to "not rated".
                        rating = rating == step ? 0 : step
                    } label: {
                        Image(systemName: step <= rating ? "star.fill" : "star")
                            .font(.system(size: 22))
                            .foregroundStyle(step <= rating ? Palette.accent : Palette.textQuaternary)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("\(step) star\(step == 1 ? "" : "s")")
                    .accessibilityAddTraits(step <= rating ? [.isButton, .isSelected] : .isButton)
                }
            }
            // A rating is set by feel as much as by looking.
            .sensoryFeedback(Haptics.selection, trigger: rating)
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Note")
            TextField("Why you stopped, what to remember", text: $note, axis: .vertical)
                .lineLimit(2...5)
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
                .padding(12)
                .background(Palette.surfaceField, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusCard, style: .continuous
                ))
        }
    }

    private var privacyToggle: some View {
        Button { isPrivate.toggle() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private entry")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text("Hidden from anyone looking at your MangaBaka profile.")
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SwitchIndicator(isOn: isPrivate)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel("Private entry")
        .accessibilityValue(isPrivate ? "On" : "Off")
    }

    /// L3: a bad chapter field blocks Save entirely, same as no changes at
    /// all — sending the rest of the sheet while silently dropping the
    /// chapter the reader typed is its own kind of data loss.
    private var canSave: Bool { !changes.isEmpty && !chapterIsInvalid }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(Palette.onAccent)
                } else {
                    Text(chapterIsInvalid ? "Fix chapter" : (canSave ? "Save" : "No changes")).typeCTA()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.ctaPrimary)
            .foregroundStyle(canSave ? Palette.onAccent : Palette.textTertiary)
            .background(
                canSave ? Palette.accent : Palette.surfaceChip,
                in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
            )
        }
        .buttonStyle(.press)
        .disabled(!canSave || isSaving)
    }

    private func save() async {
        isSaving = true
        failure = nil
        defer { isSaving = false }

        // Gap 110: Save fires a plain `Task {}`, not a `.task {}` — dismissing
        // the sheet (Cancel, or a swipe) while it is in flight does not
        // cancel it, and the outcome used to land on `@State` belonging to a
        // view nobody was looking at anymore. `ToastCentre` lives above this
        // sheet, so it still delivers the word either way even after the
        // sheet itself is gone.
        if let message = await onSave(changes) {
            failure = message
            toasts?.show(message, kind: .failure)
        } else {
            toasts?.show("Saved")
            dismiss()
        }
    }
}

/// Chapter-text parsing and the change set Save sends. Split from the view
/// body above, which was at the struct body length limit.
extension LibraryEditSheet {
    /// Only what actually differs from what was loaded.
    ///
    /// Sending every field would overwrite values the reader never touched with
    /// "12" for a whole chapter, "12.5" for a half one.
    ///
    /// L2: `Int(Double)` traps outside ±9.2e18 — twenty digits on the number
    /// pad ("99999999999999999999") parse as 1e20, and `1e20.rounded() ==
    /// 1e20` is true, so the old `Int(value)` crashed the app. `Int(exactly:)`
    /// only ever returns a value it can represent; a whole number too big for
    /// one falls through to the plain `String(value)` (scientific notation)
    /// rather than trapping. A chapter count that large is already absurd, but
    /// showing an ugly number beats crashing on one.
    nonisolated static func chapterText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value.rounded() == value, let whole = Int(exactly: value.rounded()) {
            return String(whole)
        }
        return String(value)
    }

    /// Each non-ASCII decimal digit in `text`, replaced by its ASCII
    /// equivalent. Leaves everything else — including a decimal separator —
    /// untouched.
    ///
    /// `Character.wholeNumberValue` reads digits by their actual Unicode
    /// numeric value rather than by script, so this needs no locale guess for
    /// "which keyboard sent this": it handles Eastern Arabic numerals
    /// (`١٢`) the same way it would Devanagari ones.
    nonisolated private static func normalizedDigits(_ text: String) -> String {
        String(text.map { character in
            guard !character.isASCII, let digit = character.wholeNumberValue, (0...9).contains(digit) else {
                return character
            }
            return Character(String(digit))
        })
    }

    /// Parses whatever the reader actually typed into the chapter field.
    ///
    /// L3: `Double(text)` alone returns `nil` for a European decimal comma
    /// ("12,5", pasted or from a hardware keyboard) or for Arabic-Indic
    /// digits ("١٢", which the Arabic keyboard's own number pad emits) —
    /// ordinary text a reader might actually type, not garbage. `changes`
    /// used to read that `nil` as "clear the field", and Save sent
    /// `progress_chapter: null` over a reader's real "Ch 112". This tries a
    /// plain parse first, then digit-normalises and swaps a decimal comma for
    /// a point before trying again. Only text that still fails both is
    /// reported invalid by `chapterIsInvalid`.
    ///
    /// Gap 2: the field had no upper bound, and twenty digits
    /// ("99999999999999999999") parsed as `1e20` — a value `chapterText`
    /// could still render without trapping, but only because it routes
    /// through `Int(exactly:)`. Everything else that reads a chapter number
    /// off the wire does not, and whether MangaBaka itself stores a number
    /// that large is unverified (see `Int.init(wholeOrClamped:)`'s doc
    /// comment) — so the field refuses one rather than sending it. 100,000 is
    /// **a guess**: no real series is within two orders of magnitude of it,
    /// so the ceiling only ever catches a mistyped or pasted value.
    nonisolated static let maximumChapter: Double = 100_000

    nonisolated static func parseChapter(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value.magnitude <= maximumChapter ? value : nil }
        let normalized = normalizedDigits(trimmed).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return nil }
        return value.magnitude <= maximumChapter ? value : nil
    }

    /// Whether the chapter field holds text Save cannot honestly interpret.
    ///
    /// Distinct from empty, which means "no progress" and is a legitimate
    /// value to send. This means "something was typed that could not be
    /// read", and Save must refuse rather than silently clearing it (L3).
    var chapterIsInvalid: Bool { Self.isInvalidChapter(chapter) }

    /// The rule behind `chapterIsInvalid`, static so a test can reach it —
    /// a `@State` written outside a view hierarchy is dropped, so the
    /// property itself cannot be driven from a test.
    nonisolated static func isInvalidChapter(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && parseChapter(trimmed) == nil
    }

    /// whatever this sheet happened to be holding.
    var changes: LibraryChange {
        var change = LibraryChange()
        if state != entry.state { change.state = state }

        let typed = chapter.trimmingCharacters(in: .whitespaces)
        // An unparsable, non-empty field is left out of the change set
        // entirely rather than sent as `null` — `chapterIsInvalid` blocks
        // Save in that case, so this branch only matters if it is ever
        // called while invalid.
        if typed.isEmpty || Self.parseChapter(typed) != nil {
            let newChapter = typed.isEmpty ? nil : Self.parseChapter(typed)
            if newChapter != entry.progressChapter { change.progressChapter = .some(newChapter) }
        }

        let newRating = rating == 0 ? nil : Double(rating * 20)
        if newRating != entry.rating { change.rating = .some(newRating) }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNote = trimmedNote.isEmpty ? nil : trimmedNote
        if newNote != entry.note { change.note = .some(newNote) }

        if isPrivate != (entry.isPrivate ?? false) { change.isPrivate = isPrivate }
        return change
    }
}
