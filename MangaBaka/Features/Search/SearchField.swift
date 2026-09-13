import SwiftUI

/// The system search field on the Search tab: text, tokens, scopes, Recent
/// as suggestions, and what Cancel and Return do.
///
/// One modifier rather than six lines in `SearchView.body`, so the field's
/// whole contract — what it reads from the model, what it writes back — is
/// in one place. `SearchView` attaches it to the scroll view inside the
/// tab's `NavigationStack`, which is what makes `Tab(role: .search)` morph
/// the tab bar into this field rather than draw a second one.
///
/// What is deliberately not here: `dismissSearch` on a result tap (§5 asked
/// for it). The platform's dismiss clears the text as well as the keyboard,
/// and an emptied field is idle (`SearchModel.queryDidChange`) — so a reader
/// coming back from a series page would land on the idle panel instead of
/// the results they left, which the walk saw preserved and liked (LW §2).
/// Pushing the page already hides the field and the keyboard; that is the
/// dismiss the reader gets.
struct SearchField: ViewModifier {
    @Bindable var model: SearchModel
    let recents: RecentSearches
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: text,
                tokens: tokens,
                isPresented: $isPresented,
                prompt: "Title, author, or tag"
            ) { token in
                Text(token.label)
            }
            .searchScopes(scope, activation: .onSearchPresentation) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .searchSuggestions { suggestions }
            // Titles are not prose: the walk saw a trailing double space
            // become "berserk." (LW §3), and the system AutoFill chip floated
            // over the grid after a lens tap (#60). Neither belongs on a
            // field that takes a manga title. There is no `textContentType`
            // that says "nothing" — nil is the default that invites the
            // chip — so this is what the platform allows.
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                recents.record(model.query.text ?? "")
                model.cancelPendingDebounce()
                Task { await model.search() }
            }
            .onChange(of: isPresented) { _, presented in
                // Cancel: the platform has emptied the text by the time this
                // fires; the tokens and the asked state go with it. Guarded
                // on the text so a dismissal that keeps the text — leaving
                // for a series page — does not throw the search away.
                guard !presented, (model.query.text ?? "").isEmpty else { return }
                model.cancelSearch()
            }
    }

    private var text: Binding<String> {
        Binding(
            get: { model.query.text ?? "" },
            set: { model.query.text = $0 }
        )
    }

    /// The query's tags, genres and publisher, as the field's tokens. A
    /// token removed with the field's own × writes the query back without
    /// it and re-asks if anything was asked (`SearchModel.filtersDidChange`).
    private var tokens: Binding<[SearchToken]> {
        Binding(
            get: { SearchToken.tokens(for: model.query) },
            set: { next in
                let query = SearchToken.applying(next, to: model.query)
                guard query != model.query else { return }
                model.query = query
                model.filtersDidChange()
            }
        )
    }

    /// The scope bar and the panel's Type chips share `query.types` — see
    /// `SearchScope` for how one and several read back.
    private var scope: Binding<SearchScope> {
        Binding(
            get: { SearchScope.scope(for: model.query.types) },
            set: { next in
                let types = SearchScope.types(for: next)
                guard types != model.query.types else { return }
                model.query.types = types
                model.filtersDidChange()
            }
        )
    }

    /// Recent searches, only while the field is empty: the moment the
    /// reader types, their own words are the suggestion. Tapping one fills
    /// the field and submits, which is what `onSubmit` above records — the
    /// same "a recent tapped again is the most recent search" rule the
    /// hand-built list had (UX#10).
    @ViewBuilder
    private var suggestions: some View {
        if (model.query.text ?? "").isEmpty {
            ForEach(RecentSearches.visible(recents.terms), id: \.self) { term in
                Label(term, systemImage: "clock.arrow.circlepath")
                    .searchCompletion(term)
            }
        }
    }
}
