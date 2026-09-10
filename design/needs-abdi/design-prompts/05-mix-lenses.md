# Mix: save-as-a-lens, and the two missing filter sections

**Status:** Mix itself is built and matches its mockup. Three things around it
were drawn or implied and never built, all because they need design rather than
code.

## 1. Save as a lens

A **lens** is a saved search: a query plus filters. The app ships several as
presets and Search can list them. What is missing is the reader writing their
own.

Everything unsettled is a design question:
- Where does saving happen — from Mix, from Search, or both?
- Naming: typed, or generated from the filters and then editable?
- Where do saved lenses live, and how are they edited, reordered, deleted?
- What happens to a saved lens whose filters the API later stops supporting?

## 2. Mix → Tags filter

The API supports filtering a blend by tag and `SearchQuery` already carries
tags. Only the UI is missing. The hard part is the same as everywhere else in
this app: **a series carries up to 146 tags**, across seventeen groups, each
weighted core → defining → recurrent → incidental. A flat picker is not usable.
The series detail screen solves this by grouping and showing four groups by
default; a filter needs its own answer.

## 3. Mix → Blocked tags

The blocked-tag list is global and lives in Settings. The original mockup put a
second on/off switch for it inside the search filter sheet, which I deliberately
did not build: two controls for one thing is how they drift, and it would need a
"blocking is currently off" state nothing else in the app has.

If you want per-search blocking, it is a feature to spec — not a switch to draw.

## What to hand back

The save flow end to end, where lenses live, and a tag picker that survives 146
tags.
