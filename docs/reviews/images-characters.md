# Deep review — `Core/Images` and `Core/Characters`

Date: 2026-09-11. Read-only pass. Nothing built, nothing run.

## Denominator

**The slice, read in full — 6 of 6 files, 806 of 806 lines:**

| File | Lines |
|---|---|
| `MangaBaka/Core/Images/BlurHash.swift` | 157 |
| `MangaBaka/Core/Images/BlurHashCache.swift` | 29 |
| `MangaBaka/Core/Images/CoverStore.swift` | 146 |
| `MangaBaka/Core/Characters/SeriesCharacter.swift` | 176 |
| `MangaBaka/Core/Characters/CharacterService.swift` | 90 |
| `MangaBaka/Core/Characters/AniListClient.swift` | 208 |

**Read in full outside the slice, because the questions cannot be answered
without them:** `Core/Model/Cover.swift` (135), `Features/Shared/CoverImage.swift`
(171), `MangaBakaTests/BlurHashTests.swift` (54).

**Read in part:** `LibraryList.swift:55-80`, `StackView.swift:80-145`,
`DiscoverView.swift:200-245`, `SeriesDetailView.swift:295-330`,
`docs/unknowns-2026-09-11.md:1-55`.

**Named and NOT read** — findings below never rest on these:
`MangaBakaTests/CharacterSourceTests.swift` (grepped for call shape only, not
read), `MangaBakaTests/CoverTests.swift` (test *names* only),
`Features/Shared/CopyableArtwork.swift` (grepped for its two `CoverStore`
lines only), `Features/Detail/CoverGallery.swift`, and the other 11
`CoverImage` call sites. No build, no test run, no device measurement.

---

## Question 1 — memory and eviction. What is cached, where, with what limit,
## and what evicts it?

**The complete inventory. There are exactly two caches in this slice.**

1. **`CoverStore.cache`** — `CoverStore.swift:30-34`. `NSCache<NSURL, UIImage>`,
   `totalCostLimit = 96 * 1024 * 1024` (96 MB). Key is the *variant URL*, not
   the series, so the same cover at two sizes is two entries. Cost is charged
   at `CoverStore.swift:73` as `image.approximateBytes`, defined at
   `CoverStore.swift:142-144` as `cgImage.bytesPerRow * cgImage.height` — the
   decoded bitmap, which is the right thing to count.
2. **`BlurHashCache.cache`** — `BlurHashCache.swift:14-20`.
   `NSCache<NSString, UIImage>`, `countLimit = 400`. Entries are 32×32 RGB
   (`BlurHash.swift:16`), so ~3 KB of pixels each; ~1.2 MB of pixel data
   at the limit. Not a concern, and the comment says why it is a count limit.

**What evicts.** Only `NSCache`'s own policy: cost pressure on the first,
count on the second, plus `NSCache`'s automatic purge on a
`UIApplicationDidReceiveMemoryWarning`. There is no manual eviction, no
purge-on-background, and no TTL anywhere in the slice — `grep` for
`removeAllObjects` across both directories returns nothing. Live views also
hold a strong reference through `CoverImage`'s `@State loaded`
(`CoverImage.swift:28`), so the on-screen working set sits *on top of* the
96 MB, not inside it.

**What that means for a 939-row library — the arithmetic, all of it traceable.**

A library row draws its cover at `width: 38` (`LibraryList.swift:66-70`), so
`height = 38 / (2/3) = 57pt` (`CoverImage.swift:19`, `Metrics.swift:113`).
`Cover.url(forHeight:scale:)` then does two things (`Cover.swift:111-121`):

- `57 < 175` selects `x150` — the 150pt-tall variant.
- `scale > 1` swaps `@1` for `@3` on a 3x screen, **unconditionally**.

So the app downloads and decodes a **450px-tall, 300px-wide** bitmap to fill a
frame that is 114×171 device pixels. At 32bpp that is **~540 KB resident per
library row, to draw ~78 KB of pixels** — about 7x the pixels it will ever
show. `byPreparingForDisplay()` (`CoverStore.swift:126`) decodes at the
image's natural size; nothing downsamples to the target.

96 MB ÷ 540 KB ≈ **178 covers**. A 939-row library cannot be held. Past row
~178 the cache is in steady-state eviction, and scrolling back re-downloads
and re-decodes covers the reader saw thirty seconds ago. A full pass costs
roughly **939 × 540 KB ≈ 507 MB of decode work pushed through a 96 MB
window**, and on the wire 939 × (a 300×450 JPEG, call it 40-70 KB) ≈
**38-66 MB of a reader's data**.

The footprint stays *bounded* — this is not a leak and probably not a jetsam
risk. The cost is churn, data, and battery, and it is 7x larger than it needs
to be for one reason: the `@1 → @3` substitution is applied without asking
whether the variant already exceeds the target. See F1 and F2.

**What would measure it, on device, without Allocations.** The instruments
already exist and `docs/unknowns-2026-09-11.md` established that `xctrace`
Allocations is a dead end on device, so:

1. **Footprint.** `phys_footprint` from `task_info(TASK_VM_INFO)`, sampled at
   1 Hz from inside the app in a Debug build, or Activity Monitor sampling as
   the idle number was taken. Run it across a scripted top-to-bottom scroll of
   the 939-row library, then a scroll back up. The scroll-back leg is the one
   that matters — it separates "holding covers" from "re-fetching covers".
2. **Wire bytes.** `NetworkLedger.shared.recordImage(bytes:)` already counts
   every cover at `CoverStore.swift:125`. Read its image total before and
   after the same scroll. If the scroll-back leg adds bytes, eviction churn is
   real and the number is the size of it.
3. **Decode cost.** `Signposts.measure("Cover fetch")` already wraps every
   fetch (`CoverStore.swift:63`). An os_signpost Instruments trace gives the
   count and duration distribution without needing Allocations at all.
4. **The control**, per CLAUDE.md: run the identical scroll over a library
   filtered to ~50 rows. That fits inside 96 MB, so leg 2 must add *zero*
   bytes on the way back up. If it adds bytes there too, the instrument is
   wrong and the 939-row number means nothing.

---

## Findings

### F1. Every cover is fetched and decoded at up to 7x the pixels it draws

- **What** — `Cover.url(forHeight:scale:)` picks a variant by point height and
  then multiplies by the screen scale, without checking that the chosen
  variant already dwarfs the target.
- **Where** — `MangaBaka/Core/Model/Cover.swift:111-121`, reached from
  `MangaBaka/Features/Shared/CoverImage.swift:30`. Worst call site:
  `MangaBaka/Features/Library/LibraryList.swift:66-70`.
- **Why it matters** — a 38pt-wide library thumbnail needs 114×171 device
  pixels. It gets `x150` at `@3`: 300×450, ~540 KB decoded. The smallest
  variant the API offers is already 150pt tall, so for *any* target under
  150pt the `@3` swap is pure waste. Concretely, for a reader with 939 tracked
  series, a full library scroll spends 38-66 MB of data and 507 MB of decode
  on artwork drawn at a seventh of that size. Fix: only apply the scale
  multiplier when `height * scale > variantHeight` — i.e. compare the target
  in device pixels against the variant's own pixel height (150/250/350 × N)
  and pick the smallest N that covers it.
- **Effort** — a function (`url(forHeight:scale:)`), plus a test alongside the
  four already in `CoverTests.swift`.
- **Confidence** — certain on the mechanism and the variant selected; the
  540 KB is arithmetic from a 2:3 300×450 bitmap at 32bpp, not a measurement.

### F2. `96 * 1024 * 1024` is an underived constant that shapes the app's largest memory consumer

- **What** — the cover cache's cost limit carries a comment explaining why it
  is a *cost* limit and nothing about why it is *96 MB*.
- **Where** — `MangaBaka/Core/Images/CoverStore.swift:30-34`. The comment at
  :28-29 justifies bytes-over-entries only.
- **Why it matters** — CLAUDE.md and charter §4 require an underived constant
  to be labelled a guess. This is the single number that decides whether a
  939-row library scroll churns or holds, it is roughly double the app's
  entire measured device footprint (44.8 MB, `docs/unknowns-2026-09-11.md:41`),
  and nobody can currently say whether 96 is too high or too low because the
  interactive measurement described above has never been taken. Compare
  `BlurHashCache.swift:17-19`, which does give its reasoning.
- **Effort** — a line, if the honest answer is "guess". A function, if it
  should instead be derived from `ProcessInfo.physicalMemory` or
  `os_proc_available_memory()`.
- **Confidence** — certain.

### F3. A recycled `CoverImage` shows the *previous* series' cover until the new one arrives

- **What** — `.task(id: url)` restarts the load when the URL changes but
  nothing resets `loaded`, so the stale image keeps rendering.
- **Where** — `MangaBaka/Features/Shared/CoverImage.swift:28` (`@State private
  var loaded`) and `:51-57`. The comment at `:47-50` claims the opposite:
  *"Keyed on the URL so a recycled row loads its new cover rather than keeping
  the old one."*
- **Why it matters** — keying the task controls *when the fetch runs*; it does
  not touch the state that `content` (`:62-63`) draws from. Wherever a
  `CoverImage` keeps its SwiftUI identity across a cover change, the reader
  sees the wrong artwork for the duration of a network round trip. The swipe
  stack is exactly that case: `StackView.swift:85` renders `card(current)`
  with no `.id(current.id)`, so the same `CoverImage` instance is handed a new
  `cover` on every swipe and its `@State` survives. Input that triggers it:
  swipe to a series whose cover is not already in `CoverStore`. The BlurHash
  placeholder — which exists precisely to fill that gap
  (`CoverImage.swift:67-73`) — is skipped, because `loaded` is non-nil. Even on
  a cache *hit* there is one frame of the old cover, because `.task` runs after
  the body that revealed the new series. Fix is one line: replace the body of
  the task's first branch with an unconditional
  `loaded = CoverStore.shared.cached(url)` before the `await`, so a miss clears
  to the placeholder and a hit has no flash.
- **Effort** — a line.
- **Confidence** — certain that `loaded` is never cleared; likely on the
  user-visible stack symptom, since I reasoned about SwiftUI identity from
  `StackView.swift:85` rather than observing it. It is worth a UI test before
  the fix — charter §2: prove it fails first.

### F4. One network blip disables AniList for the whole session

- **What** — every error except `.rateLimited` sets `aniListIsDown`, including
  a transport error, including a cancellation.
- **Where** — `MangaBaka/Core/Characters/CharacterService.swift:58`. The flag
  is declared at `:36` and only ever cleared by `clearOutageMemory()` (`:75`),
  which nothing calls.
- **Why it matters** — `AniListClient.characters` converts *any* thrown
  `URLSession` error into `APIError.transport`
  (`AniListClient.swift:118-120`), and a cancelled request throws. So: open a
  series page, navigate back before the cast lands, and AniList is marked down
  until the app is relaunched — even though it was working. Same for a single
  dropped connection in a lift. The doc at `:54-57` reasons only about "the
  service being unavailable", which is true of a 403 and not true of a
  transport error. AniList is described throughout as the *preferred* source
  (`CharacterService.swift:5-6`, `SeriesCharacter.swift:11`), so this
  permanently downgrades the feature on a transient fault. Fix: only latch on
  `.server` and `.decoding`; let `.transport` pass like `.rateLimited` does.
  This matters more, not less, once AniList comes back.
- **Effort** — a line.
- **Confidence** — certain on the code path. Currently masked in production
  because AniList answers 403 to everything (`AniListClient.swift:5-11`), which
  is why it has not bitten yet.

### F5. `clearOutageMemory()` has no caller anywhere, production or test

- **What** — a documented reset that nothing invokes.
- **Where** — `MangaBaka/Core/Characters/CharacterService.swift:74-77`. Its
  doc says *"Lets a new launch — or a test — try AniList again."* A grep for
  `clearOutageMemory` across the whole repo returns that declaration and
  nothing else.
- **Why it matters** — charter §3 warns that half of what a dead-code scan
  reports here is a behavioural gap. The "new launch" half is genuinely
  handled elsewhere: `AppServices.swift:22` builds one `CharacterService()` per
  launch, so the flag starts false. The "or a test" half is simply false —
  no test calls it, and `CharacterSourceTests.swift` builds a fresh service
  instead. So this is real dead code *and* it documents a caller that does not
  exist. It becomes live the moment F4 is fixed, because the right pairing is
  "clear on `NWPathMonitor` reporting the network back". Do not delete it
  without deciding F4 first.
- **Effort** — a line to delete, or a function to wire.
- **Confidence** — certain.

### F6. An undecodable cover is downloaded twice, every single time it appears

- **What** — the retry loop treats "`UIImage(data:)` returned nil" as a
  retryable failure and re-downloads the identical bytes.
- **Where** — `MangaBaka/Core/Images/CoverStore.swift:109-117`. `UIImage(data:
  data)` is inside the same `guard` as the status check, so a 200 carrying an
  image the decoder cannot read falls into the `else`, fails the 404 test at
  `:115`, and `continue`s.
- **Why it matters** — the second attempt downloads the same bytes and fails
  identically; `fetch` then returns nil, and nil is deliberately never cached
  (`:72-74`). So every reappearance of that cover on screen costs **two** full
  downloads, forever. With `prefetch` (`:84-89`) firing ahead of the scroll,
  a handful of bad covers in a 939-series library is a permanent, silent
  doubling of image traffic on a reader's connection. Fix: split the guard so a
  decode failure returns nil immediately rather than retrying.
- **Effort** — a function.
- **Confidence** — certain on the control flow; I have not confirmed the
  MangaBaka CDN actually serves any undecodable cover, so the *frequency* is
  unknown. Worth checking against the 939-series library before prioritising.
- **Related, same lines:** a non-404 bad status (503, 502) also `continue`s
  with **no** pause — the 400ms backoff at `:132` is only in the `catch`
  branch. A struggling server gets two back-to-back requests.

### F7. BlurHash decode runs synchronously on the main thread, inside `body`

- **What** — a cache miss decodes the hash on whatever thread asks, and the
  only caller asks from a SwiftUI `body`.
- **Where** — `MangaBaka/Core/Images/BlurHashCache.swift:22-28` (the decode at
  `:25` is inline and synchronous), called from
  `MangaBaka/Features/Shared/CoverImage.swift:23-26`, which is a computed
  property read by `content` at `:67`.
- **Why it matters** — the comment at `CoverImage.swift:21-22` says *"Decoded
  once per cover... so it is not recomputed on every layout pass."* A computed
  property is re-evaluated on every body evaluation; what actually saves it is
  the `NSCache` hit, not the property. On a **miss** the full decode runs in
  the layout pass. Cost of one miss, from `BlurHash.swift:72-92`: for a typical
  4×3 hash at the default 32×32, `32 × 32 × 12` inner iterations with two
  `cos` calls each — ~24,600 `cos` — plus three `pow` per pixel in
  `linearTosRGB` (`:147-151`), ~3,100 more. A screen of 12 covers scrolling
  into view fresh is ~330,000 transcendental calls in one frame, on the main
  thread. Misses are not rare in the case that matters: the `NSCache` purges
  everything on a memory warning, which is exactly what a 939-row scroll
  provokes. Fix: keep the cache lookup synchronous (so a hit stays flash-free)
  but move a miss to a detached task that writes back into `@State`.
- **Effort** — a function, plus correcting the comment at `CoverImage.swift:21-22`.
- **Confidence** — certain that the decode is synchronous and reachable from
  `body`; the frame-cost figure is arithmetic from the loop bounds, not a
  profile. Signpost it before fixing.

### F8. `CoverStore` has an injectable session seam and zero tests

- **What** — `init(session: URLSession = .shared)` exists for testing
  (`CoverStore.swift:39-41`) and no test uses it. `grep -rl CoverStore
  MangaBakaTests` returns nothing.
- **Where** — `MangaBaka/Core/Images/CoverStore.swift:39-41`, against an empty
  result across `MangaBakaTests/`.
- **Why it matters** — the class doc (`:14-22`) makes four behavioural claims:
  dedupes, caches successes, retries a failure once, never caches a failure.
  Every one is testable through that seam with a stub protocol, and none is
  tested. F6 is a bug in exactly that untested retry path — that is what an
  untested seam costs. Also untested: the 404 short-circuit (`:115`), the cost
  accounting (`:142-144`), and that `NetworkLedger` still receives bytes —
  the comment at `:121-124` records that this very line silently failed to
  apply once and reported "zero KB of cover art".
- **Effort** — a file (`CoverStoreTests.swift`).
- **Confidence** — certain.

### F9. BlurHash accepts a 10-component-tall hash the reference implementation rejects

- **What** — the size flag is decoded without an upper bound on `componentsY`.
- **Where** — `MangaBaka/Core/Images/BlurHash.swift:40-43`.
  `componentsY = (sizeFlag / 9) + 1`, and `sizeFlag` can reach 82, giving
  `componentsY == 10`. The reference implementation validates both counts
  into `1...9`.
- **Why it matters** — bounded and not a crash: the length check at `:43`
  (`hash.count == 4 + 2 * componentsX * componentsY`) means a malformed hash
  is rejected unless its length happens to match, and the render loop stays
  finite. But a 24-character hash whose first character decodes to 81 is
  accepted as a 1×10 hash and decoded into something the encoder never meant.
  Given the hashes come from a community-maintained database, the right
  posture is to reject rather than render nonsense. One line at `:42`.
- **Effort** — a line, plus a case in `BlurHashTests.rejectsGarbage`.
- **Confidence** — certain on the arithmetic; cosmetic in consequence.

### F10. Cover art is rendered from a 24bpp CGImage, which CoreAnimation cannot use directly

- **What** — the BlurHash image is built at `bitsPerPixel: 24` with
  `CGImageAlphaInfo.none` and a `bytesPerRow` of `width * 3`.
- **Where** — `MangaBaka/Core/Images/BlurHash.swift:69`, `:94-101`.
- **Why it matters** — CoreGraphics and CoreAnimation's fast paths want 32bpp
  with `.noneSkipLast`/`.premultipliedFirst` and a word-aligned row stride.
  A 24bpp, 3-byte-stride image is converted at draw time, on every draw, on
  the main thread. At 32×32 this is small — but it is per placeholder, per
  frame, during the scroll where placeholders are most numerous. Changing to
  4 bytes per pixel costs 1 KB per cached placeholder (~0.4 MB across all 400)
  and removes the conversion.
- **Effort** — a function (`render`).
- **Confidence** — worth checking. The conversion cost is a documented
  CoreGraphics property, not something I measured here; profile a scroll before
  changing it.

---

## Checked and found clean — negative results, recorded per CLAUDE.md

These were hunted deliberately. Writing them down so they are not re-hunted.

- **The recursive-subscript class of bug is not present.** Every indexing
  expression in `BlurHash.swift` uses the standard `Array`/`ArraySlice`
  subscript: `characters[0]`, `characters[1]`, `characters[2..<6]` (`:40, :45,
  :52`) and `characters[start..<start+2]` (`:56`). There is no custom
  `subscript` declaration in the file.
- **The decode is bounded and in-bounds.** With `N = componentsX *
  componentsY`, the length check at `:43` fixes `hash.count == 4 + 2N`, and the
  highest index read is `start + 2 = 2N + 2 ≤ 4 + 2N`. The render loop's
  highest write is `3(w-1) + 2 + (h-1)·3w = 3wh - 1` against a buffer of
  `3wh` (`:70, :87-90`). A hostile hash cannot read or write out of range, and
  cannot make the decode take unbounded time — the work is capped by the hash
  length, which is capped at 184 characters.
- **`UInt8(linearTosRGB(...))` at `:88-90` cannot trap.** `linearTosRGB`
  clamps to `0...1` at `:148` before the transfer function, and the maximum
  output is `Int(1.0 × 255 + 0.5) = 255`. Reaching 256 would need a clamped
  sRGB value above 1.002, which the clamp forbids.
- **No force-unwraps reachable from real input anywhere in the slice.** The
  two `preconditionFailure`s (`AniListClient.swift:205`,
  `SeriesCharacter.swift:173`) fire only on a hard-coded literal URL failing to
  parse — a build-time constant, not input. Charter asked for this claim to be
  re-verified rather than assumed; for these six files it still holds.
- **The "failed cover is retryable" claim is true.** `fetch` returning nil is
  never written to the cache (`CoverStore.swift:72-74`) and `inFlight` is
  cleared unconditionally (`:70`), so the next `.task` re-run asks again.
  `.task(id:)` does re-run on reappearance. Claim verified, unlike its sibling
  in F3.
- **The "deliberately not cancelled" claim is true.** `image(for:)` creates an
  **unstructured** `Task` at `:62`, which does not inherit cancellation from
  the caller, and `await task.value` on a `Task<UIImage?, Never>` cannot throw.
  A row scrolling away does not kill the download. Claim verified.
- **No dedup race in `image(for:)`.** The window between the `inFlight` read at
  `:57` and the write at `:68` contains no `await`, and the method is
  `@MainActor`, so two callers cannot both create a task for one URL.
- **`prefetch` fan-out is bounded in practice.** `DiscoverView.swift:224-231`
  asks for 3 ahead; `SearchView.swift:253` uses a distance of 6. `prefetch`
  itself (`CoverStore.swift:84-89`) has no cap, but no caller currently
  exercises that.
- **No reader data leaves the app from this slice.** The only outbound header
  with any identity in it is Shikimori's required User-Agent
  (`SeriesCharacter.swift:99`), which names the app and its public repo and
  carries nothing about the reader. No telemetry, no third-party endpoint.
- **Character fetching cannot fire per keystroke.** Both clients are actors
  with their own spacing, and both are reached only from
  `SeriesDetailView.loadCast()` (`:307-318`), which runs once per series page.

## Question 4, answered directly

**What, from whom, at what rate.** `CharacterService` asks AniList's GraphQL
endpoint first (`AniListClient.swift:34`, `https://graphql.anilist.co`) for up
to 25 cast members sorted by role then relevance (`:45-53`), and falls back to
Shikimori's `/api/mangas/{id}/roles` (`SeriesCharacter.swift:123`). Both are
third-party APIs, neither is MangaBaka.

**Rate limiting: yes, correctly, and separately — which is right.** Each client
is an `actor` holding its own `nextAllowedRequest` and a `waitForSlot()`
(`AniListClient.swift:190-200`, `SeriesCharacter.swift:158-168`), and both
honour a `429`'s `Retry-After` by pushing that date out
(`AniListClient.swift:125-129`, `SeriesCharacter.swift:138-142`). AniList is
spaced at 700ms against a published 90/min; Shikimori at 250ms against a
published 5/sec. Both intervals carry their derivation in a comment. These are
*different hosts* from MangaBaka's own API, so sharing MangaBaka's 30/180 limiter
would be wrong, not right. **The spacing actually holds across series pages**
because `AppServices.swift:22` creates exactly one `CharacterService()`, which
creates one client of each in its default arguments
(`CharacterService.swift:37`) — had the service been constructed per view, each
page would have got a fresh limiter and the actor would have been decorative.
That is worth keeping in mind if `AppServices` is ever refactored.

**Is a character fetch cancelled when the series page goes away?** Yes —
structurally, and that is the problem. `loadCast()` is an `async` call awaited
from the detail view, so it runs inside the view's task tree and is cancelled
on dismissal. `URLSession.data(for:)` throws on cancellation, and both clients
convert any thrown error into `APIError.transport`
(`AniListClient.swift:118-120`, `SeriesCharacter.swift:131-133`). The
Shikimori path swallows that harmlessly through `try?`
(`CharacterService.swift:63`). The AniList path does not — it latches
`aniListIsDown`. **That is F4**: dismissing a series page mid-fetch is
indistinguishable, to this code, from AniList being down.

---

## What this slice does well

Held to the same evidence standard.

- **`BlurHashTests.swift` is the best-constructed test file I read.** The
  fixture is a *recorded* hash with its endpoint and date (`:8-9`, from
  `/v2/series/discover/rising` on 2026-09-08) — provenance, which charter §2
  says is what was missing when five release-calendar tests passed against a
  payload the API never sends. It deliberately picks a 9×9 hash rather than the
  common 4×3 *because* it exercises the size-flag arithmetic (`:9-10`). And
  `producesColour` (`:26-36`) is an explicit **control**: it asserts the
  decoded reds are not all identical, so a decode that silently produced grey
  would fail rather than pass. CLAUDE.md asks for a control with every
  measurement; this file actually has one.
- **`Cover.init(from:)` is the fix for charter §1, written down.**
  `Cover.swift:22-35` names both live shapes, both endpoints, the verification
  date (2026-09-09), and what the bug cost — the swipe stack silently falling
  back to a random queue for a reader with 937 series. The `variant(_:)` helper
  (`:41-49`) then handles string-or-object per field rather than per response,
  which is the shape-tolerant form.
- **`RawDetail.resolvedURL` catches a trap on the way past.**
  `Cover.swift:78-81`: it deliberately resolves to `x1`, with the comment
  *"Picking x2 here would silently double every image request on a 3x screen"* —
  someone noticed a bug that had not happened yet. (F1 is the other half of
  that same thought, left undone.)
- **`AniListClient.Payload.CodingKeys` pre-empts a known trap.** `:69-73` maps
  the capitalised `Media` key and says *why*: the same capitalised-key failure
  the library's `Series` key already caused once. That is a lesson applied
  forward rather than re-learned.
- **`AniListClient` handles GraphQL's real failure mode.** `:144-152` treats a
  200 carrying an `errors` array and no data as a failure, with the reason:
  otherwise the fallback never runs and the reader gets an empty cast row.
  Most hand-rolled GraphQL clients get this wrong.
- **`CoverStore`'s `nonisolated` comment is a model of the standard CLAUDE.md
  asks for.** `:91-104` records the actual bug (inherited `@MainActor`
  isolation decoded every cover on the main thread, in competition with the
  scroll that revealed it), why `byPreparingForDisplay` matters for the same
  reason at the other end, and what happens when it returns nil. And `:121-124`
  keeps a dead instrument's post-mortem: *"An instrument that reads zero is
  worse than no instrument."* Charter is right that comments like these are
  why several of the bugs above were findable at all.
- **`ShikimoriCast.cast` states its evidence.** `SeriesCharacter.swift:47-58`:
  three transformations, each with the reason, checked against Solo Leveling's
  live response on 2026-09-10, with the counts — 98 rows, 95 with a character.
  The placeholder-portrait filter (`:42-44`) is derived from an observation
  about the data, not guessed, and `AniListClient.isPlaceholderPortrait`
  (`:24-26`) applies the same lesson to the other source.
- **`CharacterService`'s silence is argued, not assumed.** `:10-18` explains
  why a fallback is invisible to the reader (they have no stake in which
  tracker answered) while still being *inspectable* through `lastOutcome` — the
  distinction between "silent" and "unrecorded", made explicitly so a test can
  prove the fallback ran.
- **`AniListClient`'s header comment is the honest kind.** `:5-11` states
  plainly that the entire path is unverifiable against the live API, that the
  403 was checked repeatedly on 2026-09-10 so it is not a blip, that the code
  is written from the published schema and tested only against recorded
  shapes, and what to check first when AniList returns. CLAUDE.md asks for the
  unsures to be brought; this file brings its own.
