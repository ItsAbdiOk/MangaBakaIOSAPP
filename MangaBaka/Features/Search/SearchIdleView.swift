import SwiftUI

/// Search before anything is typed.
///
/// Two sections, in this order: the **Filters** panel, inline rather than
/// behind a tap, because "searching for a manga felt so odd" (Abdi,
/// 2026-09-13) when the only way in was a text field with no visible way to
/// narrow anything; and **Your lenses**, last and only when there are any,
/// because a saved search is the one thing here worth a full row with a
/// live count rather than a shortcut that just fills the field.
///
/// **What used to be here.** A **Recent** section of rows, each with its
/// own ×, sat above the panel until 2026-09-13; Recent is now the system
/// field's own suggestion list (`SearchField`), shown while the field is
/// empty and gone on the first keystroke (UX#6). Before that, a presets
/// section of three hard-coded lenses and the full tag row sat above this,
/// laying out the whole vocabulary before the reader had typed a single
/// letter — see `SearchLens`'s doc comment for where the presets came from
/// and why they are gone.
struct SearchIdleView: View {
    let lenses: SearchLensStore
    let counts: LensCounts
    @Binding var query: SearchQuery
    let catalogue: CatalogueService?
    var preferOffline: Binding<Bool>?
    let onRun: (SearchLens) -> Void
    let onSaveLens: () -> Void
    let onShowResults: () -> Void
    var previewCount: ((SearchQuery) async -> Int?)?
    /// The offline counter, handed straight through to `FilterPanel`.
    var offlineCount: ((SearchQuery) async -> Int?)?

    @State private var isEditingLenses = false
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    private var own: [SearchLens] { lenses.own }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            filters
                .arrives(index: 0)

            if !own.isEmpty {
                yourLenses
                    .arrives(index: 1)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .task { counts.load(own) }
        .onDisappear { counts.cancel() }
    }

    // MARK: - Filters

    /// The two section titles here are `typeSectionHeader()` — 20pt bold,
    /// the mockup's own size for "Recent" and "Your lenses" and what
    /// Discover and Library head their rows with. Until 2026-09-13 they
    /// were the 15pt `typeSubsectionHeader()` the panel's own "Type",
    /// "Status", … labels used, so a first-time reader met ten headers at
    /// one weight and nothing to say which seven belonged to "Filters"
    /// (review UX#7). The panel's labels are now eyebrows, one level down.
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filters")
                .typeSectionHeader()
                .foregroundStyle(Palette.textPrimary)
            FilterPanel(
                query: $query,
                onSaveLens: onSaveLens,
                catalogue: catalogue,
                preferOffline: preferOffline,
                previewCount: previewCount ?? counts.count,
                offlineCount: offlineCount,
                onShowResults: onShowResults
            )
        }
    }

    // MARK: - Yours

    private var yourLenses: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your lenses")
                    .typeSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Button(isEditingLenses ? "Done" : "Edit") {
                    Motion.run(Motion.snappy) { isEditingLenses.toggle() }
                }
                .typeInstruction()
                .foregroundStyle(Palette.accent)
                .buttonStyle(.press)
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
                            // "1,204 now" rolls once a live count answers,
                            // rather than cutting from the filter summary.
                            .countsNotCuts()
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
            .buttonStyle(.press)
            .accessibilityLabel(accessibilityLabel(for: lens))

            if isEditingLenses {
                Button {
                    counts.invalidate(lens.id)
                    let name = lens.name
                    Motion.run(Motion.snappy) { lenses.delete(id: lens.id) }
                    // Deleting a lens used to give no sign it happened (gap
                    // 54). Decision 3 reserves a confirmation dialog for the
                    // two truly irreversible actions elsewhere ("Remove
                    // token", "Deal another now") — a lens is one line the
                    // reader can recreate in seconds, so a toast is the right
                    // weight, not a dialog in front of a dialog.
                    toasts?.show("\(name) deleted")
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.press)
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
}
