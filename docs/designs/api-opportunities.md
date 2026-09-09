# What else the API will let us do

Written 2026-09-09 by exploring the live API, not the spec. Everything below was
fetched and inspected; where the spec and reality disagree, reality is recorded.

Ordered by whether it earns a screen, which is a different question from whether
it is interesting.

---

## Already worth building

### 1. Mix DNA — "why this blend"

`/v1/series/mix` returns a `dna` field alongside its results: ten tags with
weights, describing what the blend is actually made of.

```
Male Lead 0.140 · Sick Family Member 0.113 · Sick Parent 0.112
Poor to Rich 0.107 · Mother 0.104
```

Nothing in the app uses this. It is the difference between a recommender that
hands you a list and one that shows its reasoning — and it makes the Mix screen
tunable rather than magic: you can see the blend drifting towards "Sick Parent"
and remove the seed causing it.

**Shape:** a horizontal weighted bar or a tag cloud sized by weight, sitting
directly under the seeds. **Cost:** small, the data is already in the response
we make.

### 2. A taste profile from `top-genres`

`/v1/my/series/discover/top-genres` returns the reader's tag affinities with
scores — verified on a real account: Time Travel 83.7, Transmigrated into a
Game 52.0, Age Regression 37.5.

This is the closest thing to a portrait of someone's taste that the API offers,
and it is computed server-side from their own library. A "your taste" surface
built on this is honest in a way that a generic recommender is not: every claim
is traceable to something the reader actually read.

**Caveat that matters:** scores are comparable within one reader, not between
readers. Present as a ranking, never as a number to compare with anyone else.

**Cost:** small. Needs auth, so it is gated behind the `client_id`.

### 3. A release calendar from `works/upcoming`

`/v1/works/upcoming?days=N` returns forthcoming volumes with `release_date`,
`price`, `pages`, ISBN `identifiers`, cover images and volume index.

That is a genuine calendar, not a feed — the one thing a tracker can tell you
that a catalogue cannot. "Volume 8 of a series you're reading arrives on the
14th" is a reason to open an app.

**Cost:** medium. Real value needs cross-referencing against the reader's
library, which means auth. Without auth it is still a browsable "what's coming"
list.

---

## Worth building later

### 4. The tag tree as a browsing surface

Tags are hierarchical: `parent_id`, `level`, a full `name_path` like
"Activities > Sports > Boxing", and a `series_count` per tag. There are
thousands.

A flat chip list would be useless. A tree, ordered by usage, is a genuinely
different way to browse from search — closer to wandering a library than
querying a database. `is_spoiler` also exists, which means spoiler tags can be
hidden behind a tap on a detail screen rather than sitting there ruining a plot.

**Cost:** medium. The data layer is built; it needs a design.

### 5. Publishers as a lens

Publishers carry `country_of_origin`, `founded`, `closed`, `sub_type` and
aliases. "Everything Ize Press licensed in English" is a real browsing intent,
and defunct publishers make for a genuinely interesting archive view.

**Cost:** small once designed. Niche, but cheap.

### 6. Community pulse

`/v0/frontpage/community-pulse` returns figures with week-over-week deltas:
304,040 active series (up from 303,750), 290 new this week, 18,598 registered
users.

MangaBaka is a community-maintained database, and this is the only surface that
says so. A small, honest strip — "290 series added this week" — communicates
that the data is alive and maintained by people. It also sets up contribution.

`/v0/mod/leaderboard` buckets contributors by today / week / month / year / all.

**Cost:** small. **Caution:** easy to turn into vanity metrics. One line, or
nothing.

---

## Probably not worth it

### 7. Submissions and contribution

`/v0/my/submissions/*` lets a reader propose corrections. Editorially the right
thing — MangaBaka's data improves because people fix it — but a submission form
is a lot of screens for something few readers will use, and doing it badly
creates moderation load for someone else.

**Verdict:** not until the app has readers who care enough to want it. Revisit
after release, not before.

### 8. `phash` image search

`/v2/series/search` accepts a `phash` parameter — perceptual image hashing,
which implies "find this series from a picture of its cover".

Genuinely exciting, and almost certainly a trap: it needs local hash generation
matching the server's algorithm exactly, with no documentation of which one.
Worth one timeboxed experiment, not a roadmap item.

### 9. `blend_user_id` on mix

`/v1/series/mix` accepts `blend_user_id` — apparently blending two readers'
tastes. A social feature hiding in a recommendation endpoint.

Undocumented, and it raises a privacy question the API's own docs do not answer:
whose data is being read, and did they agree. **Do not use without asking
MangaBaka directly what it does.**

---

## Corrections to the mockup's assumptions

The design mockup listed several fabricated fields. Three turn out to be real:

| Mockup assumed | Reality |
|---|---|
| "Anime adaptation" derived from `rating > 8.4` | Real field: `anime.exists`, with start/end chapters |
| Cross-tracker scores invented as arithmetic offsets | Real: `source` carries AniList, Kitsu, MangaUpdates, MAL, Anime-Planet and ANN with normalised ratings |
| "Shares tag" line generated from the first tag | Real: `shared_tags` and `shared_tags_total`, up to 88 shared tags on a match |

One assumption was correct to flag as fake: `mix` ordering is genuinely opaque,
and there is no field explaining rank beyond `score` and `cosine`.

---

## Things that surprised me, recorded so nobody rediscovers them

- Two envelope shapes exist. Most endpoints return `data`; recommendations and
  top-genres return `results` with extra top-level flags. Neither decodes as
  the other.
- A library entry nests its series under a capitalised `Series`, which survives
  `convertFromSnakeCase` untouched while every other key does not.
- `content_rating` must be repeated, not comma-joined. The comma form returns
  HTTP 400 and once broke every feed in this app.
- `mix` rejects a seedless request outright rather than returning a default set.
- A series has no `title` field. Every title is language-tagged, and every one
  is flagged `is_primary`, so that flag cannot select a display title.
- Personalised recommendations are **not** content filtered by default. A reader
  who set the app to safe content would still receive explicit suggestions
  unless the filter is passed explicitly.
- `/v1/series/{id}/news` ignored a `limit` of 2 and returned 48.
