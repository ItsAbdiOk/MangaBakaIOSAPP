# BakaManga — feature specification

Companion to [`discovery-first-mangabaka-client.md`](discovery-first-mangabaka-client.md),
which covers architecture. This one covers what the app *does*.

Every feature below is checked against the OpenAPI spec; the endpoints that
power it are named. Nothing here assumes an API capability that does not exist.

## What the app is

A discovery-first MangaBaka client for iPhone. You open it without a goal and
leave with something to read. It also reaches broad parity with the website's
browsing features, bounded by what the API exposes.

It is not primarily a tracker. Tracking exists so that discovery can be
personal and so a found series does not get forgotten — not as the main event.

## Principles

1. **Never a dead end.** Every screen offers a next thing to look at.
2. **Content before chrome.** Covers are the interface; the app gets out of the way.
3. **Nothing is lost.** Anything you react to is retrievable later.
4. **Fast, then pretty.** Cached content renders instantly; nothing waits on a spinner it could avoid.
5. **Honest about provenance.** MangaBaka and the upstream sources are credited where the data appears, not only in an About screen.

---

## Decision required: content rating

`content_rating` has four values: `safe`, `suggestive`, `erotica`,
`pornographic`. Discovery endpoints accept `content_rating` and
`not_content_rating` filters, so this is fully controllable — but the choice
drives the App Store age rating and what a first-time user sees.

Three coherent options:

| Option | Behaviour | App Store consequence |
|---|---|---|
| **A. Safe only** | `erotica` and `pornographic` filtered everywhere, no setting | Lowest age rating, simplest review |
| **B. Safe by default, opt-in** | Defaults to `safe` + `suggestive`; a Settings toggle unlocks more | Higher age rating (17+); needs a deliberate, non-trivial opt-in |
| **C. Unfiltered** | Everything, no filtering | 17+ minimum; explicit covers on the home feed by default |

**DECIDED: B.** Default is `safe` + `suggestive`. `erotica` and `pornographic`
are excluded unless the reader turns them on in Settings.

**AMENDED 2026-09-12 — `pornographic` is not offered at all.** Option B as
written above shipped, and then came off. App Review guideline 1.1.4 bans overtly
sexual material, and a default-off toggle is not a defence: a reviewer who can
turn it on is a reviewer who sees it, and the penalty for that is removal rather
than a rejection you fix and resubmit. So the enum a reader chooses from is now
`safe`, `suggestive`, `erotica` — three values, not four — and no request the app
makes can ask for the fourth.

`erotica` stays, because "sex, not explicit" is the line Apple actually draws,
and it is now behind the deliberate opt-in this section always called for: an
alert naming the consequence and the age, on the way in only. `requiresOptIn`
had existed unread since the setting was first written, so Explicit had been a
single tap like any other switch.

The API still returns `pornographic`, so it is still named once in the code, in
`ContentPreferences.apiRatings`. That is deliberate and load-bearing: the
question "what has the reader NOT opted into" drives which tag *names* are kept
out of recommender captions, and deriving that list from the reader's three
choices would have quietly stopped hiding the fourth.

The 17+ consequence below is unchanged — mature content is still reachable — but
note Apple has since moved to 13+/16+/18+ tiers, so confirm which applies before
filling in App Store Connect.

Consequences to design and build for:
- The app is rated 17+ regardless, because the content is reachable.
- The opt-in must be deliberate: a Settings toggle with plain language about
  what changes, not a switch buried in a list.
- Filtering happens server-side via `content_rating` / `not_content_rating` on
  every discovery and search request, so unwanted covers are never downloaded,
  never cached, and never briefly visible while a client-side filter catches up.
- The setting must apply to the cache too: changing it invalidates cached feeds,
  since a cached feed was fetched under the previous filter.

---

## Phase 1 — Discovery core

The reason the app exists. All endpoints public; no login required.

### 1.1 Home
One scrollable surface, assembled from several sources so it never looks the
same twice.

- **Rising** — `/v2/series/discover/rising` (`window_days` adjustable, 7 default)
- **Hidden gems** — `/v2/series/discover/hidden-gems`
- **Trending** — `/v2/series/search?sort_by=trending_7d` and `trending_30d`
- **News** — `/v2/news` (`only_primary`, `type`)
- **Community pulse** — `/v0/frontpage/community-pulse`
- **Upcoming** — `/v1/works/upcoming?days=N`

Each row scrolls horizontally; the section header opens a full grid.

### 1.2 The stack — next-read triage
One series at a time, cover-forward, full bleed. Swipe right to save, left to
skip, up for detail. Phone-native; the website has no equivalent.

Fed by `/v1/series/mix`, which accepts seed series, so the stack sharpens as
you use it. `blocked_tag` powers a personal "never show me this" list.

Skips are remembered locally so the same series does not keep reappearing.

### 1.3 Mix — the signature feature
`/v1/series/mix` takes seed series plus 20+ filters and returns a blended
recommendation set. **It requires no authentication**, which makes a genuinely
personal recommender available before any login exists.

- Pick up to N series you love → get a mix built from them
- Filter by type, genre, tag (`and`/`or`), publisher, staff, rating range,
  publication dates, licensed status
- `blocked_tag` to exclude themes you dislike
- `/v1/series/mix/seeds` suggests starting points
- `exclude_user_library` and `blend_user_id` become useful once signed in

Saved mixes act as named, re-runnable lenses ("cosy fantasy, completed, 4+").

### 1.4 Series detail — the rabbit hole
The most important screen for the app's core promise: no dead ends.

From `/v2/series/{id}` and `/v1/series/{id}/full`:
cover, titles by language, description, authors, artists, publishers,
status, type, rating and rating count, chapters, volumes, publication dates,
anime adaptation, content rating.

Onward paths, each its own row:
- **Similar** — `/v2/series/{id}/similar`
- **Readers also like** — `/v2/series/{id}/readers-also-like`
- **Related** — `/v1/series/{id}/related` and `/relationships` (sequels, prequels, spin-offs, adaptations)
- **Collections** — `/v1/series/{id}/collections`
- **Tags and genres** — tap through to a filtered search
- **Same publisher** — `/v1/publishers/{id}/collections`
- **Series news** — `/v1/series/{id}/news`
- **Read it elsewhere** — `/v1/series/{id}/links`
- **On other trackers** — `/v1/source/*` (AniList, Kitsu, MangaUpdates, MyAnimeList, Anime-Planet)
- **More covers** — `/v1/series/{id}/images`

### 1.5 Search
`/v2/series/search`, which is far richer than a text box:
free text, type, status, content rating, tags (`and`/`or`), publisher, staff,
publication date ranges, rating range, licensed status, and 20 sort orders
including `trending_7d`, `trending_30d`, `random`, `score_desc`, `popularity_desc`.

- Plain search bar by default; filters behind one control
- Filter sets are savable and become browsable lenses
- `sort_by=random` with filters is a "surprise me" button

### 1.6 Shelf — saved for later
Local at first, synced once signed in. Discovery is worthless if what you find
is forgotten by morning.

Sections: saved from the stack, saved from browsing, and skipped (recoverable).

---

## Phase 2 — Parity browsing

The website's other surfaces, so the app is not merely a discovery toy.

- **Collections** — `/v1/collections/{id}`, `/full`, `/works`
- **Publishers** — `/v1/publishers/all`, `/search` (by type, year, open/closed), `/{id}/collections`
- **Genres and tags** — `/v1/genres`, `/v1/tags`, each opening a filtered grid
- **News** — `/v1/news`, `/v2/news`, filterable by type
- **Works and editions** — `/v1/works/{id}`, `/v1/editions/{id}`, `/v1/works/upcoming`
- **Community** — `/v0/mod/leaderboard`, `/v0/mod/statistics`

---

## Phase 3 — Account and library

Blocked on a `client_id` from MangaBaka. Everything above ships without it.

### 3.1 Sign in
OAuth `authorization_code` + PKCE `S256` via `ASWebAuthenticationSession`,
with `refresh_token` and `offline_access`. Scopes: `library.read`,
`library.write`, `profile`.

### 3.2 Library — `/v1/my/library`
Seven states, richer than the usual five:
`considering`, `plan_to_read`, `reading`, `rereading`, `paused`, `completed`,
`dropped`.

`considering` is a genuine gift for this app: the stack's "maybe" pile has a
real server-side home rather than a local invention.

Per entry: `progress_chapter`, `progress_volume`, `rating`, `note`,
`start_date`, `finish_date`, `number_of_rereads`, `priority`, `is_private`,
`read_link`.

- Batch reads and writes via `/v1/my/library/batch`
- Local shelf migrates into the library on first sign-in
- Writes are `NO_CACHE`, so they are queued and retried rather than fired blind

### 3.3 Personalised
- `/v1/my/series/recommendations` and `/status`
- `/v1/my/series/discover/top-genres`
- `exclude_user_library` on mix and search, so nothing already read is suggested
- `/v1/my/profile`

### 3.4 Contributing (optional, later)
`/v0/my/submissions/*` — propose corrections from the series screen. Turns a
reader into a contributor, which is how MangaBaka's data improves.

---

## Cross-cutting

- **Offline** — anything seen before renders without a network. Already built.
- **Attribution** — MangaBaka plus every upstream source, in-context and on a dedicated screen. A licence obligation, not a nicety.
- **Settings** — content rating, preferred title language, appearance, cache size and clear.
- **Accessibility** — Dynamic Type throughout, VoiceOver labels on covers built from the series title, reduced-motion alternatives for the stack.
- **No telemetry.** No analytics SDK, no third-party endpoint, no exceptions without an explicit decision.

---

## Screen inventory (for the mockup)

1. Home — mixed feed
2. The stack — swipe triage
3. Series detail — the rabbit hole
4. Search — with the filter sheet
5. Mix builder — seeds and filters
6. Shelf — saved, skipped
7. Library — states and progress (phase 3)
8. Settings — including content rating
9. Attribution
10. Empty, offline and rate-limited states

State 10 is not an afterthought. Empty and error states are where most apps
feel cheap, and this app will hit rate limits it did not cause, because the
limit is per IP and shared with everyone on the same network.

---

## Open questions

1. ~~Content rating default~~ — decided: safe + suggestive, opt-in for more.
2. **v1 vs v2** where both exist. Carried over from the architecture doc.
3. **Does the stack need auth to be good?** `mix` is public, so probably not — worth measuring rather than assuming.
4. **Naming**: the app is BakaManga; MangaBaka is the data source. Keeping those distinct in the UI matters for the trademark position.
