import SwiftUI

/// Keeping the pending reminders in step with what the app knows.
///
/// Its own file for the lint's body-length ceiling, and because it is one idea:
/// whenever the reader's answer or the app's answer changes, rebuild the list
/// rather than adding to it.
extension RootView {
    /// The Library tab and everything reachable from it.
    ///
    /// Its own property because this one tab carries five destinations — a
    /// series, a shelf, the taste screen, the schedule and Settings — and it
    /// had grown to more than half of `RootView`'s body on its own.
    /// `TabContent`, not `View`: a `Tab` inside a `TabView` is not a view, and
    /// typing it as one is accepted right up until the builder rejects it.
    @TabContentBuilder<AppTab>
    var libraryTab: some TabContent<AppTab> {
                Tab(AppTab.library.title, systemImage: AppTab.library.symbol, value: AppTab.library) {
                    NavigationStack(path: $shelfPath) {
                        LibraryView(
                            model: session.library,
                            path: $shelfPath,
                            scheduleSummary: nil,
                            onOpenSchedule: { showsSchedule = true },
                            onOpenTaste: { showsTaste = true },
                            onOpenWrapped: { showsWrapped = true },
                            onOpenSettings: { showsSettings = true },
                            onOpenStack: { selection = .stack },
                            onSave: saveLibraryChange,
                            continuations: continuations
                        )
                            .navigationDestination(for: Series.self) { detail($0, path: $shelfPath) }
                            .navigationDestination(isPresented: $showsWrapped) {
                                WrappedView(
                                    entries: session.library.entries,
                                    // The baseline the signature statistic is
                                    // measured against. From the live pulse
                                    // where it has arrived, and otherwise the
                                    // pulse's own reading on 2026-09-11. It
                                    // moves by a few hundred a week, so a
                                    // year's staleness shifts a lift by about
                                    // 5% — enough to move a tag sitting on the
                                    // 2.0 gate, not enough to invent one.
                                    // `Int(wholeOrClamped:)`, not `Int(_:)`
                                    // (item 9): `activeSeriesCount` is a
                                    // server `Double`, and `Int(.nan)` traps.
                                    catalogueSize: session.pulse.pulse
                                        .map { Int(wholeOrClamped: $0.activeSeriesCount) }
                                        ?? ReadingWrapped.catalogueSizeOn20260911,
                                    // Item 6: both of these took the default
                                    // `isComplete: true` "until the shell
                                    // passes the real value", and the shell
                                    // never did — so the "Built from the N
                                    // that loaded" bar was unreachable and
                                    // half the recompute trigger was dead.
                                    isComplete: session.library.isComplete,
                                    libraryRevision: session.library.revision,
                                    path: $shelfPath
                                )
                            }
                            .navigationDestination(isPresented: $showsTaste) {
                                // Reading insights rather than the old taste
                                // screen: the same route, six answers instead
                                // of one, and none of them from an endpoint.
                                ReadingInsightsView(
                                    entries: session.library.entries,
                                    isComplete: session.library.isComplete,
                                    libraryRevision: session.library.revision,
                                    path: $shelfPath
                                )
                            }
                            .navigationDestination(isPresented: $showsSchedule) {
                                ScheduleView(
                                    model: ScheduleModel(
                                        service: schedule,
                                        calendar: calendar,
                                        snapshot: librarySnapshot,
                                        // So the widget's "due this week" is
                                        // built from real publisher dates
                                        // where a feed is cached, not from
                                        // MangaUpdates estimates alone — the
                                        // same order Siri speaks them in.
                                        feeds: releaseFeeds,
                                        repository: repository
                                    ),
                                    path: $shelfPath
                                )
                            }
                            .navigationDestination(isPresented: $showsSettings) {
                                SettingsView(
                                    validate: validateStoredToken,
                                    content: content,
                                    // Item 20: Settings used to build a
                                    // private, database-less `LibrarySnapshot`
                                    // and walk the whole library on
                                    // appearance — ~13 requests and ~25 MB for
                                    // an export nobody had tapped. The shared
                                    // snapshot has already walked once this
                                    // session and answers from cache.
                                    library: library,
                                    // `wholeLibrary`, not `all()`: this is the
                                    // set the import compares against to
                                    // refuse a downgrade, and a failed walk
                                    // answering "[]" turned every row into an
                                    // add that walked the reader's own
                                    // progress backwards (review 2, item 4).
                                    loadExisting: { await librarySnapshot.load().wholeLibrary },
                                    formats: formats,
                                    blockedTags: blockedTags,
                                    catalogue: catalogue,
                                    focusAccount: wantsAccountFocus,
                                    reminders: reminders,
                                    publisherFollows: publisherFollows.value,
                                    onRemindersChanged: { await refreshReminders() },
                                    history: history,
                                    taste: taste,
                                    onAccountChanged: { await forgetPreviousAccount() },
                                    titleRevision: $titleRevision,
                                    // The app's one `TokenStore`, not a
                                    // fourth of its own (second-pass review
                                    // S1): Settings is the only writer, and
                                    // what it writes has to be what the
                                    // client reads back a moment later when
                                    // it validates the token.
                                    store: tokenStore
                                )
                            }
                    }
                }
    }

    /// Forgets everything the app learned from whoever was signed in before.
    ///
    /// A cached profile id would let a second account inherit the first's
    /// library, and a taste ledger built from someone else's reading makes
    /// every recommendation quietly about the wrong person. Both existed with
    /// a way to clear them and nothing calling it — found by Periphery, which
    /// reported them as dead code; they were a behavioural gap instead.
    /// Everything scoped to the person who was signed in.
    ///
    /// Listed in one place because the list is the bug. Two of these existed
    /// with a way to clear them and nothing calling it; a third was missed
    /// when the first two were wired up; and the "Remove token" button took a
    /// different path that called none of them. Four account-scoped values,
    /// three ways to change account, and no two agreeing.
    func forgetPreviousAccount() async {
        await library.forgetProfile()
        // Item 43: this was `try? await ledger?.clear()` inside
        // `forgetEverything`, so a failed clear left the previous account's
        // taste ledger on disk and nothing said so — the one cache whose
        // survival is about the wrong person.
        if await !taste.forgetEverything() {
            toasts.show(
                "Couldn't clear what the app learned from the previous account. "
                    + "Signing in again and removing the token will retry it.",
                kind: .failure
            )
        }
        await librarySnapshot.invalidate()
        // Gap 89: the previous account's shelves stayed on screen — in
        // `session.library.entries` — until relaunch, because nothing here
        // told the Library tab's own model to drop them. `forget()` clears
        // the entries, the shared snapshot and the generation counter that
        // guards a straggling page from the old walk.
        await session.library.forget()
        // The taste ranker built from the previous account's library keeps
        // weighting the stack toward tags that were never this account's
        // until the next relaunch rebuilds it, otherwise.
        stackModel.ranker = nil
        // The reader's own id, used to keep series they already track out of a
        // blend. Left behind, it excludes somebody else's library from their
        // recommendations — and because it is only ever written at launch,
        // signing in mid-session never enabled the exclusion at all until the
        // next relaunch.
        //
        // Item 1: this passed `nil` and *nothing* ever set the new account's
        // id, so every blend until relaunch recommended series the reader
        // already tracks — the bug the paragraph above describes, in the line
        // written to fix it. `forgetProfile()` above has already dropped the
        // cached id, so this asks the client for whoever is signed in now;
        // nil when that is nobody, which is the ordinary signed-out case.
        //
        // Item 15: "nobody" is now answered without asking. This path's
        // commonest trigger is "Remove token", and `profileID()` sent a
        // `/v1/my/profile` that could only ever be a 401 — a spent request
        // against the 180/min ceiling the whole app shares, to learn what the
        // Keychain already knew. The exclusion is nil when signed out either
        // way, so clearing it is the same answer one request cheaper.
        if hasCredentials() {
            await repository.updateLibraryExclusion(userID: await library.profileID())
        } else {
            await repository.updateLibraryExclusion(userID: nil)
        }
        // Pending notifications name series from the previous account's
        // library. Without this, "<title> has finished" arrives on the lock
        // screen for an account the reader has signed out of.
        await reminders.forget()
        await schedule.cancelBuild()
        // Same reason as the reminders: the index names the previous
        // account's library.
        await spotlight.clear()
        // Item 12: sign-out forgot the library, the ranker, the reminders and
        // Spotlight and left `widget-snapshot.json` alone, so the previous
        // account's "Pick back up · Ch. 88 of 120" stayed on the Home Screen
        // — with deep links that still opened.
        WidgetSnapshot.clear()
        // The `v2-naver-*` files hold data obtained from an endpoint this app
        // no longer calls (Q8, 2026-09-14), so serving them would be keeping
        // the fruit of it. A no-op after the first run.
        AppServices.purgeLegacyNaverCache()
    }

    /// The work a launch does once the first screen is on the way.
    ///
    /// One task rather than several: they are not independent — the reminders
    /// depend on the same library the rest of the app is about to read, and
    /// running them as separate tasks meant two library walks on every launch.
    func startSession() async {
        // Gap 3: told once, here, rather than left as a silent fall-through
        // to a database that remembers nothing between launches. One-shot
        // because `startSession` itself only ever runs once per launch — see
        // `RootView.body`'s `.task { await startSession() }`.
        if databaseWasReset {
            // Item 78: the old wording called the lost file "your saved stack
            // and library cache", which understated it — that file also holds
            // the recently-viewed history and the taste ledger, and two doc
            // comments in it still called all of that "disposable cache
            // data". It is also no longer shown for a database that merely
            // could not be opened (`.unopened`), where nothing was lost at
            // all. `AppDatabase.onDiskResettingIfCorrupt` now attempts a
            // salvage of the saves and the history, which is why this says
            // "where they could be read" rather than promising either way.
            toasts.show(
                "A local file was damaged and had to be replaced. Your saves and recently-viewed "
                    + "were copied over where they could be read, and your library will reload. "
                    + "Nothing in your MangaBaka account is affected.",
                kind: .failure
            )
        }
        if !onboarding.hasCompleted, onboardingCovers.isEmpty {
            onboardingCovers = await repository.feed(.rising, forceRefresh: false).series
        }
        // Gap 63: told apart from the settled state — empty because the feed
        // genuinely failed, or because onboarding was already finished and
        // nothing was asked for — only once this has actually run.
        isLoadingCovers = false
        // Dates move and series leave the library, and iOS holds the pending
        // list between launches — so it is corrected on return rather than kept
        // alive by anything running in the background.
        await refreshReminders()
        // After the reminders, which already walked the library: the snapshot
        // is cached now, so this costs no request.
        //
        // Gap 104: a walk that failed used to still wipe and rebuild the
        // index from whatever partial (or empty) result it produced — a
        // reader offline on launch had yesterday's index erased and replaced
        // with nothing. `load()` (not `all()`, which throws the failure
        // away) is checked first so a failed walk leaves yesterday's index
        // standing, the same rule `reschedule` already applies to reminders.
        let walk = await librarySnapshot.load()
        guard walk.failure == nil else {
            // Item 12: a walk that fails because there is no account is not a
            // transient failure — the library the widget is still showing
            // belongs to a reader who is no longer signed in. Everything else
            // (offline, a 500) leaves the last good snapshot standing, the
            // same rule the Spotlight index follows two lines down.
            if walk.failure?.needsAccount == true {
                WidgetSnapshot.write(pickBackUp: [])
                // The other surface outside the app that names the previous
                // account's series. The widget was cleared here and the
                // index was not, so with no token the Home Screen tile went
                // blank while iOS search still offered "Ch. 88 of 120" for a
                // library the app no longer has — and tapping a result still
                // opened it (walk, 2026-09-14). `LibrarySnapshot` now
                // answers a signed-out ask with this failure rather than
                // with the previous account's cache, which is what makes
                // this branch reachable at all.
                await spotlight.clear()
                // And the third one the walk found: Settings → Data Used
                // read "Taste profile: 945 series counted · 3175 tags known"
                // on an install with no account, which is the same 945 the
                // Library header was claiming — the ledger `absorb` filled
                // from the previous account's library and nothing removes
                // from. `forgetEverything` is the existing clear; the point
                // of calling it from here is that this is an invariant
                // checked on every launch ("no credential, no
                // account-scoped data") rather than a ninth line on a
                // forget list that has to be remembered at each of the three
                // ways to change account. It rebuilds from the first
                // successful walk after a token is added, so a transient 401
                // costs nothing but that walk.
                await taste.forgetEverything()
            }
            return
        }
        // Item 7: `session.library.entries` was filled only by `LibraryView`'s
        // own `.task`, so Discover's "Pick back up" row and its chapters-read
        // figure were empty on every cold launch until the Library tab was
        // visited — although the walk above had already happened. This returns
        // the snapshot that walk just cached, so it costs no request.
        await session.library.load()
        await spotlight.reindex(walk.entries)
        let lastOpened = (try? await history.lastOpenedDates()) ?? [:]
        WidgetSnapshot.write(
            pickBackUp: WidgetSnapshot.pickBackUpItems(from: walk.entries, lastOpened: lastOpened)
        )
    }

    /// Opens the series a Spotlight result named, from the library walk.
    ///
    /// The snapshot, not a request: the item was indexed from it, and the
    /// series it holds is the one the reader's state is attached to. A series
    /// that has since left the library is simply not opened — the index is
    /// rebuilt on the next launch.
    /// Opens any series by id, from a link. The library first — no request,
    /// and the reader's own copy — then the series record, which is the
    /// request the page would make on arrival anyway. Discover, because a
    /// link is a door into the app rather than into the reader's shelf.
    func openSeries(id: Int) async {
        // `.entries`: showing the reader their own row if it arrived is
        // better than refusing because the walk was partial.
        if let mine = await librarySnapshot.load().entries.first(where: { $0.seriesId == id })?.series {
            selection = .library
            shelfPath = [mine]
            return
        }
        // Gap 76: a second "Open X" arriving while this one is still awaiting
        // `extras` cancels this task (`.task(id: bridge.pending?.token)` in
        // `RootView.body` restarts on a new token) but nothing here noticed —
        // the cancelled call kept running to completion and could still land
        // its own `discoverPath` assignment after the newer one had already
        // set the right series, leaving the reader on the wrong page.
        guard !Task.isCancelled else { return }
        // One read for one series (gap 62) — the page it opens fetches the
        // rest itself.
        guard let series = await repository.series(id: id) else {
            // Gap 61: this used to `return` with nothing said, so a link to a
            // merged, removed, or momentarily unreachable series looked like
            // a dead tap — Siri, Spotlight and a mangabaka.org link all
            // landed on whichever tab was already open, in silence.
            toasts.show("That series isn't available right now", kind: .failure)
            return
        }
        guard !Task.isCancelled else { return }
        selection = .discover
        discoverPath = [series]
    }

    func openFromSpotlight(seriesID: Int) async {
        // `.entries`: a partial walk can still hold the row Spotlight
        // matched, and opening it beats refusing.
        let entries = await librarySnapshot.load().entries
        guard !Task.isCancelled else { return }
        guard let series = entries.first(where: { $0.seriesId == seriesID })?.series else {
            // Gap 61: a series Spotlight indexed yesterday that has since
            // left the library (a state changed on another device, a
            // removal) tapped in silence rather than saying why nothing
            // opened.
            toasts.show("That series isn't available right now", kind: .failure)
            return
        }
        selection = .library
        shelfPath = [series]
    }

    /// Notifies about whatever is newly true: a confirmed release, or a
    /// series the reader is reading or paused on finishing or ending a
    /// season. Called at launch, when the switch moves, and when the app
    /// comes back from the background — `RootView.foregroundChanged(to:)`,
    /// added for item 11, which is the handler this comment promised for a
    /// batch before one existed. See `NotificationPolicy` for the two
    /// conditions and `ReleaseReminders` for why nothing here rebuilds a
    /// calendar anymore.
    func refreshReminders() async {
        guard reminders.isEnabled else {
            await reminders.reschedule(announced: [])
            return
        }

        let walk = await librarySnapshot.load()
        // Nil rather than a partial set: a reminder scheduled from half a
        // library is a notification about a series the reader may not track,
        // and silence is the better failure here.
        guard let mine = walk.wholeLibrarySeriesIDs else { return }
        let announced = await calendar.mine(seriesIDs: mine)
        // Followed publishers: once a day per follow, one search each. No
        // `notify` closure — Abdi's rule (2026-09-13) is two conditions only,
        // and a publisher follow is neither; the check still runs so
        // `lastSeenSeriesID` stays current for whenever this list does notify.
        await publisherFollows.value.check(using: repository)
        // Whatever a prior series-page visit already cached — never a fetch:
        // this reads the six-hour detail cache and nothing else, so the call
        // site still costs zero requests. A series with nothing cached (never
        // opened this run) simply supplies no links, and `cachedFeeds`
        // reports nothing for it. Read ahead of `cachedFeeds` because that
        // method's own `links` closure is synchronous — it is a pure lookup
        // over providers' caches, not a place to await anything.
        //
        // Item 64: this was `await repository.cachedExtras(for:)` once per
        // entry — 939 actor hops on the launch path, each a SQLite read and a
        // full `SeriesExtras` decode, for a cache that only holds series
        // opened in the last six hours (so ~939 misses). One hop now, one
        // `WHERE seriesId IN (…)`, returning only the links. Signposted so
        // the before/after is a number rather than an argument.
        let linksByID = await Signposts.measure("Reminder links") {
            await repository.cachedExtrasLinks(for: walk.entries.map(\.seriesId))
        }
        let feeds = await releaseFeeds.cachedFeeds(for: walk.entries) { linksByID[$0] ?? [] }
        await reminders.reschedule(
            announced: announced,
            library: walk.entries,
            feeds: feeds,
            libraryFailure: walk.failure,
            // Item 8: `isComplete` was never passed, so it took its `true`
            // default and `performReschedule`'s guard — the one that refuses
            // to schedule off a walk cut short at the page cap — was dead
            // code from the day it was written. `walk.isComplete` is the same
            // `walk` the entries above come from.
            isComplete: walk.isComplete
        )
    }

    /// Writes a change to the reader's real library, then patches the entry
    /// in place rather than re-walking the whole library to see it.
    ///
    /// Gap 88 / decision 5: this used to call `session.library.reload()` on
    /// every save — thirteen requests and 24.7 MB on a real account, to
    /// reflect one changed row, and the sheet stayed open the whole time.
    /// `LibraryModel.apply(_:to:)` patches the entry in memory and in the
    /// shared snapshot's disk cache for one request's cost: the write
    /// itself. A full `reload()` only runs when the entry was not already
    /// loaded — a series added for the first time has no local row to patch
    /// — so the common case (editing something already on screen) is the
    /// cheap path and the uncommon one still ends up correct.
    func saveLibraryChange(seriesId: Int, change: LibraryChange) async -> String? {
        do {
            try await library.update(seriesId: seriesId, change: change)
        } catch {
            return error.userFacingMessage
        }
        let wasLoaded = session.library.entries.contains { $0.seriesId == seriesId }
        if wasLoaded {
            await session.library.apply(change, to: seriesId)
        } else {
            await session.library.reload()
        }
        toasts.show("Saved")
        return nil
    }
}

extension RootView {
    /// One series page, from a push that named only that series.
    ///
    /// Split out of `detail(_:path:neighbours:)` so that function can choose,
    /// with a plain `if`, between this and a `SeriesPager` wrapping several —
    /// a `@ViewBuilder` `if`/`else` needs both branches to be built the same
    /// way, and this is that shared way.
    private func detailPage(_ series: Series, path: Binding<[Series]>) -> SeriesDetailView {
        SeriesDetailView(
            series: series,
            repository: repository,
            library: library,
            libraryStore: session.library,
            schedule: schedule,
            characters: characters,
            taste: taste,
            embeddingIndex: embeddingIndex,
            offlineCatalogue: offlineCatalogue,
            appleBooks: appleBooks,
            googleBooks: googleBooks,
            releaseFeeds: releaseFeeds,
            mangaUpdatesCategories: mangaUpdates,
            openLibrary: openLibraryCovers,
            ann: ann,
            openLibraryEditions: openLibraryEditions,
            ndl: ndl,
            wikidata: wikidata,
            onOpenPublisher: { openPublisher = PublisherRoute(name: $0, kind: .publisher) },
            onOpenAuthor: { openPublisher = PublisherRoute(name: $0, kind: .author) },
            contentRatings: content.preferences.allowed.map(\.rawValue),
            path: path,
            // Gap 77: see `useAsSeedTapped` in `RootView+Failures.swift`.
            onUseAsSeed: useAsSeedTapped,
            onOpenTag: { tag in
                // `openTag`, not a raw assignment plus `search()`: it
                // remembers the text it applied so the field's own change
                // observer does not schedule a second, identical request
                // 300ms later (two calls per tap against a 30 req/min budget
                // shared with everyone on the same network — see
                // `SearchModel.queryDidChange`), it cancels any keystroke
                // debounce already pending, and it sets a stable sort. The
                // sort matters beyond tidiness: without one the API is free
                // to reorder between pages, and this app pages by asking for
                // page 2 and dropping ids it has already seen. Not
                // `applyBrowse`, which since 2026-09-13 adds to the query
                // (UX#11): a tag from a series page replaces the last search,
                // which may be an hour old and about something else.
                searchModel.openTag(tag)
                // Item 21: the tag is most often tapped on a series page
                // reached *from* Search, and that page sits on `searchPath`.
                // Switching the tab without popping it changed the results
                // underneath a detail page that stayed on top, so the tap did
                // nothing visible — one spent search request and no sign of
                // it. Popping is what the tab bar's own re-tap already does
                // (`RootView+Tabs.popToRoot`); this path never called it.
                searchPath.removeAll()
                selection = .search
            },
            onOpenSchedule: {
                selection = .library
                showsSchedule = true
            }
        )
    }

    /// A series page, and — when the row that pushed it had siblings —
    /// the ability to swipe sideways to the next or previous one.
    ///
    /// `neighbours` defaults to `[]`, and fewer than two neighbours renders
    /// exactly the plain `detailPage` this function always returned: no
    /// existing call site changes behaviour until a row actually starts
    /// passing its siblings. None does yet — see this feature's report for
    /// the one-line change each row's push would need.
    func detail(_ series: Series, path: Binding<[Series]>, neighbours: [Series] = []) -> some View {
        // The row that pushed this series recorded its siblings on the zoom
        // route; a push from anywhere else (a link, Siri, a related row that
        // did not record) pages nowhere.
        //
        // The membership check is not the guarantee this comment used to
        // claim (item 122). It rejects a stale row that does not contain this
        // series, but a related-series tap for a series that *is* in the
        // originating row passes it and wraps the new page in the wrong list.
        // The fix is at the push sites, which clear `neighbours` beside each
        // `source =`; this is the second half of it, not the whole guard.
        let siblings = neighbours.isEmpty && zoomRoute.neighbours.contains(where: { $0.id == series.id })
            ? zoomRoute.neighbours
            : neighbours
        return Group {
            if siblings.count > 1 {
                // `onSettle`, not the old `selected: .constant(series)`
                // binding (item 123): that wrote into a constant, so every
                // swipe was silently dropped and only the pushed series was
                // ever recorded. Nothing broke, which was the problem.
                SeriesPager(
                    items: siblings,
                    selected: series,
                    onSettle: { current in
                        Task { await session.recentlyViewed.record(current) }
                    },
                    content: { neighbour in detailPage(neighbour, path: path) }
                )
            } else {
                detailPage(series, path: path)
            }
        }
        // Opening the page is what counts as having viewed it. Recorded here
        // rather than inside the detail view so every route into it — a feed,
        // the stack, search, a related-series row — is remembered the same way.
        //
        // This records the series the push named. A neighbour the reader
        // swipes to inside the pager is recorded by the `onSettle` above,
        // which fires once per page that actually settles on a different
        // series and never for the one the pager opened on — so a swipe is
        // remembered exactly once, and never twice.
        .task { await session.recentlyViewed.record(series) }
        // The publisher page, pushed on whichever stack this page is in. A
        // series it lists pushes back onto the same path.
        .navigationDestination(item: $openPublisher) { route in
            PublisherView(
                name: route.name, kind: route.kind, catalogue: catalogue,
                repository: repository, path: path, follows: publisherFollows.value
            )
        }
        // Grows out of the cover that was tapped. Every screen that pushes a
        // series marks its covers with `.zoomSource`; a route that did not
        // falls through to the ordinary push, which is what an unmatched id
        // already does. A pager's neighbour pages were never the tapped
        // cover, so they fall through the same way — only the page the
        // reader actually tapped into can zoom.
        .navigationTransition(.zoom(sourceID: zoomRoute.source ?? "none", in: coverTransition))
    }
}
