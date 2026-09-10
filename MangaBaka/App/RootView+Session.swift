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
                            onOpenShelf: { state in
                                openShelf = session.library.shelves.first { $0.state == state }
                            },
                            onOpenSettings: { showsSettings = true },
                            onOpenStack: { selection = .stack }
                        )
                            .navigationDestination(for: Series.self) { detail($0, path: $shelfPath) }
                            .navigationDestination(item: $openShelf) { shelf in
                                ShelfDetailView(
                                    shelf: shelf,
                                    path: $shelfPath,
                                    onSave: saveLibraryChange
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
                                taste: taste
                                )
                            }
                    }
                }
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

        await reminders.reschedule(
            announced: announced,
            predicted: predicted,
            library: await librarySnapshot.all()
        )
    }
}
