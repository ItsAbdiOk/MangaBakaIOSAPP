import Foundation

/// What the current queue is actually built from.
///
/// Exposed so the screen can say so. "Are you sure it's using my tastes?" is
/// a fair question to ask of any recommender, and the honest answer depends
/// entirely on which of these it is — a random queue is not personalised at
/// all, and the app should not imply otherwise.
///
/// Declared outside `StackModel`'s own braces (in an extension below) rather
/// than nested directly in the class, so its body does not count against
/// `type_body_length` on a class already carrying most of the Stack's logic.
enum StackModelSource: Equatable {
    /// MangaBaka's own profile-based recommendations, built from the
    /// reader's whole library rather than from a handful of seeds.
    case yourProfile
    /// Blended from series saved on this device.
    case yourSaves
    /// Blended from the reader's MangaBaka library.
    case yourLibrary
    /// A random sample. Nothing to personalise from yet.
    case random
    /// The profile recommender could not even be asked — offline, rate
    /// limited, a server error — as distinct from `.random`, which means
    /// there is genuinely nothing on file to personalise from. A failed
    /// check used to collapse to the same `false` as a real cold-start
    /// answer and stay cached for the rest of the session, so a reader with
    /// 300 series on file was told "save a few to make it yours" until
    /// relaunch (gap 107/108, FAILURES-SUMMARY.md K6/K7).
    case unavailable(APIError)

    /// One line under the title saying where the cards came from. This was
    /// stored "so the screen can say" and the screen never said it — a
    /// random queue and a personalised one looked identical.
    var caption: String {
        switch self {
        case .yourProfile: "Picked from your MangaBaka library"
        case .yourSaves: "Blended from what you have saved here"
        case .yourLibrary: "Blended from your MangaBaka library"
        case .random: "A random sample — save a few to make it yours"
        case .unavailable: "Couldn't reach your library — showing a random sample"
        }
    }
}

/// A warning about the save that just happened, and the series it happened to.
///
/// Paired with the id because `react` advances the queue before the write
/// completes, so a bare string was rendered under the *next* card — a series
/// the reader had not saved — and stayed there through every subsequent skip
/// until a later save cleared it.
///
/// `localFailure` is true only when the on-device shelf write itself failed
/// — as opposed to the write landing locally but not reaching the reader's
/// MangaBaka library. That distinction is what `StackModel.shouldConfirmSave`
/// reads: a local failure must not be confirmed as "Saved here" (gap 36,
/// FAILURES-SUMMARY.md K8), but a library-only failure still is, because the
/// local save is real. A struct rather than a tuple so `swiftlint`'s
/// `large_tuple` stays quiet and so `StackSaveTests` has a name to construct.
struct StackSaveWarning: Equatable {
    let seriesId: Int
    let message: String
    let localFailure: Bool
}

/// Backing state for the swipe stack.
@MainActor
@Observable
final class StackModel {
    typealias Source = StackModelSource

    /// What to tell the reader after a save, once the model knows where it
    /// went. A save that reached the MangaBaka library and one that only the
    /// local shelf holds are different outcomes, and the toast used to say
    /// nothing for either.
    var saveConfirmation: String {
        lastSaveWentToLibrary ? "Saved to your library" : "Saved here"
    }

    private(set) var queue: [Series] = []
    private(set) var isLoading = false
    private var refillTask: Task<Void, Never>?
    /// Set when the queue is empty because the last fetch actually failed —
    /// offline, rate-limited, a server error — as opposed to being genuinely
    /// exhausted. `EmptyState` used to be shown for both (gap 33,
    /// FAILURES-SUMMARY.md K1): no mark, no countdown, and a reader who was
    /// simply offline read "Can't load the stack" as if nothing were left to
    /// try.
    ///
    /// Also set when a stale batch's every entry had already been reacted to:
    /// `FeedResult.blockingError` only fires when `series` itself came back
    /// empty, but a `.staleAfter` batch that is non-empty on the wire and
    /// empty only after local filtering is still a failure the reader cannot
    /// see (gap 34, K2) — "That's today's stack" the offline network never
    /// actually answered.
    private(set) var failure: APIError?
    private(set) var source: Source = .random
    /// Set when the profile recommender came back explicitly cold-start on a
    /// signed-in reader with a real library — not "nothing to personalise
    /// from" (which `.random` already says), just "not enough yet". Read by
    /// `caption` so this is not silently indistinguishable from a plain
    /// fallback (gap 108, K7).
    private(set) var isColdStart = false
    /// The `caption` the header actually shows: usually `source.caption`,
    /// overridden while `isColdStart` is true.
    var caption: String {
        isColdStart ? "Dealing from the catalogue while your library is small" : source.caption
    }
    /// Set when a save reached the reader's MangaBaka library, so the screen
    /// can say where it went rather than leaving them to guess.
    private(set) var lastSaveWentToLibrary = false
    /// Set when a save could not reach the library. The local shelf still has
    /// it, so this is a note rather than a failure.
    /// The warning to show under a given card, or nothing.
    ///
    /// A warning belongs to one series. Asking by id is what stops it appearing
    /// under a card it has nothing to do with.
    func warning(for series: Series) -> String? {
        saveWarning?.seriesId == series.id ? saveWarning?.message : nil
    }

    /// See `StackSaveWarning`'s doc comment.
    private(set) var saveWarning: StackSaveWarning?
    /// Whether `saveConfirmation` should actually be shown after the save
    /// that just happened. False only when the local shelf write failed —
    /// `try?` used to let that pass silently and the toast said "Saved here"
    /// for a write that never reached disk (gap 36, K8).
    var shouldConfirmSave: Bool { saveWarning?.localFailure != true }
    /// Why the current card was suggested, when the source can say. Only the
    /// profile recommender explains itself; a blend does not, and inventing a
    /// reason for it would be worse than showing none.
    var currentReason: String? {
        guard let id = current?.id else { return nil }
        return reasons[id]
    }

    private var reasons: [Int: String] = [:]

    /// Orders each fresh batch by the reader's own tags before it joins the
    /// queue, so a blend or a random draw leads with what they are likeliest
    /// to want. Ported from the sibling Tags Gen project's tag ranker. Not
    /// applied to the profile recommender's batches: MangaBaka already
    /// ranked those, with reasons of its own. Set once from RootView; nil or
    /// empty is a no-op.
    var ranker: TasteRanker?

    /// Covers already saved, newest first, for the strip under the card.
    private(set) var saved: [Series] = []

    /// What this run of the app has got through.
    ///
    /// Deliberately not the shelf's totals. `saved` is every save the reader
    /// has ever made, so "5 saved" from it would be a lifetime figure sitting
    /// under the words "today's stack". These two count what actually happened
    /// since launch, which is the only number the app can state honestly.
    private(set) var seenThisRun = 0
    private(set) var savedThisRun = 0
    /// What the header counts.
    var savedCount: Int { saved.count }

    /// The cover peeking in from the left: the last one reacted to, so the
    /// stack reads as a sequence with a behind and an ahead.
    private(set) var previous: Series?

    private let repository: any SeriesRepositoryProtocol
    private let shelf: ShelfStore
    private let library: (any LibraryProviding)?
    private var reacted: Set<Int> = []

    /// Every series that could seed a blend, and where we are in it.
    ///
    /// `mix` takes no page parameter, so a single set of seeds yields one
    /// batch of at most 50 and then repeats itself forever. Rotating the seeds
    /// is the only way to keep going, and it also keeps the stack from
    /// narrowing onto whichever three series happened to be saved first.
    private var seedPool: [Int] = []
    private var seedCursor = 0
    private static let seedsPerBlend = 3

    /// Page of the profile recommender. It takes `page` and `exclude_ids`, so
    /// unlike a blend it never repeats and never runs out.
    private var recommendationPage = 0
    /// Whether the profile recommender is usable for this reader. Nil until
    /// asked, or when the last check failed rather than answered; false when
    /// there is no token, or the library is too small to build a profile
    /// from. `private(set)` so `StackSourceTests` can pin gap 107 directly —
    /// a failed check must leave this nil, not cache the same `false` a real
    /// cold-start answer produces (see `profileIsUsable`'s doc comment).
    private(set) var canUseProfile: Bool?
    /// Set when `recommendationStatus()` or `recommendations()` threw, as
    /// opposed to answering with a genuinely small or empty library. Read by
    /// `buildSeedPoolIfNeeded` so a random fallback caused by a failed check
    /// says so (`Source.unavailable`) instead of reading identically to a
    /// reader with nothing on file yet (gap 107/108, K6/K7).
    private var profileFailure: APIError?

    init(
        repository: any SeriesRepositoryProtocol,
        shelf: ShelfStore,
        library: (any LibraryProviding)? = nil
    ) {
        self.repository = repository
        self.shelf = shelf
        self.library = library
    }

    var current: Series? { queue.first }
    var next: Series? { queue.count > 1 ? queue[1] : nil }

    func loadIfNeeded() async {
        await refreshSaved()
        guard queue.isEmpty else { return }
        await refill()
    }

    /// Tops the queue up, or joins the top-up already in progress.
    ///
    /// Three places call this — first load, every reaction that leaves two
    /// cards, and the empty state's retry — and they overlap in practice: a
    /// quick second swipe lands while the first swipe's refill is still
    /// fetching. Each overlap used to be a second feed request for the same
    /// stack, against a limit shared with strangers. A caller that finds a
    /// refill in flight now waits for that one instead.
    func refill() async {
        if let refillTask {
            await refillTask.value
            return
        }
        let task = Task { await performRefill() }
        refillTask = task
        await task.value
        refillTask = nil
    }

    private func refreshSaved() async {
        saved = ((try? await shelf.entries(.saved).series) ?? [])
    }

    private func performRefill() async {
        isLoading = true
        defer { isLoading = false }

        reacted = (try? await shelf.reactedIDs()) ?? []
        // Reset each cycle rather than left over from a previous refill —
        // otherwise a caption earned by a cold-start answer minutes ago could
        // outlive it and mislabel an ordinary blend fallback.
        isColdStart = false

        // The profile recommender first, when the reader has one. It draws on
        // their whole library rather than three seeds, it explains each pick,
        // and it pages — so it is strictly better than a blend wherever it is
        // available.
        if await profileIsUsable() {
            let fresh = await fetchProfilePage()
            if !fresh.isEmpty {
                append(fresh)
                source = .yourProfile
                failure = nil
                return
            }
            // Exhausted or failed: fall through to a blend rather than showing
            // an empty stack to someone who plainly has taste on file.
            // `fetchProfilePage` has already recorded `profileFailure` if that
            // was the reason, for `buildSeedPoolIfNeeded`'s fallback caption.
        }

        await buildSeedPoolIfNeeded()

        // Two attempts, not one. The first can come back entirely composed of
        // series already reacted to, which used to empty the stack and show
        // "that's the stack for now" while more was plainly available.
        for _ in 0..<2 {
            let fresh = await fetchBatch()
            if !fresh.isEmpty {
                append(fresh)
                failure = nil
                return
            }
            guard advanceSeeds() else { break }
        }

        // Nothing left to offer. `failure` is whatever the last fetch set: an
        // error if one occurred, nil if the queue is genuinely exhausted. The
        // empty state reads those two cases differently (gap 33/34, K1/K2).
    }

    /// Adds to the queue rather than replacing it.
    ///
    /// A refill starts while two cards are still in hand, so replacing threw
    /// away two series the reader had not seen yet — every time the stack
    /// topped itself up, which is constantly.
    private func append(_ series: [Series]) {
        let known = Set(queue.map(\.id))
        var fresh = series.filter { !known.contains($0.id) }
        if let ranker, !ranker.isEmpty, source != .yourProfile {
            fresh = ranker.rank(fresh) { $0 }
            // "Shares Regression, Action with what you read": the ranker's
            // matches, where the source had no reason of its own.
            for item in fresh where reasons[item.id] == nil {
                let shared = ranker.reasons(for: item)
                if !shared.isEmpty {
                    reasons[item.id] = "Shares \(shared.joined(separator: ", ")) with what you read"
                }
            }
        }
        queue.append(contentsOf: fresh)
    }

    /// Empties the stack and starts again from nothing.
    ///
    /// The stack blends what comes next from what has been saved, so a handful
    /// of swipes in a direction the reader did not mean sends every subsequent
    /// card the same way, with no way back — there is no "unswipe". This is the
    /// way back.
    ///
    /// Clears the local shelf, the reacted set and the seed pool, then reloads.
    /// It does not touch the reader's MangaBaka library: a save also wrote
    /// `plan_to_read` there, and silently deleting rows from someone's account
    /// is a bigger action than the one being asked for.
    ///
    /// - Returns: whether the shelf actually cleared. `try?` used to let a
    ///   throw (a full disk, a locked file) pass silently: the in-memory state
    ///   was wiped and the caller confirmed "The stack has been reset" while
    ///   the database still held every save, which came back on next launch
    ///   (gap 37, FAILURES-SUMMARY.md K11). `(try? await shelf.clear()) !=
    ///   nil` keeps the same `try?` call — read by `NonsenseGuardTests` — while
    ///   still reporting success, since `shelf.clear()` throws `Void`.
    @discardableResult
    func resetStack() async -> Bool {
        let cleared = (try? await shelf.clear()) != nil
        reacted = []
        saved = []
        queue = []
        previous = nil
        seedPool = []
        saveWarning = nil
        await loadIfNeeded()
        return cleared
    }

    func react(_ kind: ShelfEntry.Kind) async {
        guard let series = current else { return }
        saveWarning = nil
        queue.removeFirst()
        reacted.insert(series.id)
        seenThisRun += 1
        if kind == .saved { savedThisRun += 1 }
        // The card just dealt with becomes the one peeking in from behind.
        previous = series
        // `Void?` from `try?` doubles as a success flag here: `shelf.record`
        // throws no value to inspect, but `!= nil` still tells success from
        // failure. `try?` used to be the whole story — `saved.insert` and the
        // "Saved here" toast fired even when this write never reached disk
        // (gap 36, FAILURES-SUMMARY.md K8).
        let recorded = (try? await shelf.record(series, as: kind)) != nil
        if kind == .saved {
            if recorded {
                saved.insert(series, at: 0)
                await pushSaveToLibrary(series)
                // A save changes what the next blend should be built from, so
                // the pool is rebuilt rather than left pointing at the shelf
                // as it was on load. Only when the save actually landed —
                // nothing changed on disk otherwise.
                seedPool = []
            } else {
                lastSaveWentToLibrary = false
                saveWarning = StackSaveWarning(
                    seriesId: series.id, message: "Couldn't save — try again.", localFailure: true
                )
            }
        }

        if queue.count <= 2 { await refill() }
    }

    /// A save on the stack also puts the series in the reader's real library.
    ///
    /// Without this the app kept two lists of saved things: a local shelf
    /// MangaBaka never saw, and the account's own library. Two lists of saved
    /// things is confusing, and the local one had no home once Library replaced
    /// the Shelf tab.
    ///
    /// It goes in as "plan to read", which is what a save on a discovery
    /// surface actually means — not that it is being read.
    ///
    /// A skip stays local. MangaBaka has no concept of "not for me", and
    /// writing "dropped" to a library for something never opened would be a
    /// lie about the reader's history.
    private func pushSaveToLibrary(_ series: Series) async {
        guard let library else { return }
        do {
            // `add` answers false when the entry already existed, which is
            // still a series that is in the library — the distinction the flag
            // records is "is it there", not "did we put it there just now".
            _ = try await library.add(seriesId: series.id, state: .planToRead)
            lastSaveWentToLibrary = true
            saveWarning = nil
        } catch {
            // The shelf already has it, so this is worth mentioning rather than
            // undoing. Losing the save would be worse than a stale library.
            lastSaveWentToLibrary = false
            saveWarning = StackSaveWarning(
                seriesId: series.id,
                message: "Saved here, but not to your MangaBaka library.",
                localFailure: false
            )
        }
    }

    // MARK: - Profile recommendations

    /// Whether the profile recommender is usable for this reader.
    ///
    /// A typed throw rather than `try?` into `nil`: `recommendationStatus()`
    /// throwing (offline, rate-limited, a server error) is not the same fact
    /// as it answering with a real cold-start library, but collapsing both to
    /// `false` — and then caching that `false` for the rest of the session —
    /// told a reader with 300 series on file "save a few to make it yours"
    /// until relaunch (gap 107, FAILURES-SUMMARY.md K6). Only a genuine answer
    /// is cached; a failure leaves `canUseProfile` nil so the next `refill()`
    /// asks again, and records `profileFailure` so the fallback caption can
    /// say the check failed rather than pretend nothing is there yet.
    private func profileIsUsable() async -> Bool {
        if let canUseProfile { return canUseProfile }
        guard let library else {
            canUseProfile = false
            return false
        }
        do {
            // cold_start means the library is too small to build a profile
            // from. Asking anyway would spend a request to be told nothing.
            let status = try await library.recommendationStatus()
            canUseProfile = status.canPersonalise
            profileFailure = nil
            return status.canPersonalise
        } catch {
            profileFailure = error
            return false
        }
    }

    private func fetchProfilePage() async -> [Series] {
        guard let library else { return [] }
        recommendationPage += 1

        // Everything already reacted to, sent as exclusions rather than
        // filtered out afterwards. Filtering afterwards wastes the slots: a
        // page of twenty that is half things you have already swiped is a page
        // of ten. Capped because the exclusion list travels in the URL.
        //
        // L4: the sixty most *recently reacted to*, from `ShelfStore`'s own
        // `addedAt` — not `reacted.sorted().suffix(60)`, which was the sixty
        // numerically largest series ids (the most recently catalogued, not
        // the most recently swiped) and, on a long session, sent none of a
        // reader's actual last few sessions.
        let excluded = (try? await shelf.recentlyReactedIDs(limit: Self.maximumExclusions)) ?? []

        // `PersonalRecommendations` carries `failure`/`coldStart` alongside
        // `items` precisely so this does not have to guess why a page is
        // short. Reading `.items` alone (the compile-patch this replaces)
        // silently flipped `source` to a blend or `.random` with no
        // explanation for either cause (gap 108, K7).
        let answer = await library.recommendations(
            limit: 20,
            page: recommendationPage,
            excluding: excluded
        )
        if let error = answer.failure {
            // The page never landed: give it back so the next refill asks for
            // the same page again rather than silently skipping it.
            recommendationPage -= 1
            profileFailure = error
            return []
        }
        profileFailure = nil
        isColdStart = answer.coldStart
        guard !answer.items.isEmpty else { return [] }

        // Nil means the answer is not known, and an unverified tag name is the
        // one outcome worth avoiding here — so an unknown answer hides every
        // named tag rather than none.
        let hidden = await library.hiddenTagIDs()
        for recommendation in answer.items {
            guard let hidden,
                  let summary = recommendation.reason?.summary(hiding: hidden)
            else { continue }
            reasons[recommendation.id] = summary
        }
        // Still filtered locally: exclude_ids is capped, and a skip made on
        // this device is not necessarily known to the server.
        return answer.items.map(\.asSeries).filter { !reacted.contains($0.id) }
    }

    /// A URL has a practical length limit and each id costs about 18
    /// characters. Sixty is well inside it and covers a long session; anything
    /// older is still filtered locally.
    private static let maximumExclusions = 60

    // MARK: - Seeds

    /// Local saves first, then the reader's MangaBaka library, then nothing.
    ///
    /// The library step is what makes a first run personalised for someone who
    /// has a MangaBaka account: without it, a reader with three hundred series
    /// on the site still got a random queue on their first launch, because the
    /// on-device shelf was empty. The token is only present if they entered
    /// one, so this is silently skipped for everyone else.
    private func buildSeedPoolIfNeeded() async {
        guard seedPool.isEmpty else { return }
        seedCursor = 0

        let saved = ((try? await shelf.entries(.saved).series) ?? []).map(\.id)
        if !saved.isEmpty {
            seedPool = saved
            source = .yourSaves
            return
        }

        if let library {
            // Highest priority first, then the ones being read: a series
            // someone dropped says as much about what they don't want.
            let entries = await library.library(page: 1, limit: 50)
            let ids = entries
                .filter { $0.state != .dropped }
                .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
                .map(\.seriesId)
            if !ids.isEmpty {
                seedPool = ids
                source = .yourLibrary
                return
            }
        }

        seedPool = []
        // A random queue caused by a failed profile check is a different fact
        // from a random queue because there is genuinely nothing on file yet
        // — `.unavailable` says so instead of reading as the latter (gap
        // 107/108, K6/K7).
        source = profileFailure.map(Source.unavailable) ?? .random
    }

    /// Moves to the next group of seeds. False when the pool is exhausted.
    private func advanceSeeds() -> Bool {
        guard !seedPool.isEmpty else { return false }
        let next = seedCursor + Self.seedsPerBlend
        guard next < seedPool.count else { return false }
        seedCursor = next
        return true
    }

    private var currentSeeds: [Int] {
        guard seedCursor < seedPool.count else { return [] }
        return Array(seedPool[seedCursor...].prefix(Self.seedsPerBlend))
    }

    private func fetchBatch() async -> [Series] {
        let seeds = currentSeeds
        // mix rejects a seedless request outright ("At least one seed series
        // or one include tag is required", HTTP 400), so an empty pool has to
        // take the random path rather than fail.
        let feed: FeedKind = seeds.isEmpty ? .surprise : .mix(seeds: seeds)
        let result = await repository.feed(feed, forceRefresh: queue.isEmpty)
        let fresh = result.series.filter { !reacted.contains($0.id) }
        if let blocking = result.blockingError {
            failure = blocking
        } else if fresh.isEmpty, case let .staleAfter(error) = result.origin {
            // `blockingError` only fires when `series` itself came back
            // empty. Here the network failed but the stale cache it fell
            // back to happened to be full of entries already reacted to —
            // filtering emptied it, and the screen used to read that as an
            // honest "that's today's stack" instead of the offline/rate-
            // limited answer it actually is (gap 34, FAILURES-SUMMARY.md K2).
            failure = error
        } else {
            failure = nil
        }
        return fresh
    }
}
