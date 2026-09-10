import SwiftUI

/// Search, with type/status/sort/rating filters in a sheet.
struct SearchView: View {
    @Bindable var model: SearchModel
    @Binding var path: [Series]
    /// Opens the genre and tag browser.
    ///
    /// Lives in the screen's own header rather than the navigation bar: the
    /// app's custom top bar is drawn over the navigation bar on a root screen,
    /// so a toolbar button there was clipped to a sliver at the screen edge.
    let onBrowse: () -> Void
    let lenses: SearchLensStore

    @State private var isNamingLens = false
    @State private var lensName = ""

    @State private var showFilters = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Metrics.gapCovers),
        count: 3
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                searchBar
                    .padding(.horizontal, Metrics.gutter)

                // A heading and two links. Kept on one row until they no
                // longer fit: squeezed by both links, "30 results" broke into
                // "30" / "result" / "s" at the largest text size.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        headingText
                        Spacer(minLength: 0)
                        headerActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        headingText
                        headerActions
                    }
                }
                .padding(.horizontal, Metrics.gutter + 2)

                content
                saveLens
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .alert("Name this lens", isPresented: $isNamingLens) {
            TextField("Cosy fantasy, completed", text: $lensName)
            Button("Cancel", role: .cancel) { lensName = "" }
            Button("Save") {
                lenses.save(name: lensName, query: model.query)
                lensName = ""
            }
        } message: {
            Text(SearchLens.describe(model.query))
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet(query: $model.query) {
                Task { model.cancelPendingDebounce(); await model.search() }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(Metrics.radiusSheet)
        }
    }

    private var searchBar: some View {
        HStack(spacing: Metrics.gapChips) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textTertiary)
                TextField("Title, author, or tag", text: Binding(
                    get: { model.query.text ?? "" },
                    set: { model.query.text = $0 }
                ))
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .foregroundStyle(Palette.textPrimary)
                .typeBody()
                .onSubmit { Task { model.cancelPendingDebounce(); await model.search() } }
                .onChange(of: model.query.text) { _, _ in model.queryDidChange() }
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.field)
            .background(Palette.surfaceField)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))

            Button {
                showFilters = true
            } label: {
                Text("Filters")
                    .typeCTA()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: Metrics.field)
                    .background(Palette.surfaceChip)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            }
        }
    }

    private var headingText: some View {
        Text(heading)
            .typeSubsectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var headerActions: some View {
        HStack(spacing: 14) {
            Button(action: onBrowse) {
                Text("Browse")
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            Button {
                model.query.sort = "random"
                Task { model.cancelPendingDebounce(); await model.search() }
            } label: {
                Text("Surprise me")
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.isSearching)
        }
        .fixedSize()
    }

    /// "12 results · Score" once anything is asked for, "Saved lenses"
    /// before that — the mockup's own wording.
    private var heading: String {
        guard !model.query.isEmpty else { return "Saved lenses" }
        // "shown", not "results": this is the number loaded so far, and a query
        // matching thousands read "24 results" and then "47 results" as the
        // reader scrolled — the same query reporting different totals.
        let count = "\(model.results.count) shown"
        guard let sort = SortOrder.label(for: model.query.sort) else { return count }
        return "\(count) · \(sort)"
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            SearchLensList(lenses: lenses) { lens in
                model.query = lens.query
                Task { model.cancelPendingDebounce(); await model.search() }
            }
        } else if model.isSearching {
            ProgressView()
                .tint(Palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let message = model.message, model.results.isEmpty {
            errorState(message)
        } else if model.results.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            resultsGrid
            if model.isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(model.results) { series in
                Button { path.append(series) } label: {
                    CoverCard(
                        series: series,
                        width: 111,
                        radius: Metrics.radiusCoverGrid,
                        meta: DiscoverView.meta(for: series)
                    )
                }
                .buttonStyle(.plain)
                // Two rows from the bottom, so the next page is usually there
                // before the reader arrives rather than after.
                .onAppear {
                    guard shouldPrefetch(series) else { return }
                    Task { await model.loadMore() }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// Six results is two rows of the three-column grid.
    private static let prefetchDistance = 6

    private func shouldPrefetch(_ series: Series) -> Bool {
        guard model.hasMore, !model.isLoadingMore,
              let index = model.results.firstIndex(where: { $0.id == series.id })
        else { return false }
        return index >= model.results.count - Self.prefetchDistance
    }

    /// Saves whatever filter is applied as a lens of the reader's own.
    @ViewBuilder
    private var saveLens: some View {
        if !model.query.isEmpty {
            Button { isNamingLens = true } label: {
                Text("Save as a lens")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaSecondary)
                    .background(Palette.surface, in: RoundedRectangle(
                        cornerRadius: 14, style: .continuous
                    ))
                    .hairlineBorder(Palette.borderPill, radius: 14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.gapCovers)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Text("Nothing matched \(displayedQuery)")
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
            Text("Try a looser filter, or let the API pick.")
                .typeInstruction()
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Button {
                model.query.sort = "random"
                Task { model.cancelPendingDebounce(); await model.search() }
            } label: {
                Text("Random with these filters")
                    .typeRowTitle()
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 34)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 70)
    }

    private var displayedQuery: String {
        let text = (model.query.text ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "these filters" : "\u{201C}\(text)\u{201D}"
    }
}
