# App Store screenshots

How to capture the six main screens for App Store listing screenshots, with
placeholder covers instead of real cover art (licensing — real covers may not
appear in screenshots or promo material, per Abdi 2026-09-15).

## What this does and does not do

- `ScreenshotCaptureTests` (`MangaBakaUITests/ScreenshotCaptureTests.swift`)
  launches the app with `-placeholder-covers`, walks Discover, a series
  page, Search, Stack, Library and Mix, and saves one PNG per screen to
  `/tmp/mb-shots/`.
- `-placeholder-covers` flips `ScreenshotMode.isActive`
  (`MangaBaka/Features/Shared/ScreenshotMode.swift`), which makes every
  `CoverImage` draw a generated gradient instead of fetching network art or
  drawing its BlurHash — see the comments on `CoverImage.background` and
  `CoverImage.load()`. No image request for real artwork is made while it is
  set.
- This only captures raw screenshots. Device framing, marketing captions, and
  picking the final set for submission are a separate step, done by hand
  afterward (e.g. in a design tool, or Apple's own framing in App Store
  Connect / Fastlane's `frameit`) — not part of this test.

## Running it

The test is gated on the `MB_CAPTURE_SCREENSHOTS` environment variable so it
never runs as a side effect of the ordinary accessibility scheme or any unit
test invocation:

```swift
guard ProcessInfo.processInfo.environment["MB_CAPTURE_SCREENSHOTS"] == "1" else {
    throw XCTSkip(...)
}
```

**`xcodebuild` does not forward the invoking shell's environment to the test
runner process.** Setting `MB_CAPTURE_SCREENSHOTS=1` in front of the
`xcodebuild` command itself will *not* reach `ProcessInfo.processInfo.environment`
inside the test bundle — that only controls the `xcodebuild` process, not the
simulator's test host. Two ways that do work:

1. **`TEST_RUNNER_` prefix** (simplest, no test plan needed). `xcodebuild`
   strips a `TEST_RUNNER_` prefix off any environment variable it is given
   and forwards the rest into the test runner's environment:

   ```sh
   TEST_RUNNER_MB_CAPTURE_SCREENSHOTS=1 xcodebuild test \
     -scheme MangaBakaAccessibility \
     -only-testing:MangaBakaUITests/ScreenshotCaptureTests \
     -destination '<a simulator, e.g. platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest>'
   ```

   This is what to use unless a test plan is already in play.

2. **`-testPlan` environment variable overrides.** If the scheme already runs
   a `.xctestplan`, add `MB_CAPTURE_SCREENSHOTS` under that plan's
   `environmentVariableEntries` (Test Plan → Configurations → Environment
   Variables in Xcode, or hand-edit the `.xctestplan` JSON) and pass
   `-testPlan <name>` on the `xcodebuild test` line instead. Not needed here
   unless a test plan already exists for this scheme.

Either way, screenshots land at `/tmp/mb-shots/01-discover.png` through
`06-mix.png`; each path is also printed to the console as it is written.

## Device sizes Apple wants

Per Apple's own screenshot specification page
(<https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications>,
fetched 2026-09-15 — **worth reconfirming by eye before submitting**, since
Apple's display-size categories shift as new iPhones ship and this was read
through an automated fetch, not a screenshot of the page):

- **6.9" display — required** (unless 6.5" screenshots are supplied and
  scaled up instead): portrait pixel sizes **1290 × 2796** or **1320 × 2868**
  depending on which 6.9"-class device rendered them. Devices in this class
  per the fetched page: iPhone 17 Pro Max, iPhone 16 Pro Max, iPhone 16 Plus,
  iPhone 15 Pro Max, iPhone 15 Plus, iPhone 14 Pro Max, iPhone Air.
- **6.7" display**: the fetched page did not list "6.7"" as its own current
  category — it appears folded into the 6.9" grouping above (which is odd
  given the 14 Pro Max/15 Plus were historically marketed as 6.7" devices).
  Flagging this rather than guessing: confirm on the live page, or by opening
  App Store Connect's own media-manager upload slots for this app, which
  ones it actually asks for before picking a simulator.
- Practical takeaway for `-destination`: run the capture test against
  whichever simulator name currently maps to the required large-format
  class — e.g. "iPhone 17 Pro Max" — and check the saved PNG's pixel
  dimensions (`sips -g pixelWidth -g pixelHeight <file>.png`) against
  whatever size App Store Connect's upload UI is asking for at submission
  time, since simulator device availability changes with each Xcode release.

## Unsures

- Whether "6.7"" is truly gone as a distinct required category or the fetch
  simply summarized the page imprecisely — not independently re-verified
  beyond the one fetch above.
- Which simulator name on the machine that eventually runs this maps to the
  6.9"-class required size; not checked here, since I did not build or run
  the simulator (see below).

I did not build.


## First capture — 2026-09-15, 02:5x

Six frames at **1320 × 2868** (iPhone 17 Pro Max, iOS 27.0 simulator — the
6.9" size Apple lists as required), saved to `~/Desktop/MangaBaka-screenshots/`.
Read by a Haiku pass: no real cover art on any frame; every cover is the
generated gradient placeholder, including the series page's blurred backdrop
(which reads `CoverStore` directly — gated there too, after the first run
showed art through it).

What each frame shows, and what to know before framing:
1. Discover — "Pick back up", "Rising this week", "Hidden gems"; titles
   from the account's own library (the Debug build carries the local token).
2. Series page — Mushoku Tensei, full metadata, placeholder cover.
3. Search — **the filter panel, not results**: Return submits and then the
   filters sheet is what the capture caught. Worth a second pass that taps
   into the results grid; the UI test's `captureSearchResults` is the place.
4. Stack — one card.
5. Library — signed-in shape (948 series), the three info cards.
6. Mix — the honest empty state ("Nothing saved yet. Swipe a few series in
   the Stack first."). A framed set probably wants a Mix with seeds.

Frames, captions and the device bezel are a separate step (Apple accepts
unframed screenshots; framed ones look better in the listing).

## Second pass — prepared 2026-09-15, not yet run

Two changes to `ScreenshotCaptureTests`, written while the simulator lane was
taken and **not yet exercised**:
- Search waits for a result card whose label contains the query before
  capturing, instead of any text + any image (which the idle page's inline
  filter panel satisfied — that is why frame 3 was the panel).
- The series-page step taps "Use as seed" after its capture, so Mix (frame 6)
  shows a blend with one seed rather than the empty state.

Run it the same way (`TEST_RUNNER_MB_CAPTURE_SCREENSHOTS=1 …`) once the lane
is free; if "Use as seed" is not on the first Discover card's page, frame 6
falls back to the empty state and nothing else changes.

