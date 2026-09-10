# MangaBaka: what the terms actually say about third-party API use

**Summary: unaddressed, leaning permitted-with-conditions.** No document explicitly says "third-party apps are welcome," but the Terms of Service, Acceptable Use Policy (AUP), and Data License all describe rules *for* applications built on the API (attribution display, OAuth scopes, rate limits), which only makes sense if third-party clients are contemplated as a normal use case. Nothing forbids building a client app; several clauses forbid specific things you could do with one (bulk harvesting, competing services, redistributing third-party data, commercial use without a license).

Primary sources used: `mangabaka.org` (the live site; `mangabaka.dev` is dead — see Q4). All quotes pulled from rendered page text on 2026-09-10; the Data License page is dated "Last Updated: 2026-03-24".

---

## 1. Do Terms of Service / AUP / acceptable-use policy exist at all?

Yes. MangaBaka publishes five linked legal documents from `/about`:

- Terms of Service — https://mangabaka.org/about/terms
- Acceptable Use Policy — https://mangabaka.org/about/acceptable-use
- Data License — https://mangabaka.org/about/data-license
- NonCommercial Terms (supplementary) — https://mangabaka.org/about/data-license-noncommercial
- Privacy Policy — https://mangabaka.org/about/privacy
- DMCA Policy (linked from About, URL not separately fetched)
- Commercial Pricing — https://mangabaka.org/about/pricing (referenced, not fetched)

All confirmed live and readable (HTTP 200) as of 2026-09-10.

## 2. Do they permit third-party clients/apps built on the API?

Not stated as an explicit yes/no. But it's addressed *indirectly and repeatedly* as an expected use case:

- Data License §6.5: "**Applications, websites, or services that display data obtained from the MangaBaka API or database downloads must include a visible attribution to MangaBaka.**" (https://mangabaka.org/about/data-license) — this rule presupposes third-party apps exist and are allowed to display the data.
- AUP §4.3: "Applications using OAuth must request only the scopes they actually need and must clearly inform users of what data they access." (https://mangabaka.org/about/acceptable-use) — OAuth applications (i.e., third-party apps that authenticate users) are explicitly regulated, not banned.
- Terms of Service §4.3: "Access to the MangaBaka API and database downloads is governed by the Data License." (https://mangabaka.org/about/terms)

What **is** explicitly forbidden, regardless of who's building the client:
- Data License §6.2: "You may not systematically download the entirety or a substantial portion of Licensed Content via the API... If you need a full or substantial dataset, use the database download instead."
- Data License TL;DR: "DO NOT bulk-harvest data via the API, or present MangaBaka data as your own."
- AUP §4.1: "You must not use the API to create a competing service, mirror, or bulk data archive."

**Verdict for this project:** an iOS app that reads the API for a user's own browsing/library use, with attribution, and without re-hosting a bulk copy of the database, fits the pattern the docs assume. Nothing found forbids it. Nothing found is an affirmative grant either — it's silence-shaped-like-permission via the rules that regulate the activity.

## 3. Is attribution required? Exact wording, and where?

Yes, required. Two sources, consistent with each other:

From the API docs page (https://mangabaka.org/api):
> "When using the API, please make sure to attribute both MangaBaka and the underlying data providers. Attribution could be done in the following ways:
> - A link in the footer of your site or application
> - A link in your project's README file
> - A link in the 'About' page of your site or application
> - A link to a specific series next to your own data for that series"

From the Data License (https://mangabaka.org/about/data-license), §3 (governing MangaBaka-original data under CC BY-NC-SA 4.0):
> "**Attribution** — You must give appropriate credit to MangaBaka, provide a link to the license, and indicate if changes were made. You may do so in any reasonable manner, but not in any way that suggests MangaBaka endorses you or your use."

And §6.5 (applies regardless of license, covers any data displayed from the API):
> "Applications, websites, or services that display data obtained from the MangaBaka API or database downloads must include a visible attribution to MangaBaka. Where Third-Party Data is displayed, you should also attribute the relevant Third-Party Provider following that provider's requirements."

No specific logo, exact text string, or pixel/placement spec is given — it's "a link," in one of the listed locations (footer / README / About page / next to the specific series). For Third-Party Data (AniList, MAL, etc. — see Q6/aggregation note below) you're additionally told to follow that provider's own attribution requirements, which are not detailed on MangaBaka's site.

## 4. Is an API key or registration required, or is it fully open?

Fully open for the general/read endpoints — **not stated as requiring a key anywhere I could find**. The live API docs page (https://mangabaka.org/api) lists endpoint kinds (`Search`, `Default GET *`) with no mention of an API key, `Authorization` header, or registration step. Searched the rendered page text for "api key," "token," "register," "authentication required" — none of those phrases appear.

One caveat: `/my/*` endpoints exist ("Default * /my/* — Never cached — 180 requests per minute") which are clearly user-account-scoped (your library, your data) and would need you to be signed in — but that's account auth for *your own* data, not a general API key for reading the public database.

Note on host: **`api.mangabaka.dev` is dead.** Fetching it now returns:
> `{"status":500,"message":"api.mangabaka.dev is deprecated and no longer serves traffic — switch to https://api.mangabaka.org. Questions: https://mangabaka.org/discord"}`

The correct/current API host is `https://api.mangabaka.org`. If this project's code or notes reference `mangabaka.dev`, that's now a dead endpoint — worth flagging separately as a real bug, not just a terms question.

## 5. Is there a documented rate limit — per-IP or per-key?

Yes, documented with numbers, and it's per-IP (there's no key to scope it by). From https://mangabaka.org/api:

| Kind | Path | Cache | Limit | Limited by |
|---|---|---|---|---|
| Search | `GET /series/search` | — | 30 requests/minute | IP + Leaky Bucket |
| Default | `GET *` | — | 180 requests/minute | IP + Leaky Bucket |
| Default | `/my/*` | Never cached | 180 requests/minute | IP + Leaky Bucket |

Also: "Rate Limiting is only applied to uncached requests, so requesting `GET /v1/series/1` 10 times will only count as 1 request... You can check if your request was cached by checking the `cf-cache-status: HIT` header... Exceeding the rate limit will result in a `429 Too Many Requests` response." Rate limits of the same "kind" are shared across all endpoints of that kind.

The Data License (§6.1, 6.4) separately states you must respect published rate limits and must not circumvent them technically; "persistent or deliberate abuse... may result in temporary or permanent suspension of API access."

## 6. Commercial use / redistributing or caching data

Both addressed, in detail, in the Data License (https://mangabaka.org/about/data-license):

**Commercial use — not permitted without a paid license.**
> "**NonCommercial** — You may not use MangaBaka Data for commercial purposes. Commercial purposes include, but are not limited to: selling or licensing access to the data, incorporating the data into a product or service offered for monetary compensation, using the data to generate revenue through advertising, or using the data to train, fine-tune, or evaluate machine learning models that are developed for or deployed in commercial products or services."

Pay-what-you-want commercial licensing exists via https://mangabaka.org/about/pricing (page not fetched directly; described secondhand via search results as "pay-what-you-want," with a **$150/month incidental-revenue threshold** below which you don't need a commercial license — this specific number came from search-engine summaries, not a page I fetched directly, so treat it as second-hand pending direct confirmation).

**Redistributing third-party (aggregated) data — no rights granted, at all.**
> "§4. MangaBaka does not hold redistribution or sublicensing rights for Third-Party Data. Accordingly, **no license is granted to you** to redistribute, sublicense, relicense, or commercially exploit Third-Party Data obtained through the MangaBaka API or database downloads... If you wish to redistribute, republish, store, or otherwise use Third-Party Data outside of your personal interaction with MangaBaka, you are solely responsible for obtaining the necessary rights or permissions from the relevant Third-Party Provider."

**Caching — permitted, within limits.**
> "§6.2 No Bulk Harvesting via API: ... Reasonable caching for performance purposes is permitted, provided cached data is refreshed regularly and not redistributed."

**AI/ML training** is called out separately (§6.6): non-commercial personal/academic experimentation is fine under the standard license; commercial ML training/fine-tuning/eval requires a prior written agreement with MangaBaka (and third-party providers where their data is involved).

## 7. Stated contact route for permission

Yes, three explicit addresses plus Discord, from https://mangabaka.org/about:

- **Legal & Licensing** (commercial licensing, data-use questions, legal matters): `legal@mangabaka.org`
- **Security** (vulnerabilities, responsible disclosure): `security@mangabaka.org`
- **Copyright / DMCA**: `dmca@mangabaka.org`
- **Community / general questions**: "Join our Discord"

For this project, `legal@mangabaka.org` is the right address to ask "is a third-party iOS client okay" directly, since nothing in the docs says so explicitly.

## 8. `blend_user_id` / any endpoint exposing one user's data to another — consent?

**Not stated anywhere I could find.** Searched the Terms of Service, AUP, Data License, Privacy Policy, and the site's own `/mix` ("Build a Mix") feature page for `blend`, `blend_user_id`, "taste profile," "library visibility," and "share your" — no hits in the legal documents. The `/mix` page itself has a "Blend with my taste" option gated behind "Sign in or create an account to hide library entries and blend with your taste," which implies:
- blending is opt-in and tied to your own signed-in account's data, not a mechanism for pulling one arbitrary user's data into another's view, and
- library entries can be hidden (a privacy control exists at the feature level).

But there is no documented API parameter named `blend_user_id`, and no privacy-policy language about consent for one user's taste data being used by/shown to another user. If this app's code or notes reference `blend_user_id` as a real API parameter, that's either an undocumented/internal field or something from a different source — I could not confirm it exists in MangaBaka's public API docs at https://mangabaka.org/api.

## Aggregated-source licensing note (AniList, MyAnimeList, MangaUpdates, Anime-Planet, Kitsu)

The Data License is explicit that this is a separate legal category, not covered by MangaBaka's own CC BY-NC-SA 4.0 grant:

> "§4. MangaBaka does not hold redistribution or sublicensing rights for Third-Party Data... no license is granted to you to redistribute, sublicense, relicense, or commercially exploit Third-Party Data."

Provenance is marked in the data itself so you can tell which rules apply (§5): JSON responses nest third-party fields under `source` (e.g. `source.anilist`, `source.my_anime_list`); SQLite downloads prefix them `source_` (e.g. `source_anilist_id`). Where provenance is ambiguous, you're told to treat it as third-party and apply the more restrictive rule.

Direct links to each provider's own terms, as listed on https://mangabaka.org/about/data-license §7:

| Provider | Terms link |
|---|---|
| AniList | https://docs.anilist.co/guide/terms-of-use |
| MyAnimeList | https://myanimelist.net/about/terms_of_use |
| MangaUpdates | https://api.mangaupdates.com/#section/Acceptable-Use-Policy |
| Kitsu | https://kitsu.app/terms |
| Shikimori | https://shikimori.one/api/doc |
| Anime-Planet | https://www.anime-planet.com/about/terms |

Interesting reciprocal clause (Data License §3.1): these same third-party providers are granted a license to use *MangaBaka's* data commercially, if their own revenue is under $10,000/month — a one-way courtesy in their favor, not one that extends to unrelated third-party app builders.

## What is still unknown

- Whether MangaBaka would say yes to a specific third-party iOS client for this project — nothing found is an explicit grant or refusal; only `legal@mangabaka.org` can settle it.
- Exact numbers on `/about/pricing` (the "$150/month" and "pay-what-you-want" commercial-license details came from search-engine summaries of that page, not a direct fetch of it — worth reading directly before relying on the number).
- Whether `blend_user_id` exists as a real, documented or undocumented API field at all — found no trace of it in the public docs or in the `/mix` feature's visible behavior.
- Exact attribution wording/logo requirements for each individual third-party provider (AniList, MAL, etc.) beyond "follow that provider's requirements" — not detailed on MangaBaka's site; would need to check each provider's own terms link above.
- The DMCA Policy page itself was not fetched directly (only referenced from the About page).
