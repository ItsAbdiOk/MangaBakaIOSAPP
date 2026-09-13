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
                            onOpenShelf: { state in
                                openShelf = session.library.shelves.first { $0.state == state }
                            },
                            onOpenSettings: { showsSettings = true },
                            onOpenStack: { selection = .stack },
                            onSave: saveLibraryChange,
                            continuations: continuations
                        )
                            .navigationDestination(for: Series.self) { detail($0, path: $shelfPath) }
                            .navigationDestination(item: $openShelf) { shelf in
                                ShelfDetailView(
                                    shelf: shelf,
                                    path: $shelfPath,
                                    onSave: saveLibraryChange
                                )
                            }
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
                                    catalogueSize: session.pulse.pulse.map { Int($0.activeSeriesCount) }
                                        ?? ReadingWrapped.catalogueSizeOn20260911,
                                    path: $shelfPath
                                )
                            }
                            .navigationDestination(isPresented: $showsTaste) {
                                // Reading insights rather than the old taste
                                // screen: the same route, six answers instead
                                // of one, and none of them from an endpoint.
                                ReadingInsightsView(
                                    entries: session.library.entries,
                                    path: $shelfPath
                                )
                            }
                            .navigationDestination(isPresented: $showsSchedule) {
                                ScheduleView(
                                    model: ScheduleModel(
                                service: schedule,
                                calendar: calendar,
                                snapshot: librarySnapshot
                            ),
                                    path: $shelfPath
                                )
                            }
                            .navigationDestination(isPresented: $showsSettings) {
                                SettingsView(
                                    validate: validateStoredToken,
                                    content: content,
                                    formats: formats,
                                    blockedTags: blockedTags,
                                    catalogue: catalogue,
                                    focusAccount: wantsAccountFocus,
                                    reminders: reminders,
                                    publisherFollows: publisherFollows,
                                    onRemindersChanged: { await refreshReminders() },
                                    history: history,
                                    taste: taste,
                                    onAccountChanged: { await forgetPreviousAccount() },
                                    titleRevision: $titleRevision
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
        await taste.forgetEverything()
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
        stackModel?.ranker = nil
        // The reader's own id, used to keep series they already track out of a
        // blend. Left behind, it excludes somebody else's library from their
        // recommendations — and because it is only ever written at launch,
        // signing in mid-session never enabled the exclusion at all until the
        // next relaunch.
        await repository.updateLibraryExclusion(userID: nil)
        // Pending notifications name series from the previous account's
        // library. Without this, "<title> has finished" arrives on the lock
        // screen for an account the reader has signed out of.
        await reminders.forget()
        await schedule.cancelBuild()
        // Same reason as the reminders: the index names the previous
        // account's library.
        await spotlight.clear()
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
            toasts.show(
                "A local file couldn't be read, so your saved stack and library cache were reset. "
                    + "Anything in your MangaBaka account is unaffected.",
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
        guard walk.failure == nil else { return }
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
        if let mine = await librarySnapshot.all().first(where: { $0.seriesId == id })?.series {
            selection = .library
            shelfPath = [mine]
            return
        }
        // Gap 76: a second "Open X" arriving while this one is still awaiting
        // `extras` cancels this task (`.task(id: bridge.pendingSeriesID)` in
        // `RootView.body` restarts on a new id) but nothing here noticed —
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
        let entries = await librarySnapshot.all()
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
    /// season. Called when the switch moves and when the app comes back to
    /// the foreground — see `NotificationPolicy` for the two conditions and
    /// `ReleaseReminders` for why nothing here rebuilds a calendar anymore.
    func refreshReminders() async {
        guard reminders.isEnabled else {
            await reminders.reschedule(announced: [])
            return
        }

        let announced = await calendar.mine(seriesIDs: await librarySnapshot.seriesIDs())
        let walk = await librarySnapshot.load()
        // Followed publishers: once a day per follow, one search each. No
        // `notify` closure — Abdi's rule (2026-09-13) is two conditions only,
        // and a publisher follow is neither; the check still runs so
        // `lastSeenSeriesID` stays current for whenever this list does notify.
        await publisherFollows.check(using: repository)
        // Whatever a prior series-page visit already cached — never a fetch:
        // `cachedExtras` reads the six-hour detail cache and nothing else, so
        // this call site still costs zero requests. A series with nothing
        // cached (never opened this run) simply supplies no links, and
        // `cachedFeeds` reports nothing for it, the same as before this batch.
        // Read one entry at a time, ahead of `cachedFeeds`, because that
        // method's own `links` closure is synchronous — it is a pure
        // lookup over providers' caches, not a place to await anything.
        var cachedLinks: [Int: [SeriesLink]] = [:]
        for entry in walk.entries {
            cachedLinks[entry.seriesId] = await repository.cachedExtras(for: entry.seriesId)?.links ?? []
        }
        let linksByID = cachedLinks
        let feeds = await releaseFeeds.cachedFeeds(for: walk.entries) { linksByID[$0] ?? [] }
        await reminders.reschedule(
            announced: announced,
            library: walk.entries,
            feeds: feeds,
            libraryFailure: walk.failure
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
        openShelf = session.library.shelves.first { $0.state == openShelf?.state }
        return nil
    }
}

extension RootView {
    /// One place for the search model's construction: the offline catalogue
    /// and the three preference closures it answers from when the network
    /// cannot. Out of `RootView` itself, which sits at the body-length cap.
    func makeSearchModel() -> SearchModel {
        SearchModel(
            repository: repository,
            offline: offlineCatalogue,
            allowedRatings: { content.preferences.queryValues },
            allowedFormats: { formats.preferences.queryValues },
            blockedTagIDs: { blockedTags.blocked.ids }
        )
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
            mangaUpdatesCategories: mangaUpdatesCategories,
            openLibrary: openLibraryCovers,
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
                searchModel?.openTag(tag)
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
        // did not record) pages nowhere. Only trusted when the series is
        // actually in the list — a stale row from an earlier tap is not this
        // page's row.
        let siblings = neighbours.isEmpty && zoomRoute.neighbours.contains(where: { $0.id == series.id })
            ? zoomRoute.neighbours
            : neighbours
        return Group {
            if siblings.count > 1 {
                SeriesPager(items: siblings, selected: .constant(series)) { neighbour in
                    detailPage(neighbour, path: path)
                }
            } else {
                detailPage(series, path: path)
            }
        }
        // Opening the page is what counts as having viewed it. Recorded here
        // rather than inside the detail view so every route into it — a feed,
        // the stack, search, a related-series row — is remembered the same way.
        //
        // Records only the series the push named, not whichever one the
        // reader has since swiped to inside the pager — `SeriesPager` holds
        // its own current selection internally (see its `selected` binding
        // above, a fixed `.constant` here since nothing outside the pager
        // needs to read it yet). Recording every page swiped past is a
        // reasonable next step but not one this task asked for.
        .task { await session.recentlyViewed.record(series) }
        // The publisher page, pushed on whichever stack this page is in. A
        // series it lists pushes back onto the same path.
        .navigationDestination(item: $openPublisher) { route in
            PublisherView(
                name: route.name, kind: route.kind, catalogue: catalogue,
                repository: repository, path: path, follows: publisherFollows
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
