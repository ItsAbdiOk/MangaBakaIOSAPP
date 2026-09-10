# Decisions on the new boards — 2026-09-10

Abdi's calls on what the boards left open or contradicted.

| # | Question | Decision |
|---|---|---|
| 1 | Search idle designed twice | **Option B — Brief 05's three sections**: Your lenses (Edit + live counts) / Presets / Recent |
| 2 | Stack exhausted says "dealt tomorrow morning" but a reset exists | **Offer the reset on the exhausted card.** Keep tomorrow as the default expectation |
| 3 | App icon | **The fan — three offset cards.** Not the board's own pick |
| 4 | First run screen 1 with no network | **Ship a fallback set of covers** (the board's recommendation) |
| 5 | Schedule empty-state wording | **Claude drafts it**, flagged for Abdi to correct |

## What each decision costs, stated plainly

**1. Live lens counts.** Option B shows a live result count beside each lens. That is
one count query per lens, every time Search's idle state appears — the screen a
reader lands on constantly. The board itself offers the fallback: drop the counts
and show each lens's filter summary instead. Built with counts, cached per session
and fetched only when the idle state is actually shown. **If it turns out to cost
too many requests against a shared per-IP rate limit, this is the first thing to
take off, and Abdi should be told rather than it being changed silently.**

**3. The fan at 40px.** Abdi picked it over the board's recommendation, which is his
call to make and the fan does tell the better story — the stack is the app's one
original mechanic. The board's warning stands and is not an argument against the
choice, only something to design around: at Spotlight size the two rear cards
collapse into a shoulder. The mark needs drawing so that the front card alone
still reads when the other two stop being separable.

**4. Fallback covers.** Means shipping a small set of cover images in the app
bundle. They will age — a shipped cover for a series that later changes its art is
a stale asset nobody thinks to update. Worth it against a first launch that opens
on an empty grid, which is the worst possible first impression.
