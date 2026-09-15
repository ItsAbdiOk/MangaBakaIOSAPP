# Perf review — `surface` slice

2026-09-15, HEAD `1f5e632`. Read-only; nothing built, run, or measured. Every
number below that is not quoted from a comment in the code is an estimate and
says so.

**Files reviewed: 41 of 71** in the slice (App 8/9, Shared 11/26, DesignSystem
10/11, Settings 5/15, WidgetSnapshot 2/2, MangaBakaWidgets 5/8), plus five
outside it that the questions required: `CoverStore`, `BlurHash`,
`BlurHashCache`, `NetworkLedger`, `RateLimitGate`, and `Cover.url(forHeight:)`.
Not reviewed: `AppTab`, `BrowseDestination`, `Haptics`, `StateAction`,
`FlowLayout`, `RatingSegments`, `SectionHeader`, `EmptyState`,
`InlineSearchField`, `ConfirmDestructive`, `CopyableArtwork`,
`CoverQuickActions`, `SettingsRow`, `HistorySection`, `LibraryTransferSection`,
`TranslationSection`, `AttributionSection`, `TitleSection`, `FormatSection`,
`TokenStatus`, `SeriesWidgetView`, `PickBackUpWidget`, `MangaBakaWidgetsBundle`.

**Findings: 22** — 9 certain, 9 likely, 4 worth checking.

**The single highest-value change:** the cover pipeline decodes every row
cover at the fetched rendering's size, not the drawn size (P1), and every
cover then fades in through a Gaussian blur while its card also fades in
through a second one (P2). Together they are what a 30-card fling costs, and
neither has a measurement. One Instruments run settles both.

---

## 1. Launch path, in order

What runs, whether it is before first paint, and what it could be instead.
"Before first paint" here means inside `MangaBakaApp.init` or `RootView.init`
(synchronous, main thread); everything else is in a `.task` and starts after
the first body pass.

| Step | Where | Before first paint? | Cost (as recorded / estimated) | Could be |
|---|---|---|---|---|
| `AppServices()` | `MangaBakaApp.swift:13` | yes, signposted "Services" | comment: "~300 ms of app work" for the whole launch | — |
| Keychain read (`hasCredentials()`) | `AppServices.swift:224` | yes | ~1 ms IPC (`SettingsView.swift:125` comment) | fine |
| SQLite open ×2, migrate, ATTACH/DETACH ×2, `tableExists` ×n, `PRAGMA freelist_count`, possible `VACUUM` | `AppServices.swift:373` → `AppDatabase.swift:263,131-158` → `AppDatabase+Split.swift:298-311, 351-356` | yes, signposted "Database open" | unbounded; VACUUM is a file copy (one-time) | the two moves are no-ops after the first run but still pay two ATTACH/DETACH round trips per launch; `splitHasCompleted` (`AppDatabase.swift:253`) is already read — a second marker for the cache move would skip `finishOpening` entirely on a settled device. Unmeasured; the signpost is there to measure it. |
| Three `UserDefaults` stores | `AppServices.swift:166-167` | yes | µs | fine |
| `/v1/my/profile` request | `AppServices.swift:431-432` → `LibraryService.swift:233-237` | no (Task), but fires at t≈0 at `.userInitiated` | 1 general request | see P8 — background priority, or persisted id |
| `TagTaxonomy.warm()` + naver purge | `AppServices.swift:325-328` | no, detached `.utility` | GUESS 10–30 ms (comment) | fine |
| `URLCache.shared` replacement | `MangaBakaApp.swift:21` | yes | opens a 256 MB disk index synchronously (comment) | could be `Task.detached` before the first cover request; nothing on the first frame needs it. Unmeasured. |
| Six session models in `RootView.init` | `RootView.swift:276-299` | yes | allocations only (inits checked: no I/O) | fine |
| `startSession()` | `RootView.swift:326` → `RootView+Session.swift:199` | no | see §2 | see P8, P9 |
| `taste.ranker()` | `RootView+Tabs.swift:164` | no | walks the snapshot (cached) | fine |
| `session.library.load()` | `RootView+Session.swift:287` | no — **but sequenced after `refreshReminders()`** | zero requests (cache) | move above `refreshReminders` (P9) |
| Spotlight reindex of 945 rows | `RootView+Session.swift:288` | no, detached `.utility` inside | signposted | fine |
| `WidgetSnapshot.write` | `RootView+Session.swift:296-299` → `WidgetSnapshot.swift:174-210` | no, but synchronous on the main actor | read + decode + encode + atomic write of a few KB | `Task.detached`; see P12 |

Cold launch was measured at ~900 ms with ~600 ms linker; the app's own
synchronous share is "Services" + "Database open" + the URLCache open. Of
those, the URLCache open and the settled-device halves of `finishOpening`
are the only things that could move off the first frame without a redesign.
Everything else is already deferred, and the comments say so with dates.

## 2. Requests in flight — this slice

| Call | Trigger | Priority | Awaited before draw? | Verdict |
|---|---|---|---|---|
| `/v1/my/profile` | every signed-in cold launch, `AppServices.swift:431` | `.userInitiated` (default, `APIClient.swift:61`) | no | **Later / dropped**: needed only by the Mix's blend exclusion; `.background`, or cache the id in `UserDefaults` keyed on the token so warm launches cost nothing (P8) |
| `/v1/series/rising` (feed) | first launch only, onboarding not complete, `RootView+Session.swift:220` | `.userInitiated` | no (covers page survives empty) | fine |
| Library walk (≤13 pages) | `refreshReminders` → `librarySnapshot.load()`, `RootView+Session.swift:227, 387` | walk's own | no | 6 h disk cache; deduped with `taste.ranker()` via `inFlight` |
| `/v1/works/upcoming` ×≤6 pages | `refreshReminders` → `calendar.mine`, `RootView+Session.swift:391` → `ReleaseCalendar.swift:69-85` | **`.userInitiated`** (`getLossy` default) | no, but `session.library.load()` and the widget write queue behind it | **`.background`**: it is a launch-time background rebuild of reminders, and six general-family requests at t≈0 compete with Discover's first feeds. Only when reminders are on (off by default). |
| Search ×N follows | `refreshReminders` → `publisherFollows.check`, `PublisherFollows.swift:118` | `.background` ✔ | no | fine; once a day per follow |
| `/v1/my/profile` (again) | Settings open, `SettingsView.swift:205` → `RootView.swift:426` | `.userInitiated` | no | 1 h cache in defaults (`:81`) ✔ |
| `/v1/tags?limit=500` | Blocked-tags sheet open, `BlockedTagsSection.swift:226` | `.userInitiated` | no — bundled list shown first ✔ | **`.background`**: the bundled 2,686 rows are already on screen; the live fetch is a confirmation. Cached per session in `CatalogueService`. |
| `/v1/my/profile` after "Remove token" | `RootView+Session.swift:189-192` | — | — | guarded by `hasCredentials()` ✔ (item 15 done) |
| Covers (CDN, not rate-limited) | every `CoverImage` appearance, `CoverImage.swift:85` | URLSession default | no | see P1–P4 |
| Widget covers ×4 per widget | hourly, `SeriesWidgetEntry.swift:83`, `NextVolumeWidget.swift:35` | — | — | re-downloaded every reload (P13) |

Nothing in this slice fires per keystroke. Nothing sends reader data anywhere
(`DataUseSection.swift:83-86` says so and the code agrees).

---

## 3. Findings

### Covers — what a 30-card row fling does today

Walkthrough, from the code: each card that enters the `LazyHStack` runs
`CoverImage.body` → `blurPlaceholder` decodes the BlurHash on the main thread
on first sight (`CoverImage.swift:36` → `BlurHash.swift:93-113`) → `.task(id:
url)` calls `load()` → `CoverStore.cached` misses → `CoverStore.image(for:)`
starts an unbounded `Task` per URL (`CoverStore.swift:91`) → on the cooperative
pool: `URLSession.data`, `UIImage(data:)`, `byPreparingForDisplay()` at the
fetched rendering's full size (`:185`) → back on main: `loaded = image`, a
`Task.yield`, `isReady = true` → `appearsSoftly` animates opacity 0→1 and blur
4→0 over `Motion.settle` (0.45 s spring) (`MotionModifiers.swift:57-59`) while
the enclosing card's `.arrives()` scales it with the finger and `.enterScale()`
scales it again on a spring (`DiscoverView.swift:274-275`), all under a
`.shadow(radius: 10)` (`CoverImage.swift:281`). Scrolling off: `onDisappear`
drops the bitmap (`:104-107`); the store keeps it (up to 96 MB, ~73 row covers
on the arithmetic below); scrolling back re-reads it synchronously.

**P1 — Row covers are decoded at 1.7× the pixels they draw.**
Where: `CoverStore.swift:185` (`byPreparingForDisplay`), given
`Cover.swift:115-134` (smallest rendering ≥ needed pixels).
Why: a 118 pt row card (`Metrics.swift:79`) is 177 pt tall → 531 px at 3×;
the smallest sufficient rendering is x350@2 = 700 px tall (~467 × 700), and it
is decoded at that size: ~1.3 MB RGBA per cover versus ~0.75 MB at the drawn
354 × 531. Every row cover costs 1.74× the decode time, memory and GPU upload
it needs, and the 96 MB store holds ~73 row covers instead of ~128 — so a
Discover screen of two 30-card rows plus a grid evicts while the reader is
still on it (the `CoverStore.swift:44-51` "NOT MEASURED" note is about exactly
this). `MangaBakaWidgets/CoverLoader.swift:76` already uses
`byPreparingThumbnail(ofSize:)` — the fix has an in-repo precedent.
Caveat: the cache key is the URL (`:102`); two call sites sharing a rendering
at different display sizes (row 118 pt and hero 150 pt both resolve to x350@2)
would need the key to carry the target size, or the larger to win.
Effort: a function. Confidence: certain on the arithmetic; the ms is unmeasured.

**P2 — Two Gaussian blurs per arriving card, and one per arriving row, during scroll.**
Where: `MotionModifiers.swift:58` (`appearsSoftly`, blur 4→0 on the image) and
`:28` (`arrives(index:)`, blur 6→0 on the card), stacked at
`DiscoverView.swift:274` / `LibraryList.swift:47` / `SearchEmptyState.swift:75`
/ `VolumesSection.swift:140` and 20-odd more call sites.
Why: `.blur` is an offscreen Gaussian pass per frame while the radius is
non-zero. With `Motion.settle` at 0.45 s and a fling that surfaces 20–30
cards, that is 40–60 blur passes running concurrently on ~354 × 531 px
bitmaps at up to 120 Hz. This is the most likely single cause of dropped
frames in a row fling, and the one thing the `CoverFrame` comment
(`CoverImage.swift:268-280`) did not consider: it asks whether the *shadow* is
offscreen-rendered, but the two blurs above it are offscreen by definition.
The mockup asks for an arrival; it does not say blur. Under Reduce Motion both
collapse correctly to instant.
Effort: a line each (opacity-only in rows; keep blur on the hero/detail where
one image arrives at a time) — **after** an Instruments run with the two lines
commented out as the control. Confidence: likely.

**P3 — On-screen cover loads are unbounded; only the speculative ones are capped.**
Where: `CoverStore.swift:91-98` (one `Task` per `image(for:)`) versus
`:119, 135-146` (`prefetch` capped at `prefetchWidth = 6`, `.utility`).
Why: the cap was added (work-list 51) because 40–60 concurrent decodes
competed with the scroll that asked for them. The same 40–60 concurrent
decodes still happen for the *visible* path: a fling over 30 cards starts 30
`URLSession.data` + 30 `byPreparingForDisplay` on a pool of ~6 threads, and
the 25 that scrolled off are not cancelled (deliberately, `:73-75`) and are
not demoted either — they finish at the same priority as the six the reader
is now looking at. The visible cover waits behind covers nobody can see.
Fix: a store-level width (a small `AsyncSemaphore` or task group of ~8) with a
"still on screen" bit that `load()` clears on cancellation, so scrolled-off
fetches are deprioritised rather than dropped.
Effort: a function. Confidence: likely.

**P4 — BlurHash decodes on the main thread, on first sight, with 2 `cos` per pixel-component.**
Where: `CoverImage.swift:34-37` (computed in `body`, via `background` at
`:136`) → `BlurHash.swift:98-107`.
Why: 32 × 32 px × (cx·cy, typically 12) × 2 = ~24,600 `cosf` calls plus
3,072 `linearTosRGB` per cover, on the main thread, in the body pass that
creates the card. GUESS 0.2–1 ms each; a row that lays out 8–10 cards at once
is a few ms in one frame; a 30-card grid appearing at once is more. The
reference implementation precomputes the cosine tables (`cos(πx·i/w)` is
`w × cx` values, not `w·h·cx·cy`), which removes ~90 % of the trig. The
`BlurHashCache` (`BlurHashCache.swift:22-28`) makes it once per hash, so this
is a first-sight cost, not a per-frame one.
Effort: a function (tables), or move the decode into `load()` off-main and
show `Palette.imagePlaceholder` for one frame. Confidence: likely; unmeasured.

**P5 — `CoverImage.onLoaded` is declared, documented, and never passed.**
Where: `CoverImage.swift:26` ("Rows use this to chain their own arrival"),
called at `:169, 187`; zero call sites pass it (whole-repo grep, tests
included).
Why: charter §3, exactly the `accessibilityText` shape from the same file.
Either the rows were meant to chain arrival to the cover (in which case every
row's `.arrives()` today fires against a placeholder, which is what the
doc comment says it should not) or the property is dead. Nothing is broken;
the intent is undelivered.
Effort: a line (delete) or a function (wire `CoverCard` to it and drop the
independent `arrives` delay). Confidence: certain.

**P6 — `url` is recomputed in every body pass: nine `URL` constructions with string replacement.**
Where: `CoverImage.swift:46` → `Cover.swift:115-134` → `:150-153`
(`replacingOccurrences` + `URL(string:)` ×6 per call).
Why: `CoverImage` has 3–4 body passes per load (`loaded`, `isReady`, the
yield), each rebuilding up to nine URLs; plus every parent invalidation.
Microseconds each, but it is per cover per pass and the answer never changes
for a given `(cover, height, scale)`. Same category as item 106.
Effort: a line (`@State` cached on first pass, or a `let` computed in `init`).
Confidence: certain on the mechanism; not worth measuring alone.

### Motion

**P7 — `LoadingLine` ticks at display rate while invisible.**
Where: `LoadingLine.swift:36` (`TimelineView(.animation)`) kept in the tree at
`opacity(isActive ? 1 : 0)` (`:49`), by design ("so the fade out is a fade").
Why: `TimelineView(.animation)` re-evaluates its body every frame for as long
as it is in the hierarchy, whether or not it is visible; on a ProMotion
device it also holds the display at 120 Hz. It sits in a `safeAreaInset` on
every series page (`SeriesDetailView.swift:401`), so every open series page
pays a per-frame body pass and a moving gradient layer for its whole life,
after the last leg has answered. The fade is worth keeping; the ticking is
not. `TimelineSchedule.animation(minimumInterval:paused:)` exists for exactly
this: `.animation(paused: !isActive)` keeps the view, keeps the fade, and
stops the clock. The band's `offset` would freeze mid-line during the 0.45 s
fade-out, which at opacity → 0 is invisible.
Effort: a line. Confidence: certain on the mechanism; the mW is unmeasured.

**P8 — `.arrives(index:)` on every library row hides each row for 270 ms as it scrolls in.**
Where: `LibraryList.swift:47` (`.arrives(index: index)` for all 945 rows) →
`Motion.swift:86-88` (`stagger` capped at 6 × 45 ms) → `MotionModifiers.swift:23-36`.
Why: for index ≥ 6 the delay is a flat 0.27 s. `onAppear` fires per row as
the `LazyVStack` creates it, so a row entering by scroll is at opacity 0,
blurred, and offset for 270 ms, then springs in over 0.45 s with a blur pass
(P2). On a fling the reader is looking at blank rows filling in behind the
scroll. The comment at `:44-46` says the cap exists "so a 900-row library
assembles rather than queuing", which is true of the delay's *growth* and not
of its floor. The intent — stagger the first screenful — needs "no delay for
a row that arrives by scrolling", e.g. index relative to the first visible
row, or a `hasSettled` flag on the list after which `arrives(index: 0)`.
Same shape at `SearchEmptyState.swift:75`, `DataUseSection.swift:71`,
`BlockedTagsSection.swift:23`.
Effort: a function. Confidence: likely (not seen on a device by me).

**P9 — `.arrives()` and `.enterScale()` are stacked on the same card.**
Where: `DiscoverView.swift:274-275`, `RecentlyViewedRow.swift:74-75`,
`MixView.swift:219-220`, `ContinuationsRow.swift:67-68`,
`CharacterRow.swift:94-95`, `DetailOnwardRows.swift:150-151, 232-233, 268-269`,
`VolumesSection.swift:140-141`, `AppleVolumesRow.swift:77-78`.
Why: two `scrollTransition`s on one view, both on the row's axis — one
`.interactive` (scale 1−0.06d, opacity 1−0.4d, `Motion.swift:162-167`) and
one `.animated(glide)` (0.96 / 0.85 at the edge, `MotionModifiers.swift:95-100`).
At the edge they multiply: scale 0.90, opacity 0.51 — and one tracks the
finger while the other springs, so the card visibly double-dips. Two
transform layers per card per scroll frame is small; the visual is the
point, and the `EnterScaleModifier` comment (`:83-88`) already flags its own
`.animated` choice as "for the main session to eyeball on a device".
Effort: a line per site (keep one). Confidence: worth checking on a device.

**P10 — `EdgeSwipeToDismiss` runs a 0.7 s spring on every drag sample.**
Where: `EdgeSwipeToDismiss.swift:72-74` (`Motion.run(Motion.glide)` inside
`onChanged`).
Why: a drag-follow should assign directly; wrapping each sample in a spring
restarts a 0.7 s animation toward the finger 60–120 times a second, so the
sheet lags the finger by the spring's response and every sample opens an
animation transaction. `.interactive` is the right category here by the
project's own rule (`MotionModifiers.swift:83-85`); the end of the gesture
(`:89-101`) already animates correctly.
Effort: a line. Confidence: likely.

### Launch and session

**P11 — A failed launch `/v1/my/profile` disables the blend exclusion for the whole session, silently.**
Where: `AppServices.swift:431-432` → `LibraryService.swift:233-237`
(`client.profile()` is `try? await get(...)`, `APIClient.swift:414-415`) →
`SeriesRepository.swift:683-691`.
Why: the request fires at t≈0 at `.userInitiated`, in the same instant as
Discover's feeds and the walk. If it 429s, times out, or is offline,
`profileID()` answers nil, `updateLibraryExclusion(userID: nil)` is applied,
and nothing retries until "Remove token" or relaunch — every Mix blend for
the session recommends series the reader already tracks, which is item 1 of
the second pass reappearing as a transient rather than a permanent. The
`try?` at `APIClient.swift:415` logs nothing, so it would be invisible in
production. Two fixes, both small: persist the id in `UserDefaults` keyed on a
hash of the token (warm launches then cost zero requests and cannot fail), and
send the launch call at `.background` so it waits for a slot instead of
throwing. One `Logger.notice` on the nil path.
Effort: a function. Confidence: certain on the mechanism.

**P12 — `startSession` sequences zero-request work behind up to six background-priority requests.**
Where: `RootView+Session.swift:227` (`await refreshReminders()`) before `:287`
(`session.library.load()`), `:288` (Spotlight), `:296` (widget).
Why: with reminders on, `refreshReminders` awaits `calendar.mine` (≤6 pages
of `/v1/works/upcoming` at `.userInitiated`, `ReleaseCalendar.swift:69-85`)
and N follow searches at `.background` (`PublisherFollows.swift:118`), which
wait at the gate whenever 120 of the 180 window are held. Discover's "Pick
back up" row and chapters-read figure (item 7) are filled by
`session.library.load()`, which costs no request — and it does not run until
the reminders' requests have all returned or waited. Reorder: walk →
`session.library.load()` → widget → reminders. The comment at `:224-226`
("after the reminders, which already walked the library") is about the walk's
cache, which `librarySnapshot.load()` at `:242` already guarantees whichever
runs first.
Effort: lines. Confidence: certain on the ordering; the seconds depend on the
gate's state.

**P13 — `wantsAccountFocus` is set once and never cleared.**
Where: `RootView.swift:149`, set at `RootView+Failures.swift:45`, read at
`RootView+Session.swift:111`, no write to `false` anywhere.
Why: after onboarding's "Connect an account", every subsequent Settings visit
for the rest of the session passes `focusAccount: true`, and `AccountCard`
(`AccountCard.swift:83-88`) re-focuses the token field and raises the keyboard
350 ms after each appearance until a token is saved. Charter §3's "assigned
and never cleared" variant.
Effort: a line (`wantsAccountFocus = false` in `onRemove`/after the push, or
consume it in `SettingsView.init`). Confidence: certain.

**P14 — `WidgetSnapshot.write` is synchronous on the main actor and swallows both failures.**
Where: `WidgetSnapshot.swift:174-210` called from `RootView+Session.swift:296`;
`try?` at `:200, 201, 227, 228, 238, 240`.
Why: a read-decode-encode-write of the App Group file on the main thread
while the reader is scrolling Discover in the first seconds; small (a few KB)
but not free, and a write refused (container missing, disk full, entitlement
mismatch on a new device) leaves the Home Screen tile stale for 7 days
(`SeriesWidgetEntry.swift:45`) with nothing in the log. The only thing that
makes this findable today is `AppGroupParityTests`.
Effort: a function (`Task.detached(priority: .utility)` + one `Logger.error`).
Confidence: certain.

**P15 — The widgets re-download the same four covers every hour.**
Where: `MangaBakaWidgets/CoverLoader.swift:52` (`.ephemeral`, "nothing on
disk" by design, `:30-31`) with `SeriesWidgetEntry.swift:26` (reload every
3,600 s) and `CoverLoader.swift:76` (thumbnail decode each time).
Why: the extension process is short-lived, so `.ephemeral`'s in-memory
`URLCache` dies with it; three widgets × 4 covers × 24 reloads = up to 288
downloads a day of ~12 images that change only when the app writes a new
snapshot. ~30 KB each at x250 → ~8 MB/day on cellular for pixels the phone
already had. The snapshot changes only on an app launch, and the app already
calls `reloadAllTimelines()` on change (`WidgetSnapshot.swift:208-209`), so
the hourly reload is buying only the "due day has passed" filter
(`SeriesWidgetEntry.swift:77-80`), which a `.after(next midnight)` policy
would buy for one reload a day.
Fix: a `URLCache` on disk in the App Group container (a few MB), or have the
app write the four thumbnails beside the snapshot — it has them decoded in
`CoverStore` already.
Effort: a function. Confidence: likely.

### Charter §6 — the hand-rolled kit, and where I disagree with the branch README

The README's argument is that containers are free and colours are not. Read
against `main` today, half of what it lists is already done and the other
half costs the mockup more than it says:

- **Scroll edge.** Three tab roots still use `ScrollEdge.swift` (129 lines,
  a window-inset read, an `onScrollGeometryChange` clamped to 12 pt — the
  clamp at `:45-47` is well done and stops the action after 12 pt). Search
  and every pushed screen already use `.scrollEdgeEffectStyle(.hard)` +
  `.navigationTitle` (`SettingsView.swift:171-173`). The README is right
  that a real bar on the three roots deletes this file. It is wrong that it
  costs "a title that moves"; `.navigationBarTitleDisplayMode(.inline)` with
  `.toolbar(.hidden)`-style customisation keeps the drawn title. **What it
  actually costs:** the mockup's 36 pt title inside the scroll content
  (`typeScreenTitle`, `Typography.swift:110`) would have to move above the
  scroll view or the bar would double it. That is a design change Abdi has
  to see, not a free win. — *Recorded, not a finding.*
- **`DetailBarTitle`** (`DetailBarTitle.swift`, 58 lines): a `.principal`
  toolbar item whose opacity follows `ScrollTracker.crossfade`. The system
  version (`.large` display mode) would put a large title above the hero
  where the mockup draws the title *on* the hero. Cost of keeping it: one
  `@Observable` write per scroll sample over a 60 pt span, then nothing.
  Cheap; keep. — *Not a finding.*
- **`SearchClearButton`** (`:14-53`): correct on the three hand-rolled
  fields; the Search tab uses the system field (`:9-10`). Keep.
- **`TapTarget`** (`:15-18`): 4 lines. A `Form` would give it free and
  would give up the 30 pt pills. Keep.
- **`Palette`.** `textSecondary` and `switchOff` are already semantic
  (`Palette.swift:52, 114`) with the resolution measured (`:36-44`,
  2026-09-14). **P16 — `textPrimary` (white @ 0.96, `:46`) and
  `textEmphasis` (white @ 0.98, `:48`) are within 4 % of `.label`'s dark
  resolution (white @ 1.0) and are not semantic.** Taking `.label` costs the
  mockup nothing anyone can see and gains Increase Contrast and Smart
  Invert on every primary text in the app — the exact reasoning the file
  applies to `textSecondary`. `textBody` (0.75) and `textTertiary` (0.45) are
  deliberate departures and documented as such (`:53-65`). Effort: two
  lines. Confidence: certain on the delta; "not visible" is a claim a
  screenshot pair would settle.
- **`Typography`.** Every style is a `@ScaledMetric` anchored to a text
  style (`:10-27`), with the anchor choice measured across all content
  sizes (`:88-108`, a table with a method). The README's "`.font(.caption)`
  would have been correct" is wrong on its own table: `.caption2` stalls for
  four sizes and `.subheadline` does not. This is the hand-rolled thing
  that is *better* than the system version, and the file proves it. —
  *Done well.*

### Settings and debuggability

**P17 — `NetworkLedger.Entry.failures` is recorded and shown nowhere.**
Where: written `NetworkLedger.swift:51`; `DataUseSection.swift:120-137`
(`endpointRow`) reads `requests`, `bytes`, `averageSeconds`,
`slowestSeconds`, `droppedRows` — not `failures`. Only
`APIClientLedgerTests.swift:38` reads it.
Why: the one number that says "this endpoint is being refused" is the one
the Data-used screen omits. Same shape as item 20 (`droppedRows`, now
surfaced at `:126, 151`). One more `· N failed` in `endpointCaption`.
Effort: a line. Confidence: certain.

**P18 — Nothing counts rate-limit events, so "was I throttled?" is unanswerable after the fact.**
Where: `RateLimitGate.swift:71-74` (local `.rateLimited` throw), `:107-125`
(background wait loop), `blockedUntil` writes (a server 429) — no counter on
any of the three; `NetworkLedger` has no field for them.
Why: Abdi's two questions are "when are requests sent" and "does the reader
notice a throttle". Today the answer can only be found live in a debugger.
Three counters on the gate — `thrown[family]`, `waited[family]` with total
wait seconds, `serverLimited[family]` — read by `DataUseSection` beside the
request count would make a throttled session visible in Settings in one
glance, and make a bug report ("search felt slow") diagnosable from a
screenshot. Everything else a Diagnostics screen needs already exists:
per-endpoint counts, bytes, latency and drops (`NetworkLedger`), taste
counts (`TasteProfile.diagnostics()`, `DataUseSection.swift:166`), the
signposts in §1. Missing beyond the gate: a `CoverStore` hit/miss/evict
count (the `NSCacheDelegate` the store's own comment asks for,
`CoverStore.swift:47-51`) and `LibrarySnapshot`'s cache-vs-walk source.
Effort: a function on the gate, lines in the section. Confidence: certain on
the gap.

**P19 — Every swallowed failure on the account and widget paths is unlogged.**
Where: `AppServices.swift:342` (naver purge — fine, no-op by design),
`RootView+Session.swift:307` (`history.lastOpenedDates` → `[:]`: a read
failure makes every reading series a "Pick back up" candidate, silently),
`HistorySection.swift:123`, `WidgetSnapshot.swift:200-240` (P14),
`APIClient.swift:415` (P11), `CoverLoader.swift:72`.
Why: this slice has **no `Logger` at all** — the grep over App, Settings,
Shared, DesignSystem, WidgetSnapshot and the widget target returns nothing;
the only logger nearby is `AppDatabase`'s `splitLogger`. A production report
of "my widget is blank" or "Pick back up shows everything" has no line to
find. One `Logger(subsystem:category:)` per file and `.error` on each `try?`
that changes what the reader sees.
Effort: lines. Confidence: certain.

**P20 — `BlockedTagsSection` asks the network at `.userInitiated` for a list it has already drawn.**
Where: `BlockedTagsSection.swift:226` (`catalogue.tags(limit: 500)`) after
`:218-222` has already shown the bundled 2,686 rows.
Why: one general request per session, fine on budget; but it is the textbook
"confirmation fetch" and it competes with whatever the reader tapped next.
`.background` would wait for a slot instead of taking one, and the footnote
already handles `bundledOnly(error)` (`:246`). Under a throttle today the
sheet works and the footnote says "MangaBaka asked for a pause" — the
rate-limit invisibility is already right here; only the priority is wrong.
Effort: a line (needs `CatalogueService.tags` to take a priority).
Confidence: certain.

**P21 — `RootView.body` re-evaluates on every library page because `tabs` reads two `LibraryModel` properties.**
Where: `RootView+Tabs.swift:60, 68` (`session.library.inProgress`,
`.chaptersRead`) inside the `TabView` builder.
Why: `LibraryModel` is `@Observable`; reading its properties in `RootView`'s
body subscribes the whole tab tree to them, so each of the walk's ≤13 pages
(and every `apply`) rebuilds the five tab closures, the `detail` closures and
the `SettingsView` argument list (~40 closures, `RootView+Session.swift:91-129`).
Not per-frame; ~1 ms-class per page, unmeasured; but it is the same shape as
item 106 and the fix is the same: pass `session.library` and read the two
properties inside `DiscoverView`, narrowing the invalidation to the one view
that draws them.
Effort: lines. Confidence: likely.

**P22 — `finishOpening`'s two moves run on every launch after they have completed.**
Where: `AppDatabase.swift:131-158` → `AppDatabase+Split.swift:298-311`
(ATTACH, `tableExists` per `libraryCacheTables`, `PRAGMA freelist_count`,
DETACH), inside the "Database open" signpost, before first paint.
Why: no-ops on a settled device, but not free ones — two ATTACH/DETACH round
trips and a handful of schema queries per cold launch. `splitHasCompleted`
already exists (`AppDatabase.swift:253`) for one of the two; a matching
"cache move completed" marker (the `cache.libraryMove` row at
`AppDatabase+Split.swift:313-318` is it) checked *before* the ATTACH would
skip both. The VACUUM retry (`:305-311`) can stay behind the freelist check.
Effort: a function. Confidence: worth checking — the signpost is already
there; if "Database open" on a settled device is under 10 ms this is not
worth the marker.

---

## 4. Main thread & rendering — summary

- Decoding: BlurHash on main at first sight (P4). Image decode is correctly
  off-main (`CoverStore.swift:164`, a real bug fixed and recorded).
- Per-frame: `LoadingLine` while invisible (P7); two blurs per arriving
  card (P2); stacked scroll transitions (P9); a spring per drag sample (P10).
- Per-pass churn: `CoverImage.url` (P6); `RootView.body` on library pages
  (P21); `RowAmbient.tint` re-averages six BlurHashes per row body pass
  (`RowAmbient.swift:100-123`) — µs, not a finding, noted so nobody adds a
  seventh.
- Synchronous on main after first paint: `WidgetSnapshot.write` (P14),
  `pickBackUpItems` over 945 entries (`RootView+Session.swift:297`, trivial).
- Nothing in this slice does a DB read in a `body`. `SettingsView.init`
  used to read the Keychain per body pass and no longer does (`:124-130`) —
  done well.

## 5. Rate-limit invisibility — what exists, what is missing

Exists, in this slice: `StaleBar` with a live `Countdown` and auto-retry
(`FailureState.swift:132-206`, `Countdown.swift:37-41` with `initial: true` —
item 18 done); `FailureState` with `autoRetry` (`:46, 76-77`);
`InlineFailure` with a retry gate (`InlineFailure.swift:38-43`);
`LoadingLine` (`:18-53`); skeletons with shimmer (`Skeleton.swift:56-114`);
`BlockedTagsSection`'s bundled-first-then-confirm pattern (`:218-230`).

Missing, and specific to the kit:

1. **A "quiet" variant of `FailureState` for a `.rateLimited` error when
   there is nothing stale to show.** Today the screen says "Retrying in 40 s"
   in bold (`FailureState.swift:76-81`) — honest, but it is the card Abdi does
   not want the reader to notice. The kit already has the pieces: skeleton +
   `LoadingLine(isActive: true)` + `Countdown` with `onReachZero` firing the
   retry and no text. The decision "stale bar if we have anything, skeleton +
   silent countdown if we do not, the bold countdown only after the second
   consecutive limit" belongs in one place — a `FailurePresentation` chosen
   from `(error, hasStale, consecutiveLimits)` — rather than in each screen.
   Effort: a file. This is the one structural change the two asks need.
2. **`LoadingLine` as the only signal for background legs everywhere, not
   only on the series page.** Discover rows that arrive `.background` after a
   wait should raise the same line under the tab root; today a late row just
   appears. Effort: lines per root, once P7 stops the line costing while idle.
3. **The gate's own state as a signal.** With P18's counters, the
   `DataUseSection` caption can say "3 requests waited 12 s this session",
   which is the reader-visible honesty that lets the screens stay quiet.
4. **Priority on confirmation fetches** (P20, the launch profile P11, the
   reminders' calendar pages in §2): a request that the screen does not wait
   on should never take a slot a tap wants.

## 6. Size

- `CoverImage.onLoaded` (P5): dead or undelivered — 3 lines.
- `LibraryList.swift:48` `.transition(.blurReplace)` duplicates the one
  inside `ArrivesModifier` (`MotionModifiers.swift:30`); the outer wins. One
  line.
- `Motion.arrives()` (`Motion.swift:153-169`, `ArrivalTransition`) and
  `MotionModifiers.enterScale()` (`:89-110`) are two spellings of "scale and
  fade at the scroll edge"; every horizontal row uses both (P9). One should
  go; `Motion.swift:146-169` is the older and the one the `.parallax` sites
  do not use.
- `WidgetSnapshot` and `WidgetSnapshotData` are two copies of one shape by
  necessity (two targets, `WidgetSnapshotData.swift:16` says why) and the
  contract test (`NextVolumeContractTests.swift:19-45`) encodes with one and
  decodes with the other — the right test for charter §1. Not a size finding;
  recorded so nobody "deduplicates" it.
- `RootView`'s 35-parameter `init` (`RootView.swift:202-300`) and the matching
  35-argument call (`MangaBakaApp.swift:28-65`) are the same list twice;
  passing `services` and reading `services.x` at the twelve use sites would
  delete ~110 lines and the shotgun edit every new service costs. Product of
  the lint's earlier ceiling, per `AppServices.swift:6-11`; a design call.

## 7. Good news

- `CoverStore.fetch` is `nonisolated` for a reason that is recorded as a
  real bug (`CoverStore.swift:150-163`), and `byPreparingForDisplay` moves
  the decode off the draw thread (`:185`). The 96 MB comment corrects its own
  earlier arithmetic and says what would settle the number (`:31-51`).
- `CoverImage.onDisappear` releases the row copy with a measurement ("~70 MB
  of row state for 513 rows", `:88-95`, 2026-09-14) and the returning-row
  path is reasoned through and pure-tested (`arrival(wasCached:loadDuration:)`,
  `:240-243`).
- `ScrollEdge.travel(forOffset:)` clamps in the transform so the action stops
  firing after 12 pt (`ScrollEdge.swift:45-47`) — the "every scroll sample"
  bug it replaced is described at `:40-44`.
- `AppServices` records what is deferred, why, and that the saving is a
  guess (`:296-304`); `enlargeImageCache` is outside the "Services" signpost
  for a stated measurement reason (`MangaBakaApp.swift:16-21`).
- `RootView.tagAudience` (`:172-189`) says "Unmeasured" rather than quoting a
  number; `SettingsView.init` explains the Keychain-per-pass bug it fixed
  (`:124-130`).
- `Typography`'s anchor table (`:88-108`) is the best-evidenced design
  decision in the slice and is the one the apple-idiomatic README gets wrong.
- `WidgetSnapshot.write` only reloads timelines when a list moved
  (`:203-209`), with WidgetKit's budget quoted.
- `CoverLoader` (`:38-50`) records a measurement that *overturned* a review
  finding (the User-Agent 403) and kept the header anyway with the reason.
- `PublisherFollows.check` sends at `.background` and stops on the first
  `.rateLimited` (`:118-121`).

## Could not determine

- **Frame time of a 30-card fling** with and without the two `.blur` lines
  (P2) and with `byPreparingThumbnail` (P1). Instruments → Core Animation
  FPS + "Color Offscreen-Rendered", on a device, same fling, three runs each.
  The control is the fling with `CoverFrame.shadow` commented out, which the
  code already asks for.
- **`CoverStore` eviction count** on one Discover screen (P1): the
  `NSCacheDelegate` the store's comment names.
- **"Database open" on a settled device** (P22): the signpost exists; one
  cold launch on a device with the split and move complete.
- **Whether `TimelineView(.animation)` at opacity 0 holds 120 Hz** on
  ProMotion (P7): Instruments → Display, series page idle, before and after
  `paused:`.
- **Whether the 270 ms row delay is visible on a fling** (P8): a device, the
  library list, a flick; no fixture can show it.
- **The MB/day the widgets actually spend** (P15): Settings → Cellular →
  the extension's row after a day with three widgets placed.
- **Whether `.label` differs visibly from white @ 0.96** (P16): two
  screenshots of one screen.
