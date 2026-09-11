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
                            onSave: saveLibraryChange
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
                                    catalogueSize: session.pulse.pulse?.activeSeriesCount
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
                                    validate: validateToken,
                                    content: content,
                                    formats: formats,
                                    blockedTags: blockedTags,
                                    catalogue: catalogue,
                                    focusAccount: wantsAccountFocus,
                                    reminders: reminders,
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
        // The reader's own id, used to keep series they already track out of a
        // blend. Left behind, it excludes somebody else's library from their
        // recommendations — and because it is only ever written at launch,
        // signing in mid-session never enabled the exclusion at all until the
        // next relaunch.
        await repository.updateLibraryExclusion(userID: nil)
        // Pending notifications name series from the previous account's
        // library. Without this, "<title> has finished" arrives on the lock
        // screen for an account the reader has signed out of.
        await reminders.cancelAll()
    }

    /// The work a launch does once the first screen is on the way.
    ///
    /// One task rather than several: they are not independent — the reminders
    /// depend on the same library the rest of the app is about to read, and
    /// running them as separate tasks meant two library walks on every launch.
    func startSession() async {
        if !onboarding.hasCompleted, onboardingCovers.isEmpty {
            onboardingCovers = await repository.feed(.rising, forceRefresh: false).series
        }
        // Dates move and series leave the library, and iOS holds the pending
        // list between launches — so it is corrected on return rather than kept
        // alive by anything running in the background.
        await refreshReminders()
    }

    /// Rebuilds every pending reminder from the current schedule.
    ///
    /// Called when the switch moves and when the app comes back to the
    /// foreground. Not on a timer: iOS holds the pending list itself, so there
    /// is nothing to keep alive between launches — only something to correct
    /// when the underlying dates have moved.
    func refreshReminders() async {
        guard reminders.isEnabled else {
            await reminders.reschedule(announced: [], predicted: [])
            return
        }

        let scheduled = await schedule.snapshot()
        let announced = await calendar.mine(seriesIDs: await librarySnapshot.seriesIDs())

        // A series with an announced date is not also guessed about, for the
        // same reason the Schedule screen drops it: two notices about the same
        // series, one a fact and one an estimate, leave the reader deciding
        // which to believe.
        let announcedIDs = Set(announced.compactMap(\.seriesId))
        let predicted = scheduled.dated.filter { !announcedIDs.contains($0.series.id) }

        let walk = await librarySnapshot.load()
        await reminders.reschedule(
            announced: announced,
            predicted: predicted,
            library: walk.entries,
            libraryFailure: scheduled.libraryFailure ?? walk.failure
        )
    }
}
