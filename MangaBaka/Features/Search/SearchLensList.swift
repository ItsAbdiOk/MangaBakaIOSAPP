import SwiftUI

/// Saved searches, shown before anything is typed.
///
/// The mockup fills the idle screen with these rather than with an invitation
/// to type. Three ship with the app so a reader with none of their own still
/// sees the shape of the feature; the rest are theirs.
struct SearchLensList: View {
    let lenses: SearchLensStore
    let onRun: (SearchLens) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(lenses.all) { lens in
                Button { onRun(lens) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lens.name)
                                .typeRowTitle()
                                .foregroundStyle(Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(lens.rule)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textQuaternary)
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
                .contextMenu {
                    // Only the reader's own can be deleted; the presets are
                    // what an empty screen falls back to.
                    if lens.isOwn {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            lenses.delete(id: lens.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
