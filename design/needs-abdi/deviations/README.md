# What I changed from the mockup

Seven deviations. Each one is here because following the mockup would have
produced something broken, dishonest, or impossible — not because it was easier.
Screenshots are paired: `NN-mockup.png` is the design, `NN-app.png` is what
shipped.

Two of these are not "I did it differently". They are **the mockup was wrong**.
One of them — number 4 — turned out to be **me** being wrong, and is corrected
below rather than deleted.

**Which shots exist.** 01, 02 and 03 are true pairs, mockup and app. 05, 06 and
07 are app-only: they are behaviour and spacing, and there is nothing in a static
mockup to contrast them with. 04 is app-only because there is no disagreement to
show — see below.

The mockup's series-detail panel only renders once its `detailOpen` state is set,
which a static render never reaches, so shots 02 and 03 were taken from a scratch
copy of the mockup with that state flipped. The repo's mockup files were not
touched.

---

## 01 — Tab bar: Apple's, not a drawing of the mockup's

**Mockup:** a floating capsule of four tabs plus a detached search circle,
hand-drawn.

**Shipped:** the system iOS 26 tab bar, with `TabRole.search` detaching search.

**Why:** on iOS 26 the system tab bar *is* a floating glass capsule — the
mockup's arrangement is what the platform already produces. Drawing it by hand
cost three things the system gives free: the selection indicator that sizes to
its label and slides under a dragging finger, the scroll-away minimise
behaviour, and real Liquid Glass specular response. `AppTabBar.swift` is deleted.

---

## 02 — "In collections" → Editions  *(the mockup was wrong)*

**Mockup:** a row on the series page showing other series' covers.

**Shipped:** an **Editions** section — publisher, language, volume count,
format, and whether the release is licensed.

**Why:** `/v1/series/{id}/collections` returns **editions of the series you
asked about**. Every row carries the same `series_id`, checked live on
2026-09-10. The mockup's row was populated from a hardcoded list of unrelated
series, so it was placeholder content shaped like a feature. What the endpoint
actually answers — *can I buy this in my language, and how far along is it?* —
is a better question and one nothing else in the app answers.

---

## 03 — Tags grouped, not listed  *(the mockup was wrong about scale)*

**Mockup:** four tag chips (Murim, Fantasy, Swordsman, Training), with no heading
above them — they follow the synopsis directly.

**Shipped:** grouped by `tags_v2`'s own taxonomy, weighted by how central each
tag is, spoilers held back per group as one "4 spoilers" chip, your own
interests floated to the front.

**Why:** a real series carries **146 tags across seventeen groups**. Three chips
is not a simplification of that, it is a different screen. Grouping all
seventeen fixed the wall and rebuilt it taller, so four groups show and the
other thirteen sit behind one control.

---

## 04 — Covers framed at a fixed 2:3  *(not actually a deviation — correction)*

**I had this wrong, and the correction matters because you are handing these
notes to a designer.**

I recorded on 2026-09-09 that the mockup sized each cover from its own reported
dimensions and that the app departed from it. It does not. Every cover box in
every mockup is hardcoded `aspect-ratio:2/3` — 16 occurrences in
`NewBakaManga.html`, 12 in the older `BakaManga.html`, no other value anywhere.
The design always framed covers at 2:3 and the app agrees with it.

What is still true is the reason the code does it deliberately: one 20-item API
row returns **14 distinct aspect ratios**, spanning 0.63 to 0.88. Left to their
own sizes, rows come out ragged with titles on different baselines. So the
framing is measured and load-bearing — it is just not a disagreement with the
design, and the fidelity checklist has been corrected too.

The full-screen gallery is the one place that uses each cover's true ratio,
because there is one cover on screen and cropping it would show you less of the
thing you tapped to see.

There is no `04-mockup-covers.png`, because there is nothing to contrast.

---

## 05 — Tab-bar clearance is 96pt, not 24

24pt cannot clear an 80pt floating bar. The last row of every scrolling screen
was unreachable. A test now asserts all six screens reserve it.

---

## 06 — The peeking stack card shows no text

Its title rendered at half opacity directly through the front card's title.

---

## 07 — Settings switches are drawn, not real `Toggle`s

The system control only ever responded to a drag, never a tap, verified
repeatedly on device. **This is the weakest of the seven** — a workaround for
behaviour I never fully explained. See question 7.

---

## Smaller ones, no screenshots

- Stack tag chips left-align where the mockup centres — `FlowLayout` caps an
  over-wide item, and a long tag used to hang off the screen edge.
- The stack's left-hand neighbour is absent until the first card is dealt with,
  because there genuinely is no previous card yet.
- Discover's stack shortcut says what it does rather than "N left in today's
  stack", which Discover cannot know without duplicating the stack.
- The accent is `#F87966`, the sRGB of the mockup's `oklch(0.72 0.16 30)`.
