# Live walk: Discover tab + Stack tab

Device: iPhone 16 Pro simulator, `dev.abdirahmanmohamed.mangabaka`, today's build.
Method: real taps/swipes via the iOS Simulator, screenshots via `xcrun simctl io screenshot`, read back and inspected. Screenshots referenced below are in `walk-discover/` next to this file's source scratchpad (not committed — see notes at end).

All findings below are **observed** unless marked guessing.

## Discover

### 1. Cold open (`01-cold-open.png`)
- Header: "Discover / Monday · 463 series cached".
- **Pick back up** is present and populated on the very first frame — three real covers (無職転生, 罪と罰 vol.1, a Korean-titled assassin series), chapter numbers (ch 120/53/138), "69 in progress" count. Covers were already rendered by the time the screenshot was taken (no visible placeholder/skeleton moment caught). This looks like the "don't wait for a Library visit" fix is working.
- **Recently viewed** below it: three real covers + titles, populated immediately.
- **Rising this week** starting to render at the very bottom edge, cut off by the tab bar.
- No skeleton row was ever caught empty in any screenshot taken during this walk.

### 2. Scroll to bottom (`02-scroll1.png`, `03-scroll2.png`)
- Every row loaded with real covers: Rising this week, Hidden gems, Trending, New releases.
- Bottom of the feed ends in a stats card, "THIS WEEK ON MANGABAKA": chapters read, series in the database, people keeping libraries.
- **Finding (observed, worth checking):** the last stat line reads "27,195 of them are yours" directly under "19,735 people keeping libraries." Read literally, 27,195 can't be a subset of 19,735 — the "of them" pronoun doesn't have a valid antecedent among the numbers on screen. It's most likely meant to attach to a different stat (e.g. total series in your library, or chapters), and got left pointing at the wrong line. Screenshot: `03-scroll2.png`.
- No row said "Cancelled," "Couldn't load," or sat empty — nothing broken here.
- Nothing else to scroll past — this stats card is the true bottom of Discover.

### 3. Tab switch and back (`04`–`08`)
- Switching to Library and back to Discover: Discover was still scrolled to top with the exact same content, no reload flash, no flicker. The "reselect shouldn't reload everything" fix appears to hold.
- Also noticed while scrolled to the bottom: the floating tab bar collapses down to just two round buttons (a mic/record-style icon and search) once you're deep in the scroll, and the full pill with all four tab labels only reappears near the top. This reads as an intentional auto-hide/collapse behavior, not a bug, but flagging since a first-time reader might think the tab bar vanished. Screenshots `03`, `04`.

### 4. Cover → series page → back (`09`, `10`)
- Tapping "Gekijouban Hunter x Hunter: Hiiro no Genei" opened a full series page: rating, chapter/volume counts, synopsis, genres, tag groups, "Use as seed."
- Back button returned to Discover exactly where it was (top, same rows, same order). Correct.

### 5. Pull to refresh (`11`)
- Attempted a pull-to-refresh gesture at the top of the list. The screenshot taken right after shows the identical layout with no visible spinner and no reordering/flicker — but I can't be certain the gesture actually registered as a refresh vs. just a soft scroll-bounce, since a manual screenshot can easily miss a fast-completing spinner. **Guessing / inconclusive**: could not confirm pull-to-refresh visibly fires.

### 6. Long-press a cover (`12`)
- Long-press produced a context menu, but it only contained **"Copy cover."** No Save, Mark read, or Open action was present — just the one item. If the intent was a fuller menu (Save / Mark read / Open / Copy cover), three of four actions are missing from Discover's long-press menu.

### Library tab — surfaced in passing, real inconsistency
- While switching tabs, Library showed: header stats "945 series · 429 dropped · 425 rated" — but the body says **"No library yet — Add a MangaBaka token in Settings and everything you track there appears here."** Screenshot: `07-library-tab.png`.
- This is a real, observed contradiction: the header claims a populated library (945 series etc.) while the content area says no token is configured and the library is empty. Either the header stat is stale/hardcoded, or the "no library" empty state is showing incorrectly for a user who does have data (which lines up with Discover's Pick-back-up/Recently-viewed rows being fully populated with real reading progress). This deserves a code look — the two screens disagree about whether this install has a MangaBaka account linked.

## Stack

### 7. Cold open, swipe right/left (`13`, `19`, `20`)
- Cold open: one card ("The Graymark," Manhwa/2024/7.5), "1 saved" already counted before I touched anything, "Drag the cover aside · tap it to open" instruction text, tag chips, a "Shares X, Y, Z with what you read" line, X / Details / + buttons.
- Swipe right (save direction) advanced the card, saved count incremented (1→3 across two swipes-right total), and a "Saved from the stack / Shelf ›" strip appeared at the bottom once at least one card had been saved by any method — good, visible feedback, though it's a persistent shelf strip rather than a transient toast (see below).
- Swipe left (skip) advanced the card without changing the saved count. Cards visibly changed underneath (new cover, new title, new tags) confirming real progression, not a static demo.
- No toast/snackbar was ever observed after a save or skip — feedback is the incrementing counter and the "Saved from the stack" shelf strip, not a toast.

### 8. Tapping × and + directly (`14`–`18`)
- First attempt at tapping × landed on the cover artwork instead (misjudged the button's position) and opened the series detail page instead of skipping — that was an input-precision mistake on my part, not a bug; confirmed by re-measuring pixel coordinates from the screenshot.
- Once correctly aimed: **× (skip)** advanced to a new card without changing "saved." **+ (save)** advanced to a new card and incremented "saved" by one (1→2) and later triggered the "Saved from the stack" strip. Both buttons work identically to their swipe equivalents.

### 9. Button position vs. tab bar (`14`–`25`)
- The ×, Details, and + buttons sit clearly above the floating tab bar in every screenshot, with visible black gap between them — never overlapping or obscured. Good.

### 10. Exhausting the stack
- Performed roughly 15 swipes (mix of left/right) plus 2 direct button taps — 17 card advances total. The stack never ran out and never showed an empty state; a fresh, different cover appeared every single time, tags and titles all real and distinct (no repeats seen). The "saved" counter topped out at 3 within my sample (I only swiped right twice, left/× far more).
- One thing to note: a circular progress ring next to the saved counter visibly filled in over the course of the swipes (small arc → nearly a full circle) — it looks like it's tracking progress through some batch/session of cards, but I did not see it complete or trigger anything before I stopped (budget).
- **Could not test:** what the empty state says or whether more cards can be requested afterward — the deck is deeper than the ~70-tool-call budget allowed me to exhaust. This needs either a longer session or a way to jump near the end of the deck.

### Bonus: rate limit / throttle copy (`15-stack-after-x2.png`)
- Opening a card's series detail page (via cover tap on "The Graymark") surfaced: **"Too many requests, briefly — MangaBaka is throttling this connection. The limit is shared by everyone on your network, so this may not be you at all."** with a Retry button. This is worth calling out as a genuinely good error state: it names the cause, tells the user it's plausibly not their fault, and offers a clear retry — better than a generic "something went wrong."

## Summary of what's broken / confusing / good

**Broken (observed):**
- Library tab shows contradictory state: header says "945 series · 429 dropped · 425 rated," body says "No library yet." (`07-library-tab.png`)
- Discover's "This week on MangaBaka" stat block: "27,195 of them are yours" doesn't logically attach to the "19,735 people keeping libraries" line above it — number is larger than its claimed set. (`03-scroll2.png`)

**Confusing:**
- Discover's long-press menu on a cover offers only "Copy cover" — no Save / Mark read / Open, if those were meant to be there. (`12-longpress.png`)
- Floating tab bar collapses to two icons when scrolled deep into Discover; easy to mistake for the tab bar disappearing.
- No toast on Stack save/skip — feedback is a counter tick and a shelf strip only.

**Good:**
- Discover cold open is fully populated (Pick back up, Recently viewed) with no empty/skeleton moment caught, and tab-switch-and-back preserves scroll position and content without reloading.
- Cover → series page → back round-trip in Discover preserves exact scroll state.
- Stack swipe and button paths (×, +) both work and stay clear of the tab bar.
- The MangaBaka throttling message is the best copy seen this walk: names the cause, says it may not be the user's fault, gives a retry.

**Could not test (budget/tooling limits):**
- Whether pull-to-refresh visibly spins (gesture may not have registered; screenshot timing inconclusive).
- The Stack's actual empty state and whether it offers a way to get more cards — the deck outlasted a 17-card sample.
