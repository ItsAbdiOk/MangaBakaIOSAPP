# Empty, error, stale and loading states

**Status:** one generic layout — a symbol, a headline, a body line, a retry
button — reused for six different causes. It works and it is honest. It has
never been designed, and it is the family a reader sees on their worst day.

## The six causes, and what the app already knows about each

| Cause | Symbol today | Headline today | Stale content kept? |
|---|---|---|---|
| Offline | `wifi.slash` | "You're offline" | Yes |
| Rate limited | `hourglass` | "Too many requests, briefly" | Yes |
| Server error | `exclamationmark.triangle` | "MangaBaka had a problem" | Yes |
| Needs an account (401/403) | `person.crop.circle.badge.plus` | — | Yes |
| Decode failure | `questionmark.circle` | "Something went wrong" | **No** |
| Transport failure | `questionmark.circle` | "Something went wrong" | **No** |

Two of these carry real detail the design should use:

- **Rate limited** knows `Retry-After` when the server sends it, so it can say
  *when*, not just *that*. It is also deliberately worded never to blame the
  reader: the limit is **per IP and shared with everyone behind the same
  address**, so it can be caused entirely by a stranger on the same wifi.
- **Needs an account** is the only one where the fix is a screen we own — it
  should route to Settings, not offer a retry that will fail identically.

**Why decode/transport drop stale content:** a decode failure means the API's
shape changed, so the copy we are holding may now mislead. Offline says nothing
about accuracy, so we keep showing what we have.

## The state nobody has designed at all

**Stale-but-showing.** The app frequently has good content *and* a failed
refresh. Today that is silent — the reader sees yesterday's covers and no
indication they are yesterday's. The mockup anticipated this with a "Cached 2m"
pill that was never built (`Metrics.gutterStatus`, still unused). This is the
most valuable thing in this brief.

## Empties that are not errors

- Library with nothing saved
- Stack exhausted for the day
- Search with no results for a query
- Search idle, before anything is typed
- Mix with no seeds chosen
- Schedule with nothing worth scheduling (only *reading*, *rereading* and
  *paused* series get predictions — by design)

Each of these is a different feeling. "You have not saved anything yet" is an
invitation; "no results" is a dead end that should offer a way out.

## Loading

Covers already have a BlurHash placeholder, so image loading is solved. What is
not: first-load of a whole screen, and pagination (see below).

## What to hand back

One layout that carries all six causes, the stale-but-showing treatment, and at
least three of the empties — enough to show the family resemblance.
