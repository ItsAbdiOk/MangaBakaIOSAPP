# Two prompts for Gemini

Fill in anything in `[square brackets]` before pasting — those are things I don't know and shouldn't guess for you.

---

## Prompt 1 — describing the app

> I'm building an iOS app and I want to explore ideas with you. Here's what it is.
>
> **MangaBaka** is a native iPhone app (SwiftUI, iOS 26, Swift 6) for tracking and
> browsing manga, manhwa, manhua and light novels. It is an unofficial third-party
> client for MangaBaka, a community manga database — I authenticate against their
> API with a personal access token. I am not affiliated with them. [Confirm whether
> they have public API terms and whether third-party clients are allowed.]
>
> **What it does today:**
> - A personal library: track series, reading status, progress in chapters, ratings.
> - Discovery feeds on the home screen, ranked partly by the tags already in your library.
> - Search and browse by tag, author, publisher — full pagination, not a capped sample.
> - A detail page per series: synopsis, stats, chapter count, cover gallery, tags,
>   related series.
> - Cover galleries narrowed to English plus the series' own original language
>   (Japanese for manga, Korean for manhwa, Chinese for manhua; novels unfiltered).
> - Character profiles with art and biography.
>
> **Where the data comes from** (this part matters most for what I want to ask you):
> - **MangaBaka API** — the core catalogue. Authenticated with a token.
> - **Apple's iTunes Search API** — individual volume covers, prices and Apple Books
>   store links for a series. Every volume shown links to its Apple Books page.
> - **Google Books API** — covers only, and only for volume *numbers* Apple doesn't
>   carry. Apple always wins a collision. The section is labelled "Apple & Google
>   Books" when both contributed. Each Google volume links to its Google Books page.
>   Unauthenticated — it uses Google's anonymous quota, so it often returns nothing
>   and the shelf quietly falls back to Apple's volumes alone.
> - **AniList (GraphQL)** — character profiles and biographies.
> - **Shikimori** — fallback source for character info when AniList is unreachable.
>   Its content is in Russian, so I translate it on-device with Apple's Translation
>   framework before the user ever sees it.
> - **MangaUpdates** — [describe what you actually use this for].
>
> **Deliberate constraints I've already set:**
> - No analytics, no telemetry, no third-party tracking SDKs. Nothing phones home.
> - No manga content is hosted, cached or served by me — no scans, no reader. This is
>   a catalogue and tracker only. Links go out to legitimate storefronts.
> - The only credential is a MangaBaka personal access token, stored in the iOS
>   Keychain and entered by the user in Settings. Nothing is shipped in the binary.
> - Nothing is monetised. There's no account system of my own, no server of my own.
>
> **Where I want to take it:** [your ideas here — this is the part I can't write for you]
>
> Don't write code. I want to think through ideas, trade-offs and risks with you.
> Ask me questions where my description is thin.

---

## Prompt 2 — App Store guidelines

> I'm preparing to submit an iPhone app to the App Store and I want a hard-nosed
> review of what will and won't survive App Review. Assume the description I've
> given you is accurate. Be specific: cite the actual App Store Review Guideline
> numbers, and separate "this will be rejected" from "this is a grey area a reviewer
> might question" from "this is fine."
>
> Focus on these, and tell me if I'm missing a category:
>
> 1. **Third-party API data.** The app's catalogue comes from a community database
>    via an authenticated API, and character data from AniList and Shikimori. What
>    does Apple require regarding rights to third-party content and API terms of
>    service? (Guideline 5.2 territory.) Does the reviewer verify this, or is it
>    my liability to sort out with the data provider?
>
> 2. **Minimum functionality / "is this just a web wrapper?"** Guideline 4.2. The
>    app is a native reader-free catalogue and tracker over someone else's database.
>    What makes something like this "enough of an app"?
>
> 3. **Google Books and Apple's iTunes Search API.** I show volume covers and prices
>    sourced from both. Google's branding terms require attribution and a link back
>    per result, which I do. Apple has its own terms for the iTunes Search API and
>    for using Apple Books artwork and linking to the store. What are the actual
>    restrictions, and is there a conflict with anything in the Review Guidelines?
>
> 4. **User-generated / mature content.** The catalogue includes series with mature
>    content ratings and sexual or violent themes, and cover art that reflects that.
>    No content is hosted by me — covers and synopses come from the API. What does
>    Apple require: age rating, content filtering, a way for users to hide explicit
>    covers, reporting mechanisms? (Guidelines 1.1, 1.2, 1.4.) Where's the line
>    between "mature catalogue" and "rejected"?
>
> 5. **Anything that could read as piracy adjacency.** Guideline 5.2.3 and similar.
>    The app hosts nothing and has no reader — but the *subject matter* is manga,
>    and I want to know what patterns get apps in this space rejected, including
>    things that look innocent (linking out, naming scanlation groups, showing
>    chapter counts that only exist unofficially).
>
> 6. **A token entered by the user.** Users paste their own MangaBaka personal
>    access token into Settings to reach their library. Is requiring a user-supplied
>    token acceptable, or does it trip "requires additional setup to function" rules?
>    What has to work for a user who never enters one?
>
> 7. **Privacy.** Privacy manifest, nutrition label, third-party SDK disclosure. I
>    collect nothing and run no analytics, but the app does make network calls to
>    several third parties. What do I have to declare?
>
> 8. **On-device translation.** I translate Russian source text with Apple's
>    Translation framework before display. Any disclosure or accuracy obligations?
>
> For each point, end with the concrete thing I'd have to build, write or obtain —
> not just the rule. If something is genuinely unknowable without asking Apple,
> say so rather than guessing.
