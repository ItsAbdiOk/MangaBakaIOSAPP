# Library

**Status:** built, working, and in no mockup at all. It is where a reader's own
data lives, and it is the screen they will open most often after a month.

## What it holds today

- Every saved series, with a **reading state**: reading, rereading, paused,
  completed, dropped, planning
- A **rating** out of 5
- Progress — chapter/volume where the API gives it
- An edit sheet for changing any of the above
- A **"Pick back up"** row — paused and reading series surfaced for return
- The **gear that reaches Settings** (there is nowhere else)

## What it does not have, and needs a decision as well as a design

- **A search field.** Past ~200 entries, scrolling is the only way to find
  anything. See question 8.
- **Sorting or grouping.** Today it is one list.
- Any sense of *how much* is in each state — no counts, no shape.

## The hard part

The library pages at 500 entries per request. A reader with 1,200 series is
real, and an earlier bug in this app treated one page as the whole library — it
offered "Add to library" for a series already saved. So the design has to
account for a list that is genuinely long, and for the moment before it has all
loaded.

## What to hand back

The list, the state filter, an entry mid-edit, the empty library, and whatever
you propose for finding one series among a thousand.
