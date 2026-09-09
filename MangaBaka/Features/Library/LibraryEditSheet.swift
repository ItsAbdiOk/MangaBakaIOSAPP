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

    @State private var state: LibraryEntry.State
    @State private var chapter: String
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
        _chapter = State(initialValue: entry.progressChapter.map { String(Int($0)) } ?? "")
        // Stored 0-100, chosen as five steps.
        _rating = State(initialValue: entry.rating.map { Int(($0 / 20).rounded()) } ?? 0)
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
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state == option ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: chapterEyebrow)
            HStack(spacing: Metrics.gapChips) {
                TextField("0", text: $chapter)
                    .keyboardType(.numberPad)
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.field)
                    .background(Palette.surfaceField, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))
                    .accessibilityLabel("Chapters read")

                Button {
                    chapter = String((Int(chapter) ?? 0) + 1)
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
                .buttonStyle(.plain)
                .accessibilityLabel("Add one chapter")
            }
        }
    }

    /// An ongoing series has no denominator, so the label carries the total only
    /// when there is one.
    private var chapterEyebrow: String {
        guard let total = series.totalChapters, total > 0 else { return "Chapter" }
        return "Chapter of \(Int(total))"
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
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(step) star\(step == 1 ? "" : "s")")
                    .accessibilityAddTraits(step <= rating ? [.isButton, .isSelected] : .isButton)
                }
            }
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
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SwitchIndicator(isOn: isPrivate, isLocked: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Private entry")
        .accessibilityValue(isPrivate ? "On" : "Off")
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(Palette.onAccent)
                } else {
                    Text(changes.isEmpty ? "No changes" : "Save").typeCTA()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.ctaPrimary)
            .foregroundStyle(changes.isEmpty ? Palette.textTertiary : Palette.onAccent)
            .background(
                changes.isEmpty ? Palette.surfaceChip : Palette.accent,
                in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(changes.isEmpty || isSaving)
    }

    /// Only what actually differs from what was loaded.
    ///
    /// Sending every field would overwrite values the reader never touched with
    /// whatever this sheet happened to be holding.
    var changes: LibraryChange {
        var change = LibraryChange()
        if state != entry.state { change.state = state }

        let typed = chapter.trimmingCharacters(in: .whitespaces)
        let newChapter = typed.isEmpty ? nil : Double(typed)
        if newChapter != entry.progressChapter { change.progressChapter = .some(newChapter) }

        let newRating = rating == 0 ? nil : Double(rating * 20)
        if newRating != entry.rating { change.rating = .some(newRating) }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNote = trimmedNote.isEmpty ? nil : trimmedNote
        if newNote != entry.note { change.note = .some(newNote) }

        if isPrivate != (entry.isPrivate ?? false) { change.isPrivate = isPrivate }
        return change
    }

    private func save() async {
        isSaving = true
        failure = nil
        defer { isSaving = false }

        if let message = await onSave(changes) {
            failure = message
        } else {
            dismiss()
        }
    }
}
