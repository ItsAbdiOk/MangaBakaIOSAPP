# Roadmap — "help people find the work faster"

Abdi, 2026-09-11: nothing here reproduces copyrighted material. Every item
links to the official product, the official reader, or a first-party store,
and only where the source says the thing exists in the reader's language.
Weekly limit reset before any of it is built.

## From Abdi, in build order

1. **Hero compression only when it has to.** Full hero (byline, cadence
   sentence, bigger schedule) if it fits the cover's height; the compact forms
   only when it would not. `ViewThatFits` vertical, full first. Half a day.
   Two UI snapshots (short title, long title).

2. **"Read" opens the exact title in the official app.** Webtoons, Tapas
   (verify), via universal links: `UIApplication.open` on the READ OFFICIALLY
   link MangaBaka already gives us — the app opens at that title if installed,
   Safari if not. Language comes from the link, so the button only appears for
   a link in the reader's language on a verified platform; otherwise no button.
   Kakao unverified. Cannot be tested on the simulator — needs the phone with
   Webtoons installed. Half a day plus that check.

3. **Glass covers everywhere, cover colour bleeding into the ground.** BlurHash
   already gives a dominant colour per card for free; a per-row ambient tint is
   an average of the visible cards'. Glass over ~60 cards is GPU work: build it
   behind a flag and measure scroll frame time on the 16 Pro with the
   performance target *before* it defaults on. If it drops frames, detail page
   only. 1–2 days.

4. **All the volumes, with official covers and buy links.** MangaBaka's `/works`
   is sparse (One Piece: 8 of 113). Fill from the iTunes Search API
   (`media=ebook`, `country=` for the storefront — free, no key, cover + Apple
   Books link) and Google Books (ISBNs, Play Books link, 1,000/day). Strict
   match: title and volume number must both appear in the result, else the row
   says "couldn't verify" rather than showing a wrong cover. Lazy per visible
   spine, cached on disk. No Amazon: PA-API needs an Associates account —
   Abdi's signup, not mine. 2–3 days.

5. **"Preview" beside a volume, only where a preview exists.** Apple: the Books
   app link, where "Sample" is native. Google: `webReaderLink` in-app when
   `viewability == PARTIAL`. No page images pulled directly — undocumented,
   watermarked, against terms. Expect the button to be absent on most licensed
   manga; that is correct. Webtoons' free first episodes are the real preview
   and item 2 lands on them. 1 day on top of item 4.

## Same theme — accepted by Abdi 2026-09-11, part of the roadmap

- **Scan the barcode in a shop.** VisionKit's on-device scanner reads the ISBN
  off a physical volume → Google Books resolves the title → MangaBaka search
  → the series page, with your library state on it ("you're on chapter 53").
  No terms issue; nothing leaves the phone but a title. The single most
  "find it faster" thing on this list. ~1 day.
- **Price across stores.** Apple Books, Google Play and MangaBaka's own listed
  price side by side on the volume sheet, from the same lookups as item 4.
  Read-only store data; fine. Half a day once 4 exists.
- **iOS search finds your library.** Core Spotlight index of library series
  (title, cover, state) so Spotlight opens the series page. App Intents for
  "What's due this week" and "Open <series>". No network, no terms. ~1 day.
- **mangabaka.org links open in the app.** Universal links for our own domain
  paths (`/manhwa/3397/…` → series page), and the share sheet sends that link.
  Needs the association file hosted on mangabaka.org — ask MangaBaka. Half a
  day our side.
- **"Where to read, in your language."** A row on the series page listing the
  official platforms carrying it in the reader's language, from the links we
  already decode and filter — the surface item 2's button sits on. Half a day.
- **New from a publisher you follow.** `/v1/publishers/{id}/collections`
  exists; a "coming from Seven Seas" row or a reminder when a followed
  publisher lists a volume. 1 day; needs a design for "follow".

Declined, with the reason: Amazon links without an Associates account; pulling
preview pages as images; a generic "open Webtoons" button that lands anywhere
but the title; Crunchyroll for the anime (no per-title link in the data).
