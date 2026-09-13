import SwiftUI

/// The filter panel, presented as a sheet mid-search.
///
/// The controls themselves moved to `FilterPanel` on 2026-09-13 so the idle
/// screen could host the identical panel inline (Abdi: "I like the Filter
/// sheet... keep that on the main search page") — this file is now just the
/// sheet's chrome around it.
struct FilterSheet: View {
    @Binding var query: SearchQuery
    let onApply: () -> Void
    /// Saving a lens happens in the panel that owns filters, so any host
    /// gets it without it being designed twice. Absent where a caller has
    /// nowhere to put a lens. (Only `SearchView` presents this sheet; Mix
    /// reaches the same `SaveLensButton` through its own strip, not through
    /// here — an earlier version of this comment said otherwise.)
    var onSaveLens: (() -> Void)?
    /// The tag catalogue, so tags can be picked here rather than typed. Absent
    /// where a caller has none to offer.
    var catalogue: CatalogueService?
    /// "Browse offline" — answer from the bundled index and send zero
    /// requests, rather than waiting for the network to actually fail first.
    /// Absent where a caller has nowhere to read or set it (`SeedPickerSheet`,
    /// which builds its own `SearchModel` without wiring offline support).
    var preferOffline: Binding<Bool>?
    /// A live count for "Show results", when the caller can answer one. See
    /// `FilterPanel.previewCount`.
    var previewCount: ((SearchQuery) async -> Int?)?
    /// The offline counter, handed straight through to `FilterPanel`.
    var offlineCount: ((SearchQuery) async -> Int?)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Filters")
                    .typeSheetTitle()
                    .foregroundStyle(Palette.textPrimary)

                FilterPanel(
                    query: $query,
                    onSaveLens: onSaveLens.map { save in { save(); dismiss() } },
                    catalogue: catalogue,
                    preferOffline: preferOffline,
                    previewCount: previewCount,
                    offlineCount: offlineCount,
                    onShowResults: {
                        onApply()
                        dismiss()
                    }
                )
            }
            .padding(Metrics.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
    }
}
