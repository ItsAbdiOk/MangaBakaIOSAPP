import SwiftUI

/// The two picker sheets `FilterPanel`'s "Genres" and "Publishers" buttons
/// open. Split out of `FilterPanel.swift` on 2026-09-13 when the Genres
/// sheet grew a search field and the file crossed the lint's length
/// ceiling — the same split `TagPickerSheet` already has, not a widening
/// of who is meant to touch these. `TagPickerSheet` stays where it is.

/// Picking a genre for the panel's "Genres" button — the same 46-item list
/// `BrowseView`'s genre chips draw from, presented as a sheet rather than a
/// whole screen since this is one filter among several being built, not a
/// destination in its own right.
///
/// Writes genre *values* (`slice_of_life`) into `SearchQuery.genres`, never
/// `tags` — the two are different keys on the wire and a genre sent as a
/// tag finds 6-14% of it (`SearchQuery.genres` has the numbers).
///
/// A search field at the top, like the Tags sheet's, with the count in the
/// placeholder: the live walk (2026-09-13, `07-genres-sheet.png`) found
/// this sheet a flat wall of ~50 chips beside a sibling that could be
/// searched, and the two are reached from the same row. Filtered locally —
/// 46 labels is nothing to ask a server about. No per-genre count badge:
/// `/v1/genres` carries none, and the bundled taxonomy's number is for the
/// *tag* of the same name, a different question (Romance 109,065 as a tag,
/// 100,947 as a genre) — a number that answers the wrong question is worse
/// than none.
struct GenrePickerSheet: View {
    let catalogue: CatalogueService
    @Binding var genres: [Genre]
    @Binding var selected: [String]

    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [Genre] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return genres }
        return genres.filter {
            $0.label.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field
                    if shown.isEmpty, !genres.isEmpty {
                        Text("No genre called \u{201C}\(filter)\u{201D}.")
                            .typeSmallMeta()
                            .foregroundStyle(Palette.textMuted)
                    }
                    chips
                }
                .padding(Metrics.gutter)
            }
            .background(Palette.ground)
            .navigationTitle("Genres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
        .task { if genres.isEmpty { genres = await catalogue.genres().value ?? [] } }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            TextField(
                genres.isEmpty ? "Search genres" : "Search \(genres.count) genres", text: $filter
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .typeBody()
            .foregroundStyle(Palette.textPrimary)
            SearchClearButton(text: $filter)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.field)
        .background(Palette.surfaceField, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
    }

    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(shown) { genre in
                Button {
                    toggle(&selected, genre.value)
                } label: {
                    Text(genre.label)
                        .typeChip()
                        .foregroundStyle(
                            selected.contains(genre.value) ? Palette.onAccent : Palette.textSecondary
                        )
                        .padding(.horizontal, 13)
                        .frame(height: Metrics.headerPill)
                        .background(
                            selected.contains(genre.value) ? Palette.accent : Palette.surfaceChip,
                            in: Capsule()
                        )
                        .tapTarget()
                }
                .buttonStyle(.press)
                .haptic(Haptics.selection, on: selected.contains(genre.value))
            }
        }
    }
}

/// Picking a publisher for the panel's "Publishers" button — `PublisherBrowser`
/// wrapped in a sheet's chrome, the same reuse `TagPickerSheet` gets.
struct PublisherPickerSheet: View {
    let catalogue: CatalogueService
    let onOpen: (PublisherRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PublisherBrowser(catalogue: catalogue, onOpen: onOpen)
                    .padding(.top, 12)
            }
            .background(Palette.ground)
            .navigationTitle("Publishers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
    }
}
