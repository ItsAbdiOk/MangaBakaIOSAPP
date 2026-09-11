import SwiftUI

/// Search before anything is typed.
///
/// Three sections, and the shapes are the argument: a **lens** is a full-width
/// row with a live count, because it is a saved question that can be checked
/// and can break. A **preset** or a **recent term** is a chip, because it is
/// just a shortcut that fills the field. Rendering them alike would say they
/// were the same kind of thing.
struct SearchIdleView: View {
    let lenses: SearchLensStore
    let counts: LensCounts
    let recents: RecentSearches
    let onRun: (SearchLens) -> Void
    let onRunTerm: (String) -> Void

    @State private var isEditing = false

    private var own: [SearchLens] { lenses.own }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !own.isEmpty {
                yourLenses
            }
            presets
            if !recents.terms.isEmpty {
                recentTerms
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .task { counts.load(own) }
        .onDisappear { counts.cancel() }
    }

    // MARK: - Yours

    private var yourLenses: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your lenses")
                    .typeSubsectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Button(isEditing ? "Done" : "Edit") {
                    Motion.run(.snappy(duration: 0.2)) { isEditing.toggle() }
                }
                .typeInstruction()
                .foregroundStyle(Palette.accent)
                .buttonStyle(.plain)
            }

            VStack(spacing: 8) {
                ForEach(own) { lens in
                    row(lens)
                }
            }
        }
    }

    private func row(_ lens: SearchLens) -> some View {
        HStack(spacing: 12) {
            Button { onRun(lens) } label: {
                HStack(spacing: 11) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(lens.name)
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle(for: lens))
                            .typeSmallMeta()
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textQuaternary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .background(Palette.surface, in: RoundedRectangle(
                    cornerRadius: 14, style: .continuous
                ))
                .hairlineBorder(Palette.hairline, radius: 14)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: lens))

            if isEditing {
                Button {
                    counts.invalidate(lens.id)
                    Motion.run(.snappy(duration: 0.2)) { lenses.delete(id: lens.id) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(lens.name)")
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// The count when there is one, the filter summary until then.
    ///
    /// Never "0 now" from a missing answer: a lens claiming to find nothing is
    /// a real and much worse statement than one saying nothing yet. The summary
    /// is also what the row falls back to permanently if the counts are ever
    /// switched off for cost — see `LensCounts`.
    private func subtitle(for lens: SearchLens) -> String {
        guard let count = counts.counts[lens.id] else { return lens.rule }
        return "\(count.formatted()) now"
    }

    private func accessibilityLabel(for lens: SearchLens) -> String {
        guard let count = counts.counts[lens.id] else { return "\(lens.name). \(lens.rule)" }
        return "\(lens.name). \(count.formatted()) results now."
    }

    // MARK: - Presets and recents

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)

            FlowLayout(spacing: 8) {
                ForEach(SearchLens.presets) { lens in
                    chip(lens.name) { onRun(lens) }
                }
            }
        }
    }

    private var recentTerms: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .typeSubsectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                // Muted, not accent. Accent on this screen means "a way
                // onward"; throwing away your own search history is not one,
                // and three same-weight accent links told the reader nothing
                // about which to reach for.
                Button("Clear") { recents.clear() }
                    .typeInstruction()
                    .foregroundStyle(Palette.textMuted)
                    .buttonStyle(.plain)
            }

            FlowLayout(spacing: 8) {
                ForEach(recents.terms, id: \.self) { term in
                    chip(term) { onRunTerm(term) }
                }
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .typeChip()
                .lineLimit(1)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 13)
                .frame(minHeight: Metrics.headerPill)
                .background(Palette.surfaceChip, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                .contentShape(Capsule())
                .tapTarget()
        }
        .buttonStyle(.plain)
    }
}
