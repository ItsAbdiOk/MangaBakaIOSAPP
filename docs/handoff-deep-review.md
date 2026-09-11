# Handoff — after the deep review, 2026-09-11

Written before compaction. Read this, then `docs/reviews/SUMMARY.md`, then work.

## The order Abdi set, in his words

1. **Fix it all** — every finding from both waves.
2. **The feel of the app** — `docs/feel-plan.md`. "Smooth transitions and animations.
   I want haptics. I want this app to win design awards and I want it to be addictive."
3. **Ship it all** — one push at the end. Then push `apple-idiomatic` too if it changed.

Standing rules unchanged: don't ask, build the best version and say so in the commit;
one finding per commit with evidence; `xcodebuild test` + `swiftlint --strict` before
every commit, and **read the build result, not just the grep** — a broken build got
past the gate once tonight; prove a fix by watching its test fail first; one push at the
end; no GitHub Actions; nothing published; API budget ≤20 uncached req/min, ≤10 on
search, full stop after any 429.

**Grep before you commit a fix.** The charter's headline pattern — a correct rule
applied n−1 times out of n — was reproduced by me, tonight, inside the fix for it:
fixed the credential guard in `SecurityTests`, missed its duplicate in `LibraryTests`.
When you fix an assertion, a setter, a modifier: grep for its siblings first.

## What the review is

`.claude/skills/deep-review/` — ported from MangaTranslator, charter rebuilt from this
project's own failures. **It is gitignored** (`.claude/` is in `.gitignore`); Abdi has not
said whether to track it. Ten agents ran: six slices, four for the directories the first
wave missed, one synthesis. **139 findings.** Reports in `docs/reviews/`:

- `SUMMARY.md` — read first. Ranked table of all wave-one findings, six cross-cutting
  causes, verdicts, contradictions, unknowns.
- `wire.md`, `persistence.md`, `reader.md`, `library-ui.md`, `discovery-ui.md`,
  `surface.md` — wave one.
- `auth-notifications.md`, `images-characters.md`, `remaining-screens.md`, `tests.md`
  — wave two. **Not in SUMMARY.md** — synthesis ran before they landed. Read them
  directly; their top findings are listed below.

## Fixed and committed (7 commits since the last push)

- `d8df026` — Abdi's layout bug (schedule to one line in the hero column, byline
  removed); `DetailCredits`/`TrackerScores` reading the unmerged series (S-F1); the
  `convertFromSnakeCase` scare settled as a false positive with a control test.
- `2f78286` — every cache declares what invalidates it (`CacheScope` in
  `SeriesRepository+Cache.swift`); the every-launch cache wipe (P-F1); exclusion id
  and reminders added to account reset (P-F2, A3); "Remove token" now resets (A1); the
  credential guard checks the value.
- `fae9a29` — the credential guard's duplicate in `LibraryTests`, via a shared
  `Xcconfig` helper.

## Still to fix — in this order

Use `SUMMARY.md` §3's table for wave one. Wave two's top items are folded in here.
"Certain" unless marked.

**Rate limit and network (Abdi: "I don't want you getting banned")**
- W6 — every write bypasses the rate-limit gate, both directions. `APIClient.swift`
  `send()` never checks `secondsUntilAllowed()` nor records a 429. Function.
- R6 — `MangaUpdatesClient.swift:141-152` sleeps before writing `nextAllowedRequest`;
  the `await` releases the actor. Two overlapping callers fire two requests. Line.
- D-A1 — `StackModel.refill()` no in-flight guard; `loadIfNeeded` has one. Line.
- D-B1 — `SearchModel.loadMore` no query generation; stale page appended to new
  search. Function.
- D-A2 — every DNA chip tap is a blend, no debounce. Function.
- IC-F1 — **covers fetched at up to 7× the pixels drawn**. `Cover.swift:111-121` picks
  by point height then applies the @1→@3 swap unconditionally. ~38-66 MB on a 939-row
  library. Arithmetic, not measured — measure once with `NetworkLedger` before and after.
- IC-F4/F5 — one cancelled request latches `aniListIsDown` for the session
  (`CharacterService.swift:58`); `clearOutageMemory()` exists and nothing calls it.
- W9 — one dropped packet caches empty genres/tags for the process
  (`CatalogueService.swift:35/39/52/66-67`).
- R10 — one failed fetch caches an empty release calendar for the process.

**Failure rendered as emptiness (X2 — the amplifier)**
- L1 — `LibraryModel.failure` assigned at `:218`, read by no view. Offline reader with
  937 series sees "Nothing saved yet". Function + a test.
- R8 — offline foreground shows "0 IN SCOPE" AND deletes every pending reminder.
- R7 — a cached cadence that fails to decode is shown as settled "Too few dated
  releases" and never retried (`ReleaseSchedule.swift:344`, `:193`, `:247`).
- RS-1 — `ScheduleProgress.failure` written at `ReleaseSchedule.swift:274`, read by
  nothing. A measurement where every request fails ends silently.
- W10 — `searchPublishers` failure renders as "no results", eight lines under the
  comment forbidding it.
- P-F9 — one bad cached row silently shortens a feed.
- W1-W4 — **`SeriesWork.Price.value` non-optional** (`SeriesWork.swift:12`); spec says
  nullable. One unpriced edition throws the whole volumes array and the section
  vanishes. Also `NewsItem.id`, `SeriesImage.id`, `PublisherRecord.id` nullable on the
  wire, non-optional in Swift. Check every one against `docs/schemas/mangabaka_openapi.json`
  — **the spec is in the repo**, I probed the live API for a night without looking.
- W13/T3 — `APIShapeContractTests` covers 7 of ~17 endpoints, all series-shaped.
  `/v1/works/upcoming` — where the price bug came from — is in no sweep.

**Reminders (both features never fire)**
- R1 — `ReleaseReminders.swift:81/146/161` re-adds catch-up nudges at now+24h and
  now+30d on every foreground. Open the app daily, neither fires.
- A4 — a release due later today is scheduled at 09:00 today (`:87` admits it, `:211`
  pins the hour), past trigger, `try?` hides it. Likely — one device check first.

**Statistics that can say something false (reader slice, R-series)**
- R12 — four Wrapped statistics count series never opened. Line ×4.
- R19 — `criticGap`/`disagreements` don't guard `rating > 0` the way `verdicts` does.
- R2 — the honesty line under the tag verdicts counts entries the verdicts excluded.
- R3 — "that much of your library" divides by the rated subset, not the library.
- R9 — "Measured 3 minutes ago" is the newest row's time over six-week-old rows.
- R5 — "From N releases on MangaUpdates" is a count of calendar days.
- R4 — `obscurity`/`deepestCut` read `ratingCount`, absent on v1. The card never
  renders. Either source it from v2 or drop the card.
- L9 — "Nearly half of your library is dropped" is a hardcoded sentence
  (`ReadingInsightsView.swift:190`).
- L2 — "All" pill says 937 over a list of ~500 (dropped counted, not listed).

**Computed and discarded (X3)**
- D — `StackModel.lastSaveWentToLibrary` and `source`, documented "so the screen can
  say", read by no view.
- RS-2 — `TasteModel` is unreachable (`Features/Taste/TasteModel.swift`); only its
  test references it. Delete both.
- L-edit — the live library list has no edit affordance; the only one is on the
  unreachable shelf screen.

**The shelf decision — needs Abdi, do not decide it**
`ShelfDetailView` is unreachable: `LibraryView` stores `onOpenShelf` and never calls
it. Two sub-agents said "reachable" because the destination exists; the tests agent
and I both confirmed nothing triggers it. `ShelfCard` has zero call sites. Delete or
re-wire — product call. Written up in `docs/unknowns-2026-09-11.md`.

**Schedule screen (remaining-screens slice)**
- RS-3 — leaving mid-measure freezes it (`ScheduleView.swift:57` cancels the poll,
  nothing restarts it); copy at `:116-119` promises it resumes.
- Browse header claims "200 most-used tags"; the fetch is not usage-ordered.

**Per body pass (X6)**
- L4/L5 — `shape` rebuilt per keystroke (~3ms), `inProgress`/`subtitle` read from the
  body. Same fix as the three already stored.
- D-B3 — `LensCounts` permanently abandons lenses it was cancelled before reaching.

**Surface**
- S-F3 — `CoverGallery.swift:85-94` 3D glide ignores `Motion`; C6 named it as fixed.
- S-F2 — toast is the only write confirmation; VoiceOver never hears it.
- S-F8 — `SearchClearButton` at 30pt in the 2.52:1 colour, across four fields.
- S-F15 — Settings says the field stays usable while disabling it.
- IC-F3 — `CoverImage` `.task(id:)` restarts the fetch but never clears `@State
  loaded`; a recycled row keeps the old artwork. One line. Stack is the live case.
- S-F11 — `AppServices.init` does a synchronous SQLite open on the main thread before
  first frame; the 0.08ms launch number excludes it. Two signposts settle whether F1
  is worth starting.

**Tests (tests.md)**
- 44 of 78 catalogued `SourceTree` assertions are stub-satisfiable. Convert the ones
  guarding behaviour to behavioural tests; keep the negatives (they assert absence).
- Three suites drive the global `URLProtocolStub` with no `.serialized`.
- `mix.json` has no provenance comment; the other three fixtures are fine.

**Verdicts:** every slice fix-in-place. Three carve-outs from SUMMARY §4: replace
`ScrollEdge.swift` with real nav bars on the four tab roots (surface agent says a
`.principal` toolbar item hosts the custom title, so the type ramp survives — untested,
~20 min on the branch); derive `APIShapeContractTests`' endpoint list from source;
`CacheScope` (done). Reader must NOT be rewritten — best negative-result comments in
the repo.

## Then: the feel pass

`docs/feel-plan.md`, in order: haptics → press feedback → numeric transitions → zoom
transitions everywhere → scroll transitions and snapping → symbol effects → shimmer.
Principle: motion explains, haptics confirm. Nothing bypasses `Motion.reduced`.

## Then: ship

`git push origin main`. Pre-push runs the full suite. Then update
`docs/overnight-2026-09-11.md` or write a sibling with what changed, and send Abdi the
three most useful screenshots.

## Corrections owed to Abdi, already made in chat, recorded here

- The OpenAPI spec was in the repo all along (`docs/schemas/`). I said it wasn't served.
- I claimed SKIP/SAVE badges failed contrast; they're at `opacity(0)` in a static audit.
- The wave-one slices missed ~3,050 lines and the whole test suite. Wave two fixed that.

## Where things are

- Simulator: iPhone 17 Pro `BF8CB720-DAC1-4656-B974-421F4A41C4C1`, app id
  `dev.abdirahmanmohamed.mangabaka`. Has Abdi's real 939-series library cached.
- Phone is unplugged. Nothing left needs it.
- Branch `apple-idiomatic` pushed; `docs/apple-experiment/` on it.
- 720 tests, 152 suites, all green at `fae9a29`.
