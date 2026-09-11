# Deep review — the surface slice

`Features/Detail`, `Features/Settings`, `Features/Shared`, `DesignSystem`, `App`.
Read-only pass, 2026-09-11. No build was run.

## Denominator

55 Swift files, 6,364 lines in the slice. **34 files read line by line (~4,200
lines)** — everything named in the three questions, every file over 100 lines,
and every file the questions touch transitively. The remainder were grepped for
specific patterns but not read: `DetailScheduleBlock`, `DetailEditions`,
`DetailOnwardRows`, `DetailStatsStrip`, `DetailSynopsis`, `DetailTagSections`,
`VolumesSection`, `AlternativeTitles`, `LinksSection`, `CharacterRow`,
`TitleSection`, `FormatSection`, `RemindersSection`, `HistorySection`,
`AttributionSection`, `BlockedTagsSection`, `TokenStatus`, `InlineSearchField`,
`CopyableArtwork`, `RatingSegments`, `SectionHeader`. **Those 21 files are not
reviewed. Nothing below is a claim about them.**

23 findings. Nothing here is already closed in `docs/findings-todo.md` or
`docs/unknowns-2026-09-11.md`; where a finding touches a closed item it says so
and says what is left over.

---

# Part 1 — Findings

## F1. The series page fetches the full record, merges it, and then hands two sections the unmerged copy

**What.** `shown` exists precisely so a series arriving from a v2 feed gets the
fields a v2 payload does not carry. Two children are passed `series` instead.

**Where.** `SeriesDetailView.swift:77` — `DetailCredits(series: series)`, and
`SeriesDetailView.swift:87` — `TrackerScores(series: series)`. Every other
child on that screen takes `shown` (lines 61, 71, 73, 96, 101).

**Why it matters.** `Series.filling(gapsFrom:)` fills `authors`, `artists`,
`publishers`, `contentRating`, `anime` and `source`
(`Series.swift:200-215`). Those six are the entire input to
`DetailCredits.rows` (`DetailCredits.swift:45-70`) and the entire input to
`TrackerScores.entries` (`TrackerScores.swift:12-18`). Both views render
nothing when their input is empty (`TrackerScores.swift:21`, and `rows` simply
returns `[]`). The doc comment on `shown` names the cause itself:
*"A feed's v2 payload has no description, no chapter count, no status and no
`source`"* (`SeriesDetailView.swift:44-46`) — `source` being the one
`TrackerScores` reads.

Concretely: open any series from Discover, the Stack, Mix, or a related-series
row and the credits table and "Scores elsewhere" are both absent. Open the same
series from Search and both appear. This is the exact bug the `shown` property
was written to fix (charter pattern 3), reintroduced in two lines.

**Effort.** Two words.
**Confidence.** Certain — the merge function, both consumers and both call
sites were read.

## F2. The toast is the app's only confirmation for a write, and VoiceOver never hears it

**What.** A toast appears, is marked static text, and is never announced.

**Where.** `Toast.swift:37-58`. `grep -rn "UIAccessibility.post\|announcement"
MangaBaka/` returns **zero hits** across the whole app.

**Why it matters.** `ToastCentre` is the confirmation for a stack save
(`RootView.swift:111`), a library write, a seed being added
(`RootView.swift:241`) and a copy. The overlay sets
`.allowsHitTesting(false)` (`Toast.swift:56`), so VoiceOver focus never lands
on it, and nothing posts an announcement — so a VoiceOver reader who saves a
series gets a success haptic (`Toast.swift:64`) and no words. The doc comment
argues the toast exists because *"an action that gives no sign it worked is
indistinguishable from one that missed"* (`Toast.swift:7-8`); for VoiceOver
that is still true.

**Effort.** One line — `AccessibilityNotification.Announcement(message).post()`
in `ToastCentre.show`.
**Confidence.** Certain.

## F3. The Reduce Motion pass documents the gallery glide as fixed; the gallery glide is not

**What.** `Motion.swift`'s own doc comment names the cover gallery as one of the
fourteen surfaces it brought under Reduce Motion. The gallery's actual glide
never consults it.

**Where.** `CoverGallery.swift:85-94` — a `.scrollTransition(.interactive, …)`
applying `scaleEffect`, `opacity` and a 14° `rotation3DEffect`, with no
`Motion`, no `reduceMotion` environment read, and no guard. Compare
`Motion.swift:7-9`, which lists *"the cover gallery"* among the surfaces that
"glided, expanded, slid and bounced regardless", and `findings-todo.md` C6,
which names "the gallery glide" and is ticked closed.

The only place in that file that does honour Motion is the double-tap zoom
(`CoverGallery.swift:246`).

**Why it matters.** A 3D rotation tracking the reader's thumb is the single
most vestibular thing in the app, and it is on the screen a reader opens to
look at artwork. The comment and the closed finding both say it is handled.
This is charter pattern 5 in its documentation form: the record says the number
moved, and one of the named surfaces did not.

**Effort.** A function — `scrollTransition` has no animation to nil out, so the
transform itself has to be skipped when `Motion.isReduced`.
**Confidence.** Certain; both files read in full.

## F4. `ScrollEdge.windowTopInset` asks the process for a window, not this view for its scene

**What.** The scrim's height comes from `UIApplication.shared.connectedScenes`,
flat-mapped over every window in every scene, taking the first key one.

**Where.** `ScrollEdge.swift:34-39`.

**Why it matters**, case by case:

- **iPhone portrait, notch or Dynamic Island** — correct. One scene, one key
  window, inset 59pt. This is the case it was measured against.
- **iPhone landscape** — `safeAreaInsets.top` is 0 with the status bar hidden,
  so `height` collapses to `Metrics.scrollEdgeFade` = 14 and the first two
  gradient stops both land at location 0. The scrim degenerates to a bare 14pt
  fade with no solid section. Harmless, but it is protecting nothing, and the
  fade is now the whole effect rather than the tail of it.
- **iPhone with no notch (SE)** — inset 20pt; works.
- **iPad, Split View or Slide Over** — the inset is still the display's, not the
  app's pane. Correct by luck: the top inset is shared. But
- **iPad, Stage Manager or any second scene** — `connectedScenes` contains more
  than one `UIWindowScene`. `first { $0.isKeyWindow }` returns whichever window
  currently holds key across the *process*, which in a two-window session is not
  necessarily the window this view is in, and during a scene handoff is
  sometimes none at all. `?? 0` then silently produces the 14pt degenerate
  scrim, which is the case the modifier was built to prevent.
- **Rotation** — `windowTopInset` is read inside `scrim`, so it is only
  re-evaluated when the body is. The only thing the modifier observes is
  `travelled` (`ScrollEdge.swift:49-54`). A rotation at rest does not change
  `travelled`. Whether SwiftUI re-evaluates the body anyway for the size-class
  change is plausible but not something I can assert without running it.

The comment at `ScrollEdge.swift:57-62` is honest and correct about *why* a
`GeometryReader` inside the overlay reports zero. The fix it reaches for is one
level too broad: the view's own scene is reachable via
`@Environment(\.scenePhase)`-adjacent APIs or, more simply, by measuring in a
`GeometryReader` placed in the scroll view's `background` outside the safe-area
consumption (the pattern `EdgeSwipeToDismiss.swift:28-33` already uses in this
same slice, with a comment explaining exactly that choice).

**Effort.** A function.
**Confidence.** Certain about the code; **likely** about the iPad/Stage Manager
outcome, which I could not run.

## F5. `DetailBarTitle.heroTitleTravel` is fitted to one text size and the hero moves 230pt at another

**What.** The bar title fades in after 150pt of scroll. The hero's own title
sits much further down at accessibility text sizes.

**Where.** `DetailBarTitle.swift:22-23`, `static let heroTitleTravel: CGFloat =
150`, commented *"Measured against the hero on an iPhone 16 Pro rather than
picked"*.

**Why it matters.** `DetailHero` switches from side-by-side to a vertical stack
at accessibility sizes (`DetailHero.swift:34-41`), putting a 150pt-wide cover
(`Metrics.coverDetailHeroWidth`) *above* the title instead of beside it — the
title starts roughly 225pt further down. The schedule block
(`DetailHero.swift:73-80`) adds another ~40pt when MangaUpdates answers, and is
absent when it does not, so the travel is not even constant at one text size.

At AX1 and above, the navigation bar's copy fades in while the hero's title is
still on screen — which is **finding B2** ("The series page shows two titles at
once"), closed, reappearing at large type. Charter pattern 4: the comment
records a measurement, and the measurement was taken at one point in a range the
view itself branches on.

**Effort.** A function — derive it from the hero's measured height rather than
from a constant, or key it off the hero title's own visibility.
**Confidence.** Certain that the constant does not track the branch; **likely**
on the exact overlap point.

## F6. `Motion` cannot invalidate a view, so the two declarative call sites keep a stale answer

**What.** `Motion.isReduced` reads `UIAccessibility` directly. SwiftUI has no
dependency on it, so nothing redraws when the reader changes the setting.

**Where.** `Motion.swift:31`. The two declarative uses are
`SettingsRow.swift:140` and `Toast.swift:60`
(`.animation(Motion.reduced(…), value:)`).

**Why it matters.** For the eighteen imperative `Motion.run` sites this is fine
— the flag is read at the moment of the tap. For an `.animation` modifier the
value is captured at body-evaluation time, so a reader who turns Reduce Motion
on in Settings.app and returns to a screen that has not been rebuilt still gets
the animation. The doc comment (`Motion.swift:23-28`) argues for the direct
read on the grounds that half the call sites are in models and closures, which
is correct and a good trade — but it does not name this cost, and CLAUDE.md
asks comments to carry the evidence including what was given up.

**Effort.** A line at each of the two declarative sites (read
`@Environment(\.accessibilityReduceMotion)` there and pass it in — `reduced`
already takes an `isReduced` parameter for exactly this).
**Confidence.** Likely.

## F7. `tapTarget()` grows height only; the 44pt rule is two-dimensional

**What.** The modifier sets `minHeight` and no `minWidth`.

**Where.** `TapTarget.swift:15-18`. Applied at 13 sites.

**Why it matters.** Apple's audit measures both dimensions. A 30pt
`Metrics.headerPill` chip whose label is short — "All", "×", a single-digit
count — is still under 44pt wide after `.tapTarget()`, and the modifier's own
doc comment claims it "makes a control reach Apple's 44pt minimum". Finding C4
is closed on the strength of this modifier; the chips it names are wide, so it
probably did clear them, but the modifier does not do what it says and the next
narrow control to get it will silently not be fixed.

**Effort.** One line, plus a look at whether any current call site is narrow.
**Confidence.** Certain about the code. Whether any *current* site is affected
is **worth checking** — I did not measure the 13 sites.

## F8. `SearchClearButton` uses the 2.52:1 colour and a 30pt target, next to the file that exists to stop both

**What.** The clear button is drawn in `textQuaternary` at 30x30.

**Where.** `SearchClearButton.swift:27-31`. `Palette.textQuaternary` is the
colour finding C1 measured at **2.52:1**. The frame is 30x30 with a comment
claiming it is "something a thumb can hit", in a slice that also contains
`Metrics.tapTarget = 44` (`Metrics.swift:62`) and `TapTarget.swift`.

**Why it matters.** Four fields use it (`SearchView.swift:103`,
`TagPickerSheet.swift:113`, `SeedPickerSheet.swift:79`,
`InlineSearchField.swift:25`). It is the control a reader reaches for when a
long query is wrong, it is 14pt under the platform minimum, and it is the
lowest-contrast colour in the palette. Two closed findings (C1, C4) each step
around it.

**Effort.** Two lines.
**Confidence.** Certain.

## F9. `popToRoot` has no callers and its doc comment describes behaviour the app does not have

**What.** A private function, never called.

**Where.** `RootView.swift:195-212`. `grep -rn popToRoot MangaBaka
MangaBakaTests MangaBakaUITests` returns exactly one hit: the declaration.

**Why it matters.** Charter pattern 3 and 7 together. The comment reads
*"Tapping the current tab returns to its root"*, which is a statement about the
app that is not true: tapping the Library tab while on the schedule screen does
nothing. It is also 17 lines of carefully-maintained state-clearing
(`shelfPath`, `openShelf`, four sheet booleans) that will drift out of sync with
the real state list and be noticed by nobody. Periphery would not necessarily
catch it — a private func in a large type.

Note the closed dead-code sweep (H5) explicitly warns that half of what looks
dead here is a behavioural gap. This is that: the right resolution is probably
to wire it up, not delete it.

**Effort.** A line to wire (`.onChange(of: selection)` with the old value), or a
deletion.
**Confidence.** Certain.

## F10. `.id(titleRevision)` rebuilds the entire tab tree to change a title preference

**What.** The whole `TabView` is given an identity that changes when the title
preference changes.

**Where.** `RootView.swift:72`, `.id(titleRevision)`, set from
`TitleSection` via a binding (`RootView+Session.swift:86`).

**Why it matters.** `.id()` does not invalidate — it *replaces*. Every view
below it is torn down and rebuilt with fresh `@State`. The navigation paths
survive (they are `@State` on `RootView`, above the `.id`), and so do
`searchModel`/`mixModel`/`browseModel` for the same reason — but everything
constructed inline inside the tab closures does not: `DiscoverModel`
(`RootView.swift:93`) and `StackModel` (`RootView.swift:108`) are rebuilt,
along with every scroll position and every `@State` in every screen. So
changing "show original-language titles" in Settings silently resets the swipe
stack's position and re-runs the Discover feed.

The comment (`RootView.swift:65-68`) justifies the *version number* — which is a
reasonable call, titles are read in a hundred places — but not the *placement*.
Putting the `.id` on the leaf text would be a much smaller hammer; so would
making `DiscoverModel` and `StackModel` session-held like the other three.

**Effort.** A function.
**Confidence.** Likely — certain about what `.id` does, not measured on device.

## F11. The 0.08 ms launch number does not include the composition root

**What.** Finding F1 in `findings-todo.md` reasons from "our launch code took
0.08 ms". That measurement is of `didFinishLaunchingWithOptions`. This app has
no app delegate doing work; everything it constructs happens in
`AppServices.init`, which runs *after* that callback, when SwiftUI instantiates
the `@main` struct's stored properties.

**Where.** `MangaBakaApp.swift:10` (`private let services = AppServices()`),
`AppServices.swift:34-119`.

**Why it matters.** This is charter pattern 5 — a measurement whose unit is
wrong — sitting under the one open performance item. What `AppServices.init`
does synchronously on the main thread before the first frame:

- `URLCache.shared = URLCache(memory: 32 MB, disk: 256 MB)`
  (`AppServices.swift:152-157`). Constructing a `URLCache` with a disk capacity
  touches the cache directory.
- `AppDatabase.onDisk()` (`AppServices.swift:141-146`) — opens SQLite and, on a
  version change, runs GRDB migrations. **This is the only disk I/O in the
  critical path and it is unbounded: a migration is however long the migration
  is.**
- 17 object constructions, of which at least seven read `UserDefaults`
  (`ContentPreferencesStore`, `FormatPreferencesStore`, `BlockedTagsStore`,
  `SearchLensStore`, `RecentSearches`, `ReleaseReminders`, `OnboardingState`).
- `Bundle.main.infoDictionary` (`AppServices.swift:123`).

None of that is in the 0.08 ms. **Before anyone tries to unlink a framework,
put a signpost around `AppServices.init` and around `AppDatabase.onDisk()`** —
`Signposts.measure` already exists and is used on the detail page
(`SeriesDetailView.swift:240-241`). If the database open is 40 ms, that is 10%
of Apple's whole 400 ms budget and far cheaper to fix than dyld.

What could genuinely be deferred, on reading: the database is needed by
`SeriesRepository`, `ShelfStore`, `HistoryStore`, `LibrarySnapshot`,
`ReleaseScheduleService` and `TasteLedger` — but the first frame is Discover,
which needs only the repository. The `URLCache` swap is needed before the first
image request, not before the first frame. Nothing in this slice imports a
framework it does not use.

**Effort.** A line to measure; a redesign to defer.
**Confidence.** Certain that the 0.08 ms excludes `AppServices.init` (this is
how SwiftUI `App` initialisation is ordered). The sizes are unmeasured — that
is the point of the finding.

## F12. `AppServices` bundles nineteen values and `MangaBakaApp` immediately unbundles them

**What.** The composition root's stated purpose is to be one thing instead of
nineteen. It is then passed as nineteen arguments.

**Where.** `MangaBakaApp.swift:14-34` (nineteen labelled arguments),
`RootView.swift:12-34` (nineteen stored `let`s).

**Why it matters.** Adding a service is a three-file edit (`AppServices`,
`MangaBakaApp`, `RootView`) — the "shotgun surgery" the charter flags. And
`RootView` is a struct `View` with nineteen stored properties, so every parent
re-evaluation diffs nineteen references. The doc comment on `AppServices`
(`AppServices.swift:6-11`) says the list "had grown to the point where adding
anything to it meant fighting the lint"; that is still true, just one file
further along. Passing `services` itself is one argument and one property.

**Effort.** A file.
**Confidence.** Certain (it is a design observation, not a defect — no user-
visible failure).

## F13. `MangaBakaApp` carries a dead copy of `unsafelyUnwrappedFallback`, and its comment points at a literal that has moved

**What.** A private extension duplicating one in `AppServices`, with no use in
its own file.

**Where.** `MangaBakaApp.swift:39-49`. The comment reads *"The literal above is
a compile-time constant known to parse"* — there is no literal above it any
more; the URL moved to `AppServices.swift:129`, which has its own identical copy
at `AppServices.swift:192-202`.

**Why it matters.** Small, but it is precisely the "duplicated constants" and
"unreachable code that still looks alive" pair the charter names, and the
comment is now false. Both copies are `private`, so the compiler cannot tell
you.

**Effort.** A deletion.
**Confidence.** Certain.

## F14. `ScaledFont` computes line spacing from the unscaled size, so leading does not grow with Dynamic Type

**What.** The line-height multiplier is converted to points at init, using the
base size rather than the scaled one.

**Where.** `Typography.swift:28` —
`self.lineSpacing = lineHeight.map { ($0 - 1.2) * size }`, where `size` is the
init *parameter*, not the `@ScaledMetric` property (`Typography.swift:11`).

**Why it matters.** `typeBody()` asks for 14pt at line-height 1.55, i.e. 4.9pt
of extra leading. At AX5 the glyphs reach roughly 30pt and the leading is still
4.9pt — the ratio falls from 1.55 to about 1.36. The same applies to
`typeScreenTitle` (1.05), `typeStackCardTitle`, `typeDetailHeroTitle`,
`typeSubtitle`, `typeCardTitle` and `typeFootnote`. The effect is that the
longest text in the app — the synopsis — gets *tighter* leading exactly as the
reader who needs it asks for bigger type. The file's own doc comment
(`Typography.swift:6-9`) promises the ramp "keeps its proportions instead of
collapsing at the extremes"; the leading is the one proportion that does not.

`@ScaledMetric` cannot be read in `init`, which is presumably how this
happened; the multiplier has to be stored and the conversion done in `body`,
where the scaled `size` is available.

**Effort.** A function.
**Confidence.** Certain from reading; the visual severity is **likely**.

## F15. The Settings "checking" state shows the reader an implementation note, and it is false

**What.** A user-facing string that describes the design decision rather than
the state, and contradicts what the code then does.

**Where.** `AccountCard.swift:127` —
`"The field and buttons stay put and stay usable — this is not a modal wait."`
Four lines later, `AccountCard.swift:148` renders that state as
`field.opacity(0.5).disabled(true)`.

**Why it matters.** A reader who taps Save is told the field stays usable,
while looking at a field that is dimmed and disabled. It also reads as a note
the developer left in the wrong place — every other string in that switch
(`AccountCard.swift:119-137`) is written to the reader.

**Effort.** One line.
**Confidence.** Certain.

## F16. `validateToken` takes a token it never uses

**What.** The parameter is ignored; the client resolves credentials per request.

**Where.** `RootView.swift:268-277` — `func validateToken(_ token: String)`,
whose body never mentions `token`. Called from `SettingsView.swift:166` as
`validate(entry)`, where at `SettingsView.swift:53` (the on-appear check)
`entry` is the empty string.

**Why it matters.** It makes `check()` read as "validate what is in the field"
when it actually means "ask the server who the *stored* token belongs to". That
ordering is load-bearing — `save()` deliberately writes to the Keychain before
calling `check()` (`SettingsView.swift:142-151`), and the comment at
`RootView.swift:266-267` explains why. A parameter that says otherwise is the
kind of thing that gets "fixed" by reordering the two calls.

**Effort.** A line.
**Confidence.** Certain.

## F17. The gallery backdrop renders two 1000pt blurred images and rebuilds them on every frame of a swipe

**What.** Two `DetailBackdrop`s, cross-faded by a continuously-updating
fractional scroll position.

**Where.** `CoverGallery.swift:118-136` (`height: 1000`, two of them), fed by
`CoverGallery.swift:102-107` (`onScrollGeometryChange` writing `progress` on
every geometry change). Each `DetailBackdrop` is an `AsyncImage` with
`.scaleEffect(1.6)`, `.blur(radius: 72)`, `.saturation(1.7)` and a four-stop
gradient overlay (`DetailBackdrop.swift:29-50`).

**Why it matters.** `Glass.swift:12-15` states the project's own rule: *"Nothing
that scrolls is glass — that is a performance decision as much as an aesthetic
one, since live blur under a moving feed is expensive on both GPU and battery."*
This is two 72pt blurs at 1000pt tall, both live, both animating their opacity,
under a finger. It is the same cost the rule exists to avoid, on the one screen
where the reader is dragging continuously. The design intent (a wash that
follows the thumb rather than snapping) is good and worth keeping; rendering it
as two full-size live blurs is the expensive way to get it.

The default `DetailBackdrop` height is 420 with a comment saying the taller it
is the more the blur costs (`DetailBackdrop.swift:14-16`). This call site passes
1000 and does it twice.

**Effort.** A function — render both washes once into a small offscreen and
cross-fade those, or cap the height.
**Confidence.** Likely. Not profiled; the mechanism is certain from the code and
from the project's own stated rule.

## F18. Nothing in the app is marked `accessibilityIgnoresInvertColors`, so Smart Invert turns every cover into a negative

**What.** Zero uses app-wide.

**Where.** `grep -rn accessibilityIgnoresInvertColors MangaBaka/` — no hits. The
three places artwork is drawn: `CoverImage.swift:61-78`,
`DetailBackdrop.swift:29-33`, `CoverGallery.swift:205-218`.

**Why it matters.** Smart Invert exists so a reader can invert the UI without
inverting photographs, and the way a view opts out is this modifier. An app
whose subject is cover art shows every cover as a photographic negative to a
reader using it. Note this is **independent of the dark-mode decision** — it
would be the right fix whether or not the palette ever changes, and it is three
lines.

**Effort.** Three lines.
**Confidence.** Likely — certain that nothing opts out; the exact rendering under
Smart Invert is not something I could verify without a device.

## F19. Bold Text is overridden everywhere by construction

**What.** Every piece of text in the app sets an explicit weight through
`.font(.system(size:weight:))`, which supersedes the Bold Text accessibility
setting.

**Where.** `Typography.swift:33`. Every one of the 22 named ramp styles passes
a `weight`. `@Environment(\.legibilityWeight)` is read nowhere in the app
(grep: no hits).

**Why it matters.** Bold Text is a low-vision setting with a large user base,
and it is one of the few that costs a designer almost nothing — `.regular`
becomes `.medium`, `.semibold` becomes `.bold`, the ramp keeps its shape. As
written the setting does nothing anywhere in the app, silently.

**Effort.** A function, in `ScaledFont`.
**Confidence.** Certain.

## F20. Settings is the only pushed scrolling screen with neither a navigation title nor a scroll-edge style

**What.** Four pushed screens set `.scrollEdgeEffectStyle(.hard, for: .top)`.
Settings sets neither that nor `.navigationTitle`.

**Where.** `SettingsView.swift:29-55` — a `ScrollView` drawing its own 36pt
"Settings" (line 32-33) with `.padding(.top, Metrics.scrollTopInset)` (line 47)
and no toolbar modifiers. Compare `SeriesDetailView.swift:100`,
`WrappedView.swift:62`, `ShelfDetailView.swift:97`,
`ReadingInsightsView.swift:54`.

**Why it matters.** Settings still has a bar (it is a `navigationDestination`)
so it gets the *automatic* edge rather than none — this is not the B1 defect
returning. But it renders a different top edge to every sibling screen reached
from the same tab, and it has no accessible screen name and no back-button
label for anything pushed from it. `BlockedTagsSection.swift:149` sets a
`navigationTitle` for its own sheet, so the pattern is known in this very
directory.

**Effort.** Two lines.
**Confidence.** Certain about the absence; **likely** about the visual
difference, which I could not render.

## F21. `SwitchIndicator` is a hand-drawn `UISwitch`, and the root cause its comment asks for is probably visible in the call site

**What.** A picture of a switch, at hard-coded UIKit metrics, because a real
`Toggle` "only ever responded to a drag across the switch, never to an ordinary
tap".

**Where.** `SettingsRow.swift:108-143` (the drawing, 51/31/27 hard-coded at
lines 124-126), and the note at `SettingsView.swift:76-83` ending *"Worth
revisiting if anyone finds the root cause."*

**The root cause, offered.** At `SettingsView.swift:114-128` the row is a
`Button` whose *label* contains the control. A `Button`'s label is not an
interactive region — SwiftUI installs the button's own tap gesture over the
whole label and it wins every tap inside it. A drag is not the button's
gesture, so a drag falls through to the `Toggle` underneath. That is exactly the
reported symptom: drag works at the coordinate where the tap had just failed.
The fix is not a second gesture arbitration attempt — it is not nesting the
control inside a `Button` at all (`Toggle(isOn:)` with a custom
`toggleStyle`, or a row-level `.onTapGesture` rather than a `Button`).

**Why it matters.** Two costs beyond the duplication. (a) 51x31/27 is iOS's
metric *today*; iOS 26 restyled switches under Liquid Glass, and a drawn
control that is "nearly the system's" is the exact failure mode the comment at
`SettingsRow.swift:110-117` already argues against — it just argues it about
size and not about time. (b) A real `Toggle` brings `.isToggle` traits,
switch-specific VoiceOver gestures and Increase Contrast adaptation for free;
the drawing gets `.accessibilityHidden(true)` (`SettingsRow.swift:141`) and the
row reconstructs a label and value by hand (`SettingsView.swift:135-137`).

**Effort.** A function to try; a file if it cascades.
**Confidence.** Likely on the root cause — it matches the symptom precisely and
is a known SwiftUI behaviour, but I could not run it. Certain on (a) and (b).

## F22. Three comments still describe a 126pt hero cover that is 150pt

**What.** Stale measurements in comments.

**Where.** `DetailHero.swift:28` (*"The cover is a fixed 126pt"*),
`DetailHero.swift:58-61` (*"Bottom-aligning a 126pt cover"*),
`CoverGallery.swift:6` (*"the page shows it at 126pt"*). The value is
`Metrics.coverDetailHeroWidth = 150` (`Metrics.swift:88`), and that constant's
own comment records the change from 126 with its reason.

**Why it matters.** CLAUDE.md forbids deleting a comment that records a
measurement — the corollary is that a measurement which has been superseded has
to be updated, or the next person derives from a number that is two revisions
old. `DetailHero.swift:28-32` in particular reasons from 126 to justify the
accessibility-size stack, and the reasoning is now based on the wrong width.

**Effort.** Three lines.
**Confidence.** Certain.

## F23. Two smaller ones, grouped

- **`Metrics.swift:48-55`** — the doc comment *"The one CTA height. There were
  two … A second height with no second meaning is how a design system starts
  drifting"* has become detached from `ctaPrimary` and now sits above
  `shapeBar`, welded to `shapeBar`'s own comment. It is also false as written:
  `ctaSecondary` (line 64) exists and has eleven call sites. One line to
  re-attach, one sentence to correct. Certain.
- **`CoverGallery.swift:10, 141`** — `@State private var selection` is set once
  in `init` and never again; it is read only as the fallback when
  `scrolledIndex` is nil (`scrollPosition(id:)` does set it nil during some
  transitions). So a nil moment mid-gallery shows the caption for the page the
  reader *opened at*, not the one they are on. One line. Likely.

---

# Part 2 — The three questions

## Q1 — Hand-rolling what the platform provides

Taken one at a time. The short version: **two of the five are the system's job
and should go back to it, two are legitimately hand-built, and one is
half-right.**

### `ScrollEdge.swift` — the system provides it; take it

iOS 26 gives this to any scroll view under a navigation bar, and **this project
already uses the API** — `.scrollEdgeEffectStyle(.hard, for: .top)` appears on
four pushed screens. The four tab roots do not get it only because they print
`typeScreenTitle()` inside the `ScrollView` and have no bar.

*What taking the system's version costs the mockup.* Less than the
`apple-idiomatic` README implies, and this is where I disagree with it. That
document frames the choice as "real navigation bars on the four tab roots, and
you lose a title that moves" — presenting a `.navigationTitle(.large)` as the
only door. It is not. A `ToolbarItem(placement: .principal)`, or iOS 26's
`.safeAreaBar(edge: .top)`, hosts **arbitrary content** in the bar's own space
and participates in the scroll edge effect. The mockup's 36pt title at -1.2
tracking and 1.05 line height can go in there verbatim. The README's own
framing — *"the free upgrades come from the containers"* — is right, and it then
under-sells it: the container does not dictate its contents.

So the honest cost is not the type ramp. It is:

- **The title collapses on scroll** unless you suppress it, which is a behaviour
  the mockup does not draw either way. The README concedes this.
- **The bar reserves its height**, so `Metrics.scrollTopInset = 24` and the flat
  `.padding(.top)` on nine screens (grep: nine call sites) would need revisiting
  — one number, nine files.
- Nothing else. The floating capsule tab bar, the search circle, the ground, the
  accent, the swipe stack are all untouched by this; they live in `TabView` and
  `TabRole.search`, which the project already takes from the system
  (`RootView.swift:134-138, 178` — and the comment there makes exactly the right
  argument).

*What it buys*, beyond deleting 91 lines: the edge effect adapting to Liquid
Glass automatically on the next OS, status-bar-tap-to-scroll-to-top (absent
today), a screen name for VoiceOver on four screens that have none, and the
bug in F4 ceasing to exist.

*Is the hand-built version correct?* Mostly, on the device it was measured on.
The gradient stop maths (`ScrollEdge.swift:65-73`) is right and the comment
explaining why the stops are uneven is correct and non-obvious. The
`GeometryReader`-reports-zero comment (lines 57-62) is a real measured finding
worth keeping regardless of what happens to the file. The inset lookup is not
correct — see **F4**.

**Verdict: replace it.** This is the highest-value item in the slice after F1.

### `DetailBarTitle.swift` — no system equivalent; keep it, fix the constant

The system fades a bar title in as a *large title* leaves. The detail hero is
not a large title — it is a cover, a schedule block, a kicker, a tappable title
and a byline — so there is nothing to inherit. The implementation is also
careful in a way worth naming: it keeps `.navigationTitle` for the back button
and VoiceOver and renders the *visible* copy as a principal item
(`DetailBarTitle.swift:35-46`), with `.accessibilityHidden` tracking visibility
so VoiceOver does not read the title twice. That is a better answer than either
obvious alternative.

**Verdict: keep.** One defect — **F5**, the 150pt constant is fitted to one
text size and the hero moves at accessibility sizes.

### `SearchClearButton.swift` — the system provides it on the Search tab; keep it for the sheets

`.searchable` brings a clear button and a Cancel button for free, and on iOS 26
it is specifically designed to pair with `TabRole.search` — which this app
already uses (`RootView.swift:138`). The Search tab is the strongest candidate
in the app for `.searchable`: it would delete the hand-built field, the clear
button, and probably part of the idle/results switching, and it is the one
screen where the system's arrangement *is* the mockup's arrangement (a search
circle that expands into a field).

The two sheets (`TagPickerSheet`, `SeedPickerSheet`) and `InlineSearchField`
are filtering a list that is already on screen inside a sheet; `.searchable`
there would put a bar where the sheet's own title is, which is a real cost.
Keep the component for those.

*Is the hand-built version correct?* No — **F8**. Wrong colour (the 2.52:1 one),
30pt target under a 44pt rule, in a slice that contains both the constant and
the modifier that exist to prevent each.

**Verdict: split.** Take `.searchable` on the Search tab; keep and fix the
component for the three sheet fields.

### `TapTarget.swift` — the system provides it only inside `List`/`Form`, which this design cannot use; keep it

A `Form` row is 44pt by default, and that is genuinely free. But
`Metrics.headerPill = 30` is the mockup's number and a `Form` cannot draw a 30pt
chip — the whole point of the modifier is to keep the *drawn* size and grow the
*touch* area, which no container does for you. The comment at
`TapTarget.swift:6-12` states this correctly and the distinction between
`Metrics.tapTarget` (a platform rule) and `Metrics.headerPill` (a mockup number)
at `Metrics.swift:57-62` is exactly right.

**Verdict: keep.** One defect — **F7**, it grows height only.

### `Motion.swift` — the system does *not* do this; keep it

`withAnimation` does not consult Reduce Motion. SwiftUI's only offer is
`@Environment(\.accessibilityReduceMotion)`, which is view-only, and the
argument at `Motion.swift:23-28` for reading `UIAccessibility` instead — half
the call sites are in models and closures, threading the environment through
them all is fifteen chances to forget — is correct and I would make the same
call. `reduced` returning `nil` rather than a shorter duration
(`Motion.swift:34-36`) is also the right reading of what the setting asks for.

*Is it correct?* Two gaps: **F6** (no invalidation, which affects the two
declarative call sites) and **F3** (the gallery's `scrollTransition` — the
loudest animation in the app, named in this file's own doc comment as fixed —
never routes through it).

**Verdict: keep.** F3 is the one to act on.

## Q2 — The composition root

**What runs at launch, in order.**

1. `main` → UIKit bootstrap → the app delegate shim's
   `didFinishLaunchingWithOptions`. **This is where the 0.08 ms was measured.**
2. SwiftUI instantiates `MangaBakaApp`, which runs its stored property
   initialiser — `AppServices()` (`MangaBakaApp.swift:10`). Synchronous, main
   thread, before any frame:
   - `enlargeImageCache()` — allocates a 32 MB/256 MB `URLCache`
     (`AppServices.swift:152-157`).
   - `makeClient()` — `Bundle.main.infoDictionary`, a `URL` parse
     (`AppServices.swift:122-134`).
   - `makeDatabase()` — **`AppDatabase.onDisk()`: SQLite open plus any pending
     GRDB migration** (`AppServices.swift:141-146`). Unbounded.
   - Seventeen object constructions, at least seven of which read
     `UserDefaults` on init.
   - `applyStoredFilters` spawns an unstructured `Task`
     (`AppServices.swift:179-187`) — five `await`s including
     `library.profileID()`, which is a Keychain read and possibly a network
     call. Off the critical path, correctly.
3. `RootView.body` → `TabView` builds only the selected tab (Discover).
4. `.task { startSession() }` (`RootView.swift:73`) — the rising feed if
   onboarding is incomplete, then `refreshReminders()`
   (`RootView+Session.swift:111-119`). `refreshReminders` walks the whole
   library, the schedule and the calendar; it early-returns on
   `reminders.isEnabled` (`RootView+Session.swift:128`), so for a reader with
   reminders off it is nearly free, and for one with them on it is three
   awaits over a 939-entry library on **every** launch.
5. `fullScreenCover(isPresented: .constant(!onboarding.hasCompleted))`
   (`RootView.swift:74`) — evaluated on every launch.

**What could be deferred.** Answering the question as posed — not "run our code
faster" but "what are we constructing that the first frame does not need":

- **The database.** The first frame is Discover, which needs `repository`. The
  other six database consumers (`shelf`, `history`, `librarySnapshot`,
  `schedule`, `TasteLedger`, and `SeriesRepository`'s own cache) are not on
  screen. Making `AppDatabase` lazy behind the repository is the largest single
  candidate, and it is also the only synchronous disk I/O in the path.
- **The `URLCache` swap.** Needed before the first image request, not before
  the first frame.
- **`ReleaseReminders`, `ReleaseScheduleService`, `ReleaseCalendar`,
  `CharacterService`, `CatalogueService`, `BlockedTagsStore`,
  `SearchLensStore`, `RecentSearches`** — none is reachable from Discover.
  Eight of nineteen.

**But: measure first, and the existing measurement does not cover any of this.**
See **F11**. `Signposts.measure` is already in the codebase
(`SeriesDetailView.swift:240-241`); wrapping `AppServices.init` and
`AppDatabase.onDisk()` is a two-line change that would tell you whether this is
a 5 ms question or a 60 ms one. Doing the deferral work against an unmeasured
guess is charter pattern 5 for the second time on the same finding.

**Framework linking.** Nothing in this slice imports anything unnecessary —
`SwiftUI` throughout, `UIKit` in three files that genuinely need it
(`Motion.swift` for `UIAccessibility`, `DetailHero.swift` for `UIPasteboard`
and haptics, `CoverImage.swift` for `UIImage`), and `Foundation`. UIKit is
linked by SwiftUI regardless. The 598-634 ms is dyld plus SwiftUI plus GRDB,
and none of it is reachable from this slice.

## Q3 — What the hard-coded dark palette costs

Not an argument to change it. An enumeration, with what I could verify.

**Verified by grep across the whole app (excluding `MangaBaka/Apple/`): zero
uses of `colorScheme`, `colorSchemeContrast`, `accessibilityReduceTransparency`,
`accessibilityDifferentiateWithoutColor`, `accessibilityIgnoresInvertColors`,
`legibilityWeight`, or any semantic colour (`Color.primary`, `Color(.label)`,
`UIColor.*`). Every colour in the app is one of the 26 literals in
`Palette.swift`.**

### Light mode — gone, and more thoroughly than the branch README says

`.preferredColorScheme(.dark)` appears in **eight** places, not one:
`RootView.swift:192`, `CoverGallery.swift:63`, `OnboardingView.swift:37`,
`LibraryEditSheet.swift:66`, `TagPickerSheet.swift:62`,
`BlockedTagsSection.swift:157`, `VolumesSection.swift:120`,
`AlternativeTitles.swift:99`. (The extra seven are not redundant — a
`fullScreenCover` and a `sheet` are separate presentations — but it does mean
"turn light mode on" is an eight-file change before you touch a single colour.)

The palette itself is the real obstacle and it is worse than "invert the
values": five surface tokens are `Color.white` at alpha 0.035-0.13
(`Palette.swift:19-27`), which is a *technique*, not a colour. White at 4.5%
over near-black is a subtle raised card; over white it is invisible. Every card,
chip, field and pill in the app would need a different mechanism, not a
different number. The four text tiers are the same story
(`Palette.swift:34-41`).

**Cost: the dark design is not a theme, it is an architecture.** That is a real
decision with a real payoff (it is why the surfaces are consistent), and it
should be understood as one-way.

### Increase Contrast — the setting a reader would reach for, and it does nothing

This is the sharpest loss, because of what it interacts with. `textQuaternary`
measures **2.52:1** (finding C1) and is used at 10.5-12.5pt in 26 places. A
reader who finds that text hard to read will turn Increase Contrast on. With
semantic colours, iOS would darken the ground and lighten the text
automatically. Here, `Palette.textQuaternary` is
`Color(hex: 0xEBEBF5).opacity(0.32)` and stays 0.32 forever.

So C1 — which is marked NEEDS A DECISION because raising the alpha changes the
mockup's look — has a resolution that costs the mockup **nothing**: read
`@Environment(\.colorSchemeContrast)` and raise the four text alphas only when
the reader has asked for it. The mockup's look is preserved at the default
setting, which is the setting the mockup was drawn at. That is worth saying
plainly because the decision is currently framed as all-or-nothing.

### Reduce Transparency — half honoured, and the wrong half

- **The six glass surfaces are fine.** `Glass.floating` calls
  `.glassEffect(.regular, in:)` (`Glass.swift:21`), which is real system glass
  and honours Reduce Transparency itself. The decision recorded at
  `Glass.swift:5-9` — take the system material rather than the spec's CSS blur
  — is why, and it was the right call.
- **Every card in the app does not.** The five `Color.white.opacity(...)`
  surface tokens are *simulated* translucency: they look layered but they are
  flat composited colours. Reduce Transparency changes nothing about them. A
  reader turning it on is asking for solid, higher-contrast surfaces and gets
  the same 4.5%-white card.

### Smart Invert — every cover becomes a negative

See **F18**. Nothing is marked `accessibilityIgnoresInvertColors`. This is the
largest loss on the list for an app about artwork, and it is the one fix that is
**entirely independent of the palette decision** — three lines, no design
change, do it regardless.

### Classic Invert

The ground becomes near-white, text near-black, the `#F87966` accent becomes a
teal. Readable but unrecognisable. Nothing to do about this in any design.

### Bold Text

See **F19**. Overridden everywhere by `.font(.system(size:weight:))`. Also
independent of the dark decision, and also cheap.

### Differentiate Without Color

Unverified — I did not audit every colour-coded surface. But the setting is read
nowhere, and the app does encode meaning in colour in at least three places I
saw: the account dot (`AccountCard.swift:98-105`), the library state colours
(`Palette.paused` and siblings), and `Palette.stale` vs `Palette.accent`, where
the *distinction between two similar oranges* carries the meaning
(`Palette.swift:70-76`). The comment there is careful about the semantics and
does not consider a reader who cannot separate them. **Worth checking.**

### What is *not* lost

Worth stating so the ledger is honest. `.preferredColorScheme(.dark)` costs
nothing in Dynamic Type, VoiceOver, Reduce Motion, Increase Button Shapes,
Larger Text, or Full Keyboard Access. The system tab bar, the glass and the
navigation bars still adapt themselves. The losses are exactly: light mode,
Increase Contrast, Reduce Transparency on custom surfaces, Smart Invert, and —
separately from the colour decision but from the same "we draw it ourselves"
instinct — Bold Text.

---

# Part 3 — What this slice does well

With the same evidence standard.

**The comments record measurements with their dates and methods, and they are
load-bearing.** `Typography.swift:61-81` does not say "use subheadline" — it
prints the `UIFontMetrics` table for four anchors across every content size
category, with the base size stated, and then names the cost of the choice
("a 10.5pt meta line reaches 30pt rather than 39pt"). That is a measurement a
successor can reproduce and disagree with. `ScrollEdge.swift:57-62` records a
negative result — a `GeometryReader` inside a scroll view's overlay reports
`top == 0`, measured, and the wrong output it produced ("a 14pt band above the
clock"). `Metrics.swift:72-78` records why an unbuilt feature is not a feature:
the mockup's `density` prop sits in the designer's own editor panel next to
`glassBlur`. Several of the findings above were findable *only* because of these
comments.

**The reasons for rejected alternatives are written down, with the failure.**
`CoverImage.swift:88-96` explains why covers are framed at a fixed 2:3 and not
at the API's per-scan ratio — "a row of covers came out visibly ragged" — and
then `CoverGallery.swift:189-192` explains why the *opposite* choice is right
one screen away, and cites the first comment by name. Two decisions that look
contradictory, each justified, each aware of the other. That is unusual.

**`StateAction` puts the disabled treatment where it cannot be forgotten.**
`StateAction.swift:25-32`: call sites used to reach for `.opacity(0.5)`, which
dims foreground and background together and produced the 2.27:1 Save button
Apple's audit measured. Reading `@Environment(\.isEnabled)` inside the component
(line 32) means every caller gets it right by default. That is fixing a
duplication at its source rather than documenting the hazard — which is the
thing CLAUDE.md says two agents got wrong.

**`SessionModels` records the bug its own existence prevents.**
`SessionModels.swift:19-24`: `library` "used to be a computed property, so every
body pass that reached for it built a fresh one — and a fresh one loads,
registers itself for page updates, and replaces whichever model was listening
before." That is a class of bug that is invisible in a diff and obvious in a
comment.

**`LibraryControlModel.load` states the wrong answer it used to give.**
`LibraryControl.swift:32-42`: it asked for one page of 500 and treated it as the
whole library, so on 937 entries it offered "Add to library" for series already
being read, and the write then 409'd "having told them something false first."
The fix and the rate-limit argument are in the same comment.

**The accessibility work that is done is done properly, not performatively.**
`CoverCard` collapses cover, title and meta into one element with a composed
label (`CoverImage.swift:159-170`) rather than leaving VoiceOver to read three
fragments. `DetailBarTitle.swift:44-46` hides the bar copy from VoiceOver while
it is invisible so the title is not read twice. `SettingsView.swift:130-137`
explains why the locked row is *not* `.disabled` — SwiftUI fades a disabled
`Button`'s whole label, so a deliberate rule read as a broken control — and
supplies the traits by hand instead. `SwitchIndicator` is
`.accessibilityHidden(true)` with the row carrying the value
(`SettingsRow.swift:141`, `SettingsView.swift:135-137`).

**`Series.filling(gapsFrom:)` guards the id before merging.**
`Series.swift:193` — "merging two different series would be a silent data
corruption, so a mismatch returns this one untouched." The failure mode is named
and the guard is there. (F1 is a call-site bug, not a flaw in this.)

**No force-unwraps reachable from real input, still true in this slice.** The
two `unsafelyUnwrappedFallback` extensions (`AppServices.swift:192-202`,
`MangaBakaApp.swift:39-49`) exist specifically so a hard-coded literal does not
need `!`, and both `preconditionFailure` rather than crash silently.
`AppServices.makeDatabase` (`AppServices.swift:141-146`) falls back to an
in-memory database rather than crashing on a corrupt cache. I read every `!` in
the 34 files: none is on a value the network or the reader can influence.
(F13 is about the duplicate, not the technique.)
