# Bibliographic sources — libraries, ISBN registries, retail catalogues

Research pass, 2026-09-14. Family: the book world. Brief: `sources-brief.md`.
Every endpoint below was called from this machine; nothing is reported second-hand.

**Headline:** three keyless sources survive all tests and together cover need #1
(volume/edition metadata) better than Google Books did — **Open Library**,
**NDL Search (Japan)**, and **Wikidata**. **openBD** is a strong Japanese
enrichment layer but cannot search. **DNB** and **BnF** are real but narrow.
Nothing in this family replaces need #2 ("when is the next chapter out") —
libraries catalogue books, not weekly episodes. That gap stays open.

---

## The Apothecary Diaries problem — measured, since it decides the ranking

The test: given the string "The Apothecary Diaries", can the source tell the
manga (Square Enix / Big Gangan) from the light novel (Hero Bunko / 主婦の友社)
*from a field*, not from a title suffix?

| Source | Discriminator | Verdict on this test |
|---|---|---|
| Wikidata | `P31` (instance of) — three distinct items: `Q106090656` manga series, `Q48751907` light novel series, `Q106090452` novel series | **Passes cleanly.** Structured, unambiguous, per-item. |
| NDL Search | `dcndl:genre` = `漫画` on manga records; light-novel records carry a bunko imprint in `dcndl:seriesTitle` (`ヒーロー文庫`) and no `漫画` genre | **Passes**, with a caveat: the genre field is present on many but not all records. |
| Open Library | `subject` tags `form:manga` / `form:light novel` | **Fails as a rule, works as a hint** — see the measurement below. It is fan-curated and absent on whole series. |
| openBD | no format field; imprint (`series`) implies it — `ビッグガンガンコミックス` vs `ヒーロー文庫` | Inferable from imprint only. Fragile. |
| DNB / BnF | MARC `655` genre absent on every record I pulled | **Fails.** |

Measured Open Library form-tag coverage, 100-doc samples, `title:"…"` queries:

```
Solo Leveling:            291 found, 100 sampled →   0 tagged (100 × <none>)
One Piece:               1403 found, 100 sampled →  90 × form:manga, 10 × <none>
The Apothecary Diaries:    37 found,  37 sampled →  16 × form:light novel, 21 × <none>
The Beginning After The End: 4 found,   4 sampled →   0 tagged
Delicious in Dungeon:      18 found,  18 sampled →  18 × form:manga + form:manga volume
```

**The practical impact:** for Apothecary, Open Library reliably tells you what
*is* a light novel (16 tagged) but the 21 untagged docs are the manga volumes
*and* some untagged novels mixed together. If you filter with `form:` alone you
get the Apple Books failure back in a new coat. **Use Wikidata's `P31` as the
format authority and Open Library only for the edition rows underneath it.**

---

## 1. Open Library — search + editions API

Replaces: **#1 volume/edition metadata**, partly **#3 covers**.
We already use its cover-by-ISBN endpoint; the search and editions APIs are new to us.

### Endpoints tested

```bash
curl -A "MangaBakaResearch/1.0" \
  'https://openlibrary.org/search.json?q=delicious+in+dungeon&limit=3&fields=key,title,author_name,first_publish_year,isbn,subject'
```

```
{"numFound":20,"start":0,"numFoundExact":true,"num_found":20,
 "documentation_url":"https://openlibrary.org/dev/docs/api/search",
 "q":"delicious in dungeon","offset":null,
 "docs":[{"author_name":["九井諒子"],"first_publish_year":2015,
   "isbn":["0316473065","9782203103993","9784047301535","220310399X","9780316471855",
           "0316471852","9780316473064","4047301531","8416960267","9788416960262"],
   "key":"/works/OL19712075W","number_of_pages_median":192,"title":"ダンジョン飯 1",
   "subject":["franchise:ダンジョン飯","series:ダンジョン飯","form:manga",
              "form:manga volume","form:graphic novel","genre:adventure", …
```

```bash
curl -A "MangaBakaResearch/1.0" \
  'https://openlibrary.org/works/OL19712075W/editions.json?limit=3'
```

```
size 5
- Delicious in Dungeon 1 | pub_date: 2017-05-23 | isbn13: ['9780316473064'] | publishers: ['Yen Press'] | lang: ['/languages/eng'] | covers: [15226797] | pages: 192
- ダンジョン飯 1            | pub_date: 2015       | isbn13: ['9784047301535'] | publishers: ['Kadokawa']   | lang: ['/languages/jpn'] | covers: None      | pages: 192
- Delicious in Dungeon 1 | pub_date: 2017       | isbn13: ['9780316471855'] | publishers: ['Yen Press'] | lang: ['/languages/eng'] | covers: [15226798] | pages: 191
```

This is the single most useful shape found in the whole family: **one work,
every language edition under it, each with its own ISBN-13, publisher, language,
page count and cover id.** That is the French and German editions the brief asked
for, for free, from an endpoint we already talk to.

### Auth, limits

- **Keyless.** No key at all.
- Documented: **1 req/s anonymous, 3 req/s with a descriptive `User-Agent`**
  (`MyApp (contact@example.org)`). Shippable — the UA is not a secret.
- **Observed:** two runs of five sequential queries with 1.0–1.5 s sleeps were
  both cut off mid-run with `ConnectionResetError: [Errno 54]`. The documented
  1/s is optimistic in practice; budget ≥2 s between calls, or go through the
  bulk dump. This is a real finding, not a flake — it happened twice.

### Coverage, measured

| Series | `numFound` | ISBN present | year present | full date? |
|---|---|---|---|---|
| Solo Leveling | 291 | 96/100 | 90/100 | mixed, many year-only |
| One Piece | 1403 | 100/100 | 100/100 | mixed |
| The Apothecary Diaries | 37 | 37/37 | 24/37 | mixed |
| The Beginning After The End | 4 | 2/4 | 4/4 | year-only |
| Delicious in Dungeon | 18 | 18/18 | 18/18 | editions API gave `2017-05-23` |

All five present. TBATE is thin (4 works) — Yen Press print volumes are there
but sparse. Release dates are the weak field: `first_publish_year` is a year,
and full `publish_date` only appears per-edition and only sometimes.

### Covers

Spot-checked `covers.openlibrary.org/b/isbn/{isbn}-M.jpg?default=false`:

```
9784047301535 (ダンジョン飯 1, JP)      → 404
9784088725093 (ONE PIECE 巻1, JP)      → 200
9784046816351 (俺だけレベルアップな件 10) → 404
```

**Japanese-edition cover coverage is poor** — roughly a third in this sample.
English editions are much better. Does not solve need #3 on its own.

### Licence

Weak spot, and I am not going to paper over it. The licensing page says only:

> "The Internet Archive does not assert any new copyright or other proprietary
> rights over any of the material in the Open Library database."

It **does not name a licence** and concedes "the legal issues are, frankly,
very confusing." That is not CC0 and should not be written up as CC0. Practical
reading: attribution to Open Library / Internet Archive costs nothing and
removes the argument. **Display "Edition data from Open Library".**

### Bulk dump

`https://openlibrary.org/data/ol_dump_latest.txt.gz` → 302 to
`archive.org/download/ol_dump_2026-08-31/ol_dump_2026-08-31.txt.gz`. Monthly,
whole-database. Far too large to ship whole (tens of GB uncompressed) but a
filtered manga slice is a legitimate bundled artefact, consistent with the
existing 20k-title offline index.

### Apple risk

**None.** Bibliographic metadata from a library. No 5.2.3 surface.

### Verdict — **build on it.** Primary edition source.
Caveats: rate limit is harsher than documented; `form:` tags are not a format
authority; Japanese covers are thin; licence is unnamed so attribute it.

---

## 2. NDL Search (国立国会図書館サーチ) — SRU

Replaces: **#1**, specifically the Japanese-original half, including
**forthcoming releases**.

### Endpoint tested

```bash
curl -A "MangaBakaResearch/1.0" \
  'https://ndlsearch.ndl.go.jp/api/sru?operation=searchRetrieve&recordSchema=dcndl&recordPacking=xml&maximumRecords=3&query=title%3D%22%E4%BF%BA%E3%81%A0%E3%81%91%E3%83%AC%E3%83%99%E3%83%AB%E3%82%A2%E3%83%83%E3%83%97%E3%81%AA%E4%BB%B6%22%20AND%20mediatype%3Dbooks'
```

Parsed (Solo Leveling, Japanese edition):

```
total: 27
 * 俺だけレベルアップな件外伝　01 | series= MFC | issued= 2026-09-18 | isbn= ['9784046604873'] | pub= ＫＡＤＯＫＡＷＡ
 * 俺だけレベルアップな件. 10     | series= MFC | issued= 2022       | isbn= ['978-4-04-681635-1'] | pub= KADOKAWA | genre= ['漫画']
 * 俺だけレベルアップな件. 11     | series= MFC | issued= 2023       | isbn= ['978-4-04-682287-1'] | pub= KADOKAWA | genre= ['漫画']
```

Note the first row: **`issued= 2026-09-18` is a future date.** NDL ingests
forthcoming-title (近刊) records, so it carries next-volume release dates —
the closest thing in this family to the Naver "what's next" signal, for print
volumes rather than chapters.

Raw `dcndl` record (Apothecary query) confirms the field set:
`dcterms:title`, `dc:title` with `dcndl:transcription` (kana reading, useful for
matching), `dcterms:publisher/foaf:Agent/foaf:name`, `dcterms:issued`
(W3CDTF), `dcterms:identifier` typed `ISBN`/`JPNO`/`NDLBibID`,
`dcndl:seriesTitle`, `dcndl:volume`, `dcndl:genre`, `dcndl:publicationPlace`.

### Gotchas found the hard way

- `recordPacking=xml` is **required**, otherwise `recordData` comes back as an
  escaped string and every XML parse returns zero records. Cost me a run.
- `mediatype="1"` → `illegal mediaType value`. The working value is
  **`mediatype=books`**, unquoted. Without it, the Apothecary query returned CD
  and soundtrack records (`愛は薬` by wacci, Sony Music Labels) among the books.
- `title=` is a **loose keyword match**, not a phrase match. `title="ダンジョン飯"`
  returned 37 records of which the top hits were
  `引退したSランク冒険者は辺境でダンジョン飯を作ることにした` (an unrelated light
  novel), a recipe book and an anime guidebook. **Any integration must
  post-filter on publisher + series + genre**, or it will show the wrong books.

### Coverage, measured

Searched in Japanese, as the brief instructed. Record counts (books only):
薬屋のひとりごと 84 · ダンジョン飯 37 · 俺だけレベルアップな件 27 · ONE PIECE 2593
(all mediatypes, unfiltered). All present. The Beginning After The End has no
Japanese print edition to find — correctly absent, not a failure.

### Auth, limits

- **Keyless.**
- Documented: concurrent-request limits enforced, **no published numeric
  threshold**; large-scale continuous access may be blocked. Observed: sequential
  requests fine, no 429 seen.

### Licence — **this is the flag**

NDL's API help states non-commercial use needs no application, but
**commercial use requires prior approval from NDL *and* from the relevant data
providers**, and credit is mandatory. Some metadata is CC BY 4.0; provider
conditions vary per the 提供対象データプロバイダ一覧.

An App Store app is a judgement call — free and ad-free is arguably
non-commercial, paid or ad-supported is not. **I am not sure this clears, and I
am not going to guess.** If the app is free with no IAP and no ads, I would
ship it with a 国立国会図書館サーチ credit. If it monetises, file the
利用申請 first. Worth asking the owner which the app will be before building on it.

### Apple risk

**None.** A national library catalogue. No 5.2.3 surface.

### Verdict — **build on it for Japanese volumes**, subject to the
commercial-use question above. Best-in-family for JP release dates including
forthcoming ones, and it has a genuine format field.

---

## 3. Wikidata (SPARQL) — the format authority

Replaces: **#1**, partly — as a *discriminator and spine*, not as a volume list.

### Endpoint tested

```bash
curl -G -A "MangaBakaResearch/1.0" --data-urlencode "query@wd4.rq" \
  -H 'Accept: application/sparql-results+json' 'https://query.wikidata.org/sparql'
```

```
Q20016948  Delicious in Dungeon       | manga series       | P577 count: 13  | P2635: 14
Q28667972  One Piece                  | manga series       | P577 count: 112 | P2635: 111
Q65551313  Solo Leveling              | novel series       | P577 count: 0   | P2635: 14
Q106090656 The Apothecary Diaries     | manga series       | P577 count: 0   | P2635: 17
Q48751907  The Apothecary Diaries     | light novel series | P577 count: 0   | P2635: -
Q106090452 The Apothecary Diaries     | novel series       | P577 count: 1   | P2635: -
```

All five present. **The three Apothecary items are separate, typed items** —
that is the clean solve for the matcher problem, and nothing else in this family
does it as well.

### Coverage, measured — and where it breaks

`P2635` (number of parts) is present for 4 of 5: One Piece 111, Apothecary manga
17, Solo Leveling 14, Delicious in Dungeon 14. **TBATE has neither.**

`P577` (publication date) is bimodal and that is the killer for need #1:
One Piece 112 distinct dates (essentially per-volume), Delicious in Dungeon 13,
**and zero for Solo Leveling, Apothecary manga, and TBATE.** So it gives
per-volume dates for exactly the series that already have them everywhere else.

**No per-volume ISBNs.** A `P212` (ISBN-13) sample across all five returned
`none` on every row — Wikidata models these as series items, not edition items.

### Query cost — a real operational finding

My first query used `?item rdfs:label ?l . FILTER(STR(?l) = ?s)` to match titles.
It **timed out with HTTP 504 (`upstream request timeout`)** — an unbounded label
scan. Rewriting it to bind `VALUES ?l { "…"@en }` and constrain `wdt:P31` first
returned in about a second. **Practical impact: WDQS is not safe for live
per-series lookup from a phone unless queries are pre-shaped and pinned.** Given
that, the right use is a **bundled dump**: one SPARQL run at build time
producing a manga/manhwa series table (QID, type, volume count, MangaBaka/AniList
cross-ids) shipped with the app. That fits the existing offline-index pattern and
sidesteps the timeout entirely.

### Licence

**CC0 1.0.** No attribution required. The only unencumbered source in this family.

### Apple risk

**None.**

### Verdict — **build on it, as a bundled format/identity table, not a live API.**
It will not give you volume release dates or ISBNs. It will tell you, reliably
and for free, that the Apothecary manga and the Apothecary light novel are two
different things — which the brief says is worth more than coverage.

Wikipedia's REST API was sanity-checked alongside
(`/api/rest_v1/page/summary/The_Apothecary_Diaries` → 200, and it hands back
`"wikibase_item":"Q48751907"`, a free bridge from an English title to the
Wikidata QID). Useful as a lookup helper; carries no volume data itself.

---

## 4. openBD — Japanese publishing-industry bibliographic API

Replaces: **#1** enrichment for Japanese ISBNs. **Cannot search.**

### Endpoint tested

```bash
curl 'https://api.openbd.jp/v1/get?isbn=9784047301535,9784088725093'
```

```
9784047301535 | ダンジョン飯 = DELICIOUS IN DUNGEON. 1 | vol:  | series: BEAM COMIX      | KADOKAWA | 201501 | cover: False
9784088725093 | One piece 巻1                        | vol:  | series: ジャンプ・コミックス | 集英社    | 199712 | cover: False
```

Full ONIX 3.0 payload per record (`DescriptiveDetail`, `PublishingDetail`,
`ProductSupply` with JPY price), plus a flattened `summary`.

**Batch lookup works** — comma-separated ISBNs in one request, which matters for
a whole series.

### The limitations that decide it

- **ISBN-only. There is no search endpoint.** openBD can only enrich ISBNs you
  already hold, from Open Library or NDL. It is a second hop, never a first.
- `summary.volume` was **empty on every manga record tested**. The volume number
  lives inside the title string (`ダンジョン飯 = DELICIOUS IN DUNGEON. 1`,
  `One piece 巻1`) and would have to be parsed out — and the format varies
  between publishers (`. 1` vs `巻1`).
- `summary.cover` was **empty on all three manga ISBNs tested**. KADOKAWA,
  Shueisha and Square Enix are not supplying cover images here. Does **not**
  solve need #3.
- `pubdate` is `YYYYMM` — month precision, no day.
- **No format field.** Fails the Apothecary test except by imprint inference.

### Bulk coverage list

```bash
curl -o cov.json -w 'HTTP %{http_code} bytes %{size_download}\n' https://api.openbd.jp/v1/coverage
→ HTTP 200 bytes 30981937   (1,936,371 ISBNs)
```

A 31 MB **ISBN list only** — no metadata, so it tells you whether an ISBN is
covered, not what it is. Not a shippable dump in itself.

### Auth, limits, licence

Keyless, no documented rate limit, no observed throttling. openBD publishes its
data for free reuse by the Japanese book trade; the ONIX records originate from
publishers and JPRO.

### Apple risk

**None.**

### Verdict — **keep as an enrichment fallback, second hop only.**
Genuinely good Japanese publisher/imprint/price data, arriving too late to be
useful for discovery, with the volume number in the wrong place and no covers.

---

## 5. Deutsche Nationalbibliothek (DNB) — SRU

Replaces: **#1**, German editions only.

```bash
curl -A "MangaBakaResearch/1.0" \
  'https://services.dnb.de/sru/dnb?version=1.1&operation=searchRetrieve&recordSchema=MARC21-xml&maximumRecords=3&query=tit%3D%22Delicious%20in%20Dungeon%22'
```

Parsed MARC:

```
245: [{'a': 'Delicious in dungeon', 'n': '13', 'c': 'Ryoko Kui ; aus dem Japanischen von Claudia Peter'}]
020: [{'a': '9783755501190', '9': '978-3-7555-0119-0'}]
264: [{'a': 'Berlin', 'b': 'Egmont Verlagsgesellschaften mbH', 'c': '2024'}]
```

**`245$n` = `13` is a clean, parsed volume number** — the only source in this
family that hands it over as its own subfield rather than buried in a title string.

Record counts (`tit="…"`): One Piece 833 · Apothecary Diaries 141 ·
Solo Leveling 136 · Delicious in Dungeon 28 · Beginning after the End 20.
**All five present.** Note `tit="Apothekarin"` → 0; the German editions use the
English title, so no German-title translation step is needed.

- **Auth:** keyless. MARC21-xml works without a token.
- **Rate limits:** none documented that I found; none hit.
- **Format discriminator:** MARC `655` (genre) was **absent on every record
  pulled**. Fails the Apothecary test.
- **Date precision:** `264$c` is a **year only**. No month, no day.
- **Licence:** DNB titledata is generally CC0; not separately re-verified here,
  so confirm before relying on it in a credits screen.
- **Apple risk:** none.

### Verdict — **keep as a fallback** for German editions and, specifically,
as the best available source of a *machine-readable volume number* when Open
Library's title string is ambiguous. Not a primary: year-only dates and no
format field.

---

## 6. Bibliothèque nationale de France (BnF) — SRU

```bash
curl -A "MangaBakaResearch/1.0" \
  'https://catalogue.bnf.fr/api/SRU?version=1.2&operation=searchRetrieve&recordSchema=dublincore&maximumRecords=1&query=bib.title%20all%20%22Gloutons%20et%20Dragons%22'
```

```
<dc:identifier>http://catalogue.bnf.fr/ark:/12148/cb45385382j</dc:identifier>
<dc:title>Gloutons &amp; dragons / Ryoko Kui</dc:title>
<dc:creator>Kui, Ryōko. Auteur du texte</dc:creator>
<dc:publisher>Casterman (Paris)</dc:publisher>
<dc:date>2017</dc:date>
<dc:description>Collection : Sakka</dc:description>
<dc:type xml:lang="eng">printed text</dc:type>
```

Counts: One Piece 667 · Les Carnets de l'apothicaire 51 · Solo Leveling 35 ·
The Beginning after the End 33 · Gloutons et Dragons 2.

- **Auth:** keyless. **Rate limits:** none documented; none hit.
- **The killer:** the `dublincore` record carries **no ISBN, no volume number,
  and a year-only date**. `dc:type` is `printed text` — no manga/novel
  distinction. Everything the brief asks for is missing from the response.
- French editions are retitled (*Gloutons & dragons*, *Les Carnets de
  l'apothicaire*), so **you must already know the French title to search** —
  which means you need another source first, and if you had it you would not
  need BnF.
- **Apple risk:** none.

### Verdict — **reject for now.** Failed on field content, not on access.
Richer InterXMarc schemas exist on the same endpoint and might carry ISBNs;
that is the one retest worth doing if French editions ever become a priority.
Recording the reason so nobody re-proposes it blind.

---

## Rejected, with the test that killed each

### Library of Congress — **reject (transport)**
- `https://www.loc.gov/books/?q=one+piece&fo=json` → **HTTP 403**
- `https://www.loc.gov/search/?q=one+piece+oda&fo=json` with a browser UA → **HTTP 403**
- `https://id.loc.gov/search/?q=one+piece&format=json` → 200 (authorities only, no editions)
- `http://lx2.loc.gov:210/LCDB?...&query=bath.title="one piece"` → **200, 449 records**
- Same URL over **`https://lx2.loc.gov:210` → HTTP 000 (no TLS listener)**

The only endpoint that returns bibliographic records is **plain HTTP on port
210**. Shipping that means an **ATS exception in `Info.plist`**, which is a
justification we would have to write for App Store review in order to reach a
source that DNB and Open Library already cover for English-language editions.
Not worth it. **Killed by: no TLS.**

### National Library of Korea (NLK) — **reject (key)**
```bash
curl 'https://www.nl.go.kr/NL/search/openApi/search.do?key=TEST&kwd=나%20혼자만%20레벨업&apiType=json'
→ {"errorCode":"011","errorMsg":"INVALID KEY:인증키값이 유효하지 않습니다."}
```
Requires a registered key. Free, but it is a **single shared key in a shipped
binary**, which is exactly the liability that removed Google Books, and NLK
issues keys per registered service with per-key quotas. **Killed by: key model.**
Worth revisiting only if manhwa print volumes become a priority and someone is
willing to own the key — it is the only real source for Korean 단행본 dates.

### Rakuten Books / Rakuten Kobo — **reject (rate limit × key)**
```bash
curl 'https://app.rakuten.co.jp/services/api/BooksBook/Search/20170404?format=json&title=ダンジョン飯'
→ {"error_description":"specify valid access token","error":"invalid_token"}
```
Needs an `applicationId`. The brief said check whether it can be shipped. It
cannot, and the reason is arithmetic, not legal: Rakuten documents
**1 request per second per `applicationId`**. One ID embedded in a shipped app
is one request per second *across the entire user base*. The app already runs
30/min and 180/min windows for a single user. **Killed by: a global 1 req/s
ceiling.** Rate-limit relief exists but is granted to large affiliate sites on
application. Account limit is 5 IDs, which does not change the maths.

### WorldCat (OCLC) — **reject (auth)**
```bash
curl -o /dev/null -w '%{http_code}' 'https://americas.discovery.api.oclc.org/worldcat/search/v2/bibs?q=one+piece'
→ 401
```
OAuth2 client-credentials, issued to **OCLC member institutions**. No public
tier. Requires a client secret, which cannot live in an app binary even if we
qualified. **Killed by: institutional auth.** Not retestable without membership.

### ISBNdb — **reject (paid)**
```bash
curl -o /dev/null -w '%{http_code}' 'https://api2.isbndb.com/book/9784047301535'
→ 401
```
API-key auth, **paid subscription tiers only, no free tier**. The pricing page
(`isbndb.com/apidocs/v2`) returned **403 to automated fetch**, so I could not
capture current prices and am not going to quote remembered figures. Recording
it as: paid, key-in-binary, price unverified. **Killed by: paid + key model.**

### Bookshop.org — **reject (no public API)**
```bash
curl -o /dev/null -w '%{http_code}' 'https://bookshop.org/api/v1/books/9784047301535'
→ 403
```
No documented public bibliographic API; the affiliate programme is a link
generator, not a data source. **Killed by: no API.**

---

## What this family does *not* solve

**Need #2 — "when is the next chapter out."** Nothing here answers it, and the
reason is structural: libraries and ISBN registries catalogue *books*, and a
weekly web chapter has no ISBN and is never deposited. The closest approximation
found is **NDL's forthcoming-title records** (`issued= 2026-09-18` on a volume
not yet published), which gives *next print volume* rather than *next chapter*.
That is a different, weaker promise than the one Naver used to underwrite, and
the UI copy would have to change to match it — saying "next volume" where it
used to say "next episode". Flagging that rather than letting it pass as a fix.

**Need #3 — covers.** Partly. Open Library covers are good for English editions
and roughly one-in-three for Japanese ones (2 of 3 spot-checks 404'd). openBD,
the source that *should* have Japanese covers, returned an empty `cover` field on
every manga ISBN tested. The gap for Japanese-edition covers is still open.

---

## Recommended shape

1. **Wikidata (bundled table)** decides *what a series is* — manga vs light
   novel vs novel — and supplies volume counts. CC0, no runtime dependency,
   no timeout risk.
2. **Open Library search + editions** supplies the edition rows: ISBNs,
   publishers, languages, covers, dates. Live, keyless, ≥2 s between calls,
   descriptive User-Agent, attribution displayed.
3. **NDL** supplies Japanese volumes and forthcoming dates — *pending the
   commercial-use question*, which needs an answer from the owner before any
   code is written against it.
4. **openBD** enriches Japanese ISBNs already in hand. **DNB** is the tiebreak
   for a volume number Open Library left ambiguous.

## Open questions for the owner

- **Will the app be free and ad-free?** NDL's terms turn on it, and NDL is the
  best Japanese source found. A wrong guess here means either an unnecessary
  application or an unlicensed dependency.
- **Is "next print volume" an acceptable substitute for "next chapter"** in the
  UI, given nothing in this family can deliver the latter?
- If manhwa print volumes matter, **is anyone willing to own an NLK key**? It is
  the only Korean route, and it fails our shipped-key rule as things stand.

## Not retested / unverified

- DNB's data licence (assumed CC0 from general knowledge; **not confirmed** on
  this pass — confirm before putting it in a credits screen).
- ISBNdb current pricing — pricing page 403'd to automated fetch.
- BnF's richer InterXMarc schemas, which may carry the ISBNs the `dublincore`
  schema lacks. One retest, only if French editions become a priority.
- Open Library's real sustained rate ceiling. Observed resets at ~1 req/1.5 s
  contradict the documented 1 req/s; I did not characterise it further to avoid
  hammering them.

## Open Library covers for coverless ANN rows — measured 2026-09-15, not wired

The question from the Omniscient Reader page (13 ANN rows, no cover art):
would Open Library's cover-by-ISBN fill them? Counted volume-like search
docs with a `cover_i`, five series, one query each:

| Series | volume-like docs | with a cover |
|---|---|---|
| Solo Leveling | 52 | 14 (27%) |
| Chainsaw Man | 42 | 34 (81%) |
| Dandadan | 4 | 0 |
| The Apothecary Diaries | 13 | 0 |
| Tower of God | 22 | 14 (64%) |
| Omniscient Reader's Viewpoint (09-14) | 9 | 1 |

Two of six clear 50%; three are 0–11%. A shelf with a third of its covers
reads as broken, not as partial, so this stays unwired. Revisit if a
per-ISBN check (`covers.openlibrary.org/b/isbn/<isbn>-M.jpg?default=false`,
one HEAD per row) is acceptable — that would show only the covers that
exist, at one request per volume.
