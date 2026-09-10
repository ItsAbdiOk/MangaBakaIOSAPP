import SwiftUI

/// Keeping the pending reminders in step with what the app knows.
///
/// Its own file for the lint's body-length ceiling, and because it is one idea:
/// whenever the reader's answer or the app's answer changes, rebuild the list
/// rather than adding to it.
extension RootView {
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

        let snapshot = await schedule.snapshot()
        var ids: Set<Int> = []
        for page in 1...10 {
            let batch = await library.library(page: page, limit: 100)
            if batch.isEmpty { break }
            ids.formUnion(batch.map(\.seriesId))
            if batch.count < 100 { break }
        }
        let announced = await calendar.mine(seriesIDs: ids)

        // A series with an announced date is not also guessed about, for the
        // same reason the Schedule screen drops it: two notices about the same
        // series, one a fact and one an estimate, leave the reader deciding
        // which to believe.
        let announcedIDs = Set(announced.compactMap(\.seriesId))
        let predicted = snapshot.dated.filter { !announcedIDs.contains($0.series.id) }

        await reminders.reschedule(announced: announced, predicted: predicted)
    }
}
