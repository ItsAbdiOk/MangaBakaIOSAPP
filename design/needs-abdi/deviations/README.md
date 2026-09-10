# What I changed from the mockup

Seven deviations. Each one is here because following the mockup would have
produced something broken, dishonest, or impossible — not because it was easier.
Screenshots are paired: `NN-mockup.png` is the design, `NN-app.png` is what
shipped.

Two of these are not "I did it differently". They are **the mockup was wrong**.

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

**Mockup:** three tag chips.

**Shipped:** grouped by `tags_v2`'s own taxonomy, weighted by how central each
tag is, spoilers held back per group as one "4 spoilers" chip, your own
interests floated to the front.

**Why:** a real series carries **146 tags across seventeen groups**. Three chips
is not a simplification of that, it is a different screen. Grouping all
seventeen fixed the wall and rebuilt it taller, so four groups show and the
other thirteen sit behind one control.

---

## 04 — Covers framed at a fixed 2:3

**Mockup:** each cover sized from its own reported dimensions.

**Why:** one 20-item API row returns **14 distinct aspect ratios**, spanning
0.63 to 0.88. Rows came out visibly ragged with titles on different baselines.
The full-screen gallery is the exception — it uses each cover's true ratio,
because there is one cover on screen and cropping it would show you less of the
thing you tapped to see.

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
