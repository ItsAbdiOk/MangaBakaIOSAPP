#!/usr/bin/env python3
"""Build MangaBaka/Resources/WikidataIdentity.json.gz from Wikidata.

Run by hand, once per release, like the other bundled data. It is NOT in the
pre-push hook: it depends on a third-party endpoint that returns 502 under load
(observed twice during the 2026-09-14 research pass and once while writing this
script), and a hook that fails because someone else's server is busy is a hook
people learn to skip.

    python3 scripts/generate-wikidata-identity.py

WHAT THIS TABLE IS FOR
----------------------
One job: say what *kind of work* a MangaBaka series is, and what its siblings in
other formats are. The Apothecary Diaries is three separate, separately typed
Wikidata items -- Q106090656 the manga series, Q48751907 the light novel series,
Q106090452 the novel series -- and that structural split is the whole reason
this file exists. The app has already shipped one bug where untagged light
novels filled a comic shelf.

WHAT THIS TABLE IS NOT
----------------------
**It is not a volume-date source, and it must never be built into one.**
Measured 2026-09-14 (docs/sources/datasets.md section 2): of 18,202 Wikidata
manga series, 171 carry per-volume dates via the P577/P478 qualifier modelling
and 79 model volumes as separate dated items -- under 1% either way. Wikidata
also has no per-volume ISBNs on series items (a P212 sample returned none on all
five test series). If you want volume dates, use MangaBaka's own
/v1/series/{id}/works, which hit 100% dated + ISBN on 5 of 5.

LICENCE
-------
Wikidata is CC0 1.0. No attribution required, no share-alike, no
non-commercial clause. Crediting it anyway costs one line in Settings.

FAILING HONESTLY
----------------
Every query here is bounded (VALUES batches or LIMIT/OFFSET pages) because the
research pass's first unbounded label-scan query died with HTTP 504. Any page
that cannot be fetched after RETRIES attempts aborts the whole run and writes
nothing -- a truncated identity table is worse than no table, because the code
reading it cannot tell "this series is not manga" from "this series fell off the
end of a half-finished export".
"""

import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = "MangaBakaIOS/1.0 (https://github.com/mangabaka; identity table build)"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(REPO_ROOT, "MangaBaka", "Resources", "WikidataIdentity.json.gz")

WIRE_VERSION = 1

# WDQS documents a 60 s query timeout and throttles with 429 + Retry-After.
# 1.0 s between requests keeps a whole run (about 50 requests) well inside any
# polite reading of that. Measured 2026-09-14: a 5,000-row scope page returned
# in 0.9 s, so the sleep dominates the runtime, not the endpoint.
SPACING_SECONDS = 1.0
RETRIES = 3
SCOPE_PAGE = 5000
# VALUES batch size for the attribute queries. 750 QIDs per query returned
# comfortably inside the timeout on 2026-09-14; it is a measured-safe figure,
# not a documented limit.
BATCH = 750

# The join keys. MangaBaka's own /v1/series/{id} hands back AniList and
# MangaUpdates ids in its `source` object, so these joins are exact ids, never
# fuzzy title matches -- which is the only reason this table is trustworthy at
# all. Counts measured 2026-09-14 over all of Wikidata:
#   P14262 MangaBaka manga ID      212 items   (brand new property, barely used)
#   P8731  AniList manga ID      8,178 items   <- the workhorse
#   P11149 MangaUpdates manga ID 4,001 items
#   P4087  MyAnimeList manga ID             (carried for diagnostics, not a scope key)
PROP_MANGABAKA = "P14262"
PROP_ANILIST = "P8731"
PROP_MANGAUPDATES = "P11149"
PROP_MYANIMELIST = "P4087"

# P31 (instance of) values, bucketed into the four formats the volumes shelf and
# the Apple Books matcher actually need to tell apart. Built from a measured
# census of every P31 value in scope on 2026-09-14 (60 distinct values; the
# long tail below is anime/film/game and is deliberately left unbucketed).
#
# Anything not listed here gets format "other" and is still stored, because
# "Wikidata knows this item and does not call it a comic" is itself an answer
# the matcher can use -- it is different from "Wikidata has never heard of it".
FORMAT_BY_TYPE = {
    # manga -- 7,207 items in scope
    "Q21198342": "manga",       # manga series (6,993)
    "Q8274": "manga",           # manga (65)
    "Q865484": "manga",         # yonkoma (89)
    "Q21202185": "manga",       # one-shot manga (32)
    "Q114830535": "manga",      # manga anthology (14)
    "Q116505896": "manga",      # manga collection (14)
    "Q1499199": "manga",        # gekiga (1)
    "Q11116488": "manga",       # baseball manga (1)
    "Q470137": "manga",         # original English-language manga (1)
    "Q97379091": "manga",       # comicalize (2)
    "Q137637896": "manga",      # manhua series (40)
    "Q754669": "manga",         # manhua (9)
    "Q137644978": "manga",      # Hong Kong manhua series (9)
    "Q133863495": "manga",      # Taiwanese manhua series (7)
    "Q10915592": "manga",       # Taiwanese comics (1)
    "Q1004": "manga",           # comic (23)
    "Q14406742": "manga",       # comic book series (12)
    "Q1760610": "manga",        # comic book (1)
    "Q838795": "manga",         # comic strip (1)
    # webtoon -- the digital-first Korean side. manhwa is bucketed here rather
    # than under manga: the app's library is 554 Webtoons + 235 Kakao + 228
    # Piccoma titles (docs/sources/datasets.md section 6) and what the shelf
    # needs to know is "this never had a print run", not the country of origin.
    "Q7978994": "webtoon",      # webtoon (173)
    "Q74262765": "webtoon",     # manhwa series (149)
    "Q562214": "webtoon",       # manhwa (9)
    "Q213369": "webtoon",       # webcomic (55)
    # light novel -- the bucket the Apothecary bug is about
    "Q104213567": "lightNovel",  # light novel series (971)
    # novel / prose
    "Q1667921": "novel",        # novel series (24)
    "Q7725634": "novel",        # literary work (89)
    "Q104902491": "novel",      # web novel (South Korea) (49)
    "Q277759": "novel",         # book series (9)
    "Q47461344": "novel",       # written work (4)
    "Q27888335": "novel",       # short story series (1)
    "Q15980953": "novel",       # fiction series (1)
}

# Edges that link an adaptation to its source. P144 points from the adaptation
# to what it is based on; P4969 points the other way. Both are walked, in both
# directions, and the connected component is what gets stored -- because the
# Apothecary manga's only P144 edge is to the light novel, and the novel is one
# more hop out. A reader asking "what else is this story" wants all three.
PROP_BASED_ON = "P144"
PROP_DERIVATIVE = "P4969"

# The app shows exactly two titles: English, and the series' own original
# language. Never a third. So only those two survive into the bundle --
# everything else is dropped here rather than filtered at read time, which
# makes the artefact smaller and means the table cannot answer a question the
# app never asks.
#
# P407 (language of work) census over the whole scope, measured 2026-09-14:
#   Japanese 7,921 | Korean 256 | Chinese (all variants) ~126 | English 30
#   | a 20-item tail of id/es/vi/pt/ru/fr/th
# Chinese variants all collapse to "zh": Wikidata labels are stored under plain
# zh far more often than under zh-Hans/zh-Hant, and the app has one Chinese
# display language, not three.
NATIVE_LANGUAGE_BY_QID = {
    "Q5287": "ja",          # Japanese
    "Q9176": "ko",          # Korean
    "Q632551": "ko",        # Korean dialect
    "Q7850": "zh",          # Chinese
    "Q13414913": "zh",      # Simplified Chinese
    "Q18130932": "zh",      # Traditional Chinese
    "Q727694": "zh",        # Standard Chinese
    "Q262828": "zh",        # Standard Taiwanese Mandarin
    "Q20063795": "zh",      # Hong Kong written Chinese
}
# Items whose original language is English, or anything else not in the map
# above, ship no native title -- there is no second title to show.
LABEL_LANGUAGES = ["en", "ja", "ko", "zh"]

# NEGATIVE RESULT, measured 2026-09-14, recorded so nobody re-proposes it:
# **Wikidata has no romanised title in any typed field.** Over the 8,178 items
# carrying an AniList id, `rdfs:label` in "ja-latn" returned 0 and P2440
# (transliteration) returned 0. Romaji does exist -- "Kusuriya no Hitorigoto",
# "Dungeon Meshi", "Na Honjaman Level-up" are all present -- but only as
# *English aliases* (skos:altLabel @en), sitting unlabelled in the same list as
# alternative English translations ("Apothecary Diaries", "Only I Level Up").
# There is no field that says which alias is the romanisation, so shipping one
# would mean guessing, and a guessed romaji beside a native title is exactly
# the kind of confident-and-wrong the matcher is here to stop. No `ro` field is
# emitted. If the app needs romaji, AniList's `title.romaji` is a typed field
# and MangaBaka already hands us the AniList id.


class QueryFailure(RuntimeError):
    """A query could not be completed. Nothing is written when this escapes."""


def run_query(query, label):
    """POST one bounded SPARQL query, retrying transient failures.

    Raises QueryFailure rather than returning partial data. The research pass
    saw one 502 that succeeded on retry three seconds later, and another while
    this script was being written, so retrying is worth it -- but giving up and
    writing a short table is not.
    """
    body = urllib.parse.urlencode({"query": query}).encode("utf-8")
    last = None
    for attempt in range(1, RETRIES + 1):
        request = urllib.request.Request(
            ENDPOINT,
            data=body,
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/sparql-results+json",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                payload = json.load(response)
            time.sleep(SPACING_SECONDS)
            return payload["results"]["bindings"]
        except (urllib.error.URLError, urllib.error.HTTPError, ValueError, KeyError) as error:
            last = error
            retry_after = 0
            if isinstance(error, urllib.error.HTTPError):
                try:
                    retry_after = int(error.headers.get("Retry-After", "0"))
                except (TypeError, ValueError):
                    retry_after = 0
            wait = max(retry_after, SPACING_SECONDS * (2 ** attempt))
            sys.stderr.write(
                "  %s: attempt %d/%d failed (%s); waiting %.0fs\n"
                % (label, attempt, RETRIES, error, wait)
            )
            time.sleep(wait)
    raise QueryFailure("%s failed after %d attempts: %s" % (label, RETRIES, last))


def qid(uri):
    return uri.rsplit("/", 1)[-1]


def fetch_scope():
    """Every Wikidata item carrying at least one id we can join on.

    Scoping by join key rather than by P31 is deliberate. A P31-scoped query
    would pull all 18,202 manga series, of which roughly half carry no id
    MangaBaka can hand us, so half the table would be unreachable weight. It
    also means the table's reach is a property we can measure honestly (see
    the hit-rate note at the bottom of this file).
    """
    found = []
    offset = 0
    while True:
        query = """
        SELECT DISTINCT ?i WHERE {
          { ?i wdt:%s [] } UNION { ?i wdt:%s [] } UNION { ?i wdt:%s [] }
        } ORDER BY ?i LIMIT %d OFFSET %d
        """ % (PROP_ANILIST, PROP_MANGAUPDATES, PROP_MANGABAKA, SCOPE_PAGE, offset)
        rows = run_query(query, "scope offset=%d" % offset)
        found.extend(qid(row["i"]["value"]) for row in rows)
        sys.stderr.write("  scope: %d items\n" % len(found))
        if len(rows) < SCOPE_PAGE:
            return found
        offset += SCOPE_PAGE
        if offset > 200_000:
            raise QueryFailure("scope paging ran away past 200,000 rows")


def batches(items, size):
    for start in range(0, len(items), size):
        yield items[start:start + size]


def values_clause(qids):
    return " ".join("wd:" + q for q in qids)


def fetch_identifiers(qids, into):
    """P31, the four external ids, and P2635 (number of parts).

    One query per property group rather than one big OPTIONAL-joined query:
    several of these are multi-valued (an item can carry two AniList ids), and
    a single query with six OPTIONALs produces a cartesian product that both
    inflates the response and hides which property is multi-valued.
    """
    for prop, key, numeric in [
        ("P31", "types", False),
        (PROP_MANGABAKA, "mb", True),
        (PROP_ANILIST, "al", True),
        (PROP_MANGAUPDATES, "mu", False),
        (PROP_MYANIMELIST, "ml", True),
        ("P2635", "n", True),
        ("P407", "lang", False),
    ]:
        query = """
        SELECT ?i ?v WHERE { VALUES ?i { %s } ?i wdt:%s ?v }
        """ % (values_clause(qids), prop)
        for row in run_query(query, "%s x%d" % (prop, len(qids))):
            item = qid(row["i"]["value"])
            raw = row["v"]["value"]
            # P31 and P407 come back as entity URIs; everything else is a
            # literal string that happens to be an id.
            value = qid(raw) if prop in ("P31", "P407") else raw
            if numeric:
                try:
                    value = int(float(value))
                except ValueError:
                    continue
            into.setdefault(item, {}).setdefault(key, []).append(value)


def fetch_titles(qids, into):
    """rdfs:label in en/ja/ko/zh, plus P1476 (title).

    All four are fetched because which one is *native* depends on P407, which
    is collected in the same batch; the pruning to English-plus-native happens
    at write time in `build`.

    P1476 is included because it is the *work's own* title statement rather
    than a Wikidata editor's label, and on the Apothecary manga it is the one
    that reads 薬屋のひとりごと.
    """
    query = """
    SELECT ?i ?l WHERE {
      VALUES ?i { %s }
      ?i rdfs:label ?l .
      FILTER(LANG(?l) IN (%s))
    }
    """ % (values_clause(qids), ", ".join('"%s"' % lang for lang in LABEL_LANGUAGES))
    for row in run_query(query, "labels x%d" % len(qids)):
        item = qid(row["i"]["value"])
        language = row["l"].get("xml:lang")
        if language:
            into.setdefault(item, {}).setdefault("ti", {}).setdefault(language, row["l"]["value"])

    query = """
    SELECT ?i ?l WHERE {
      VALUES ?i { %s }
      ?i wdt:P1476 ?l .
      FILTER(LANG(?l) IN (%s))
    }
    """ % (values_clause(qids), ", ".join('"%s"' % lang for lang in LABEL_LANGUAGES))
    for row in run_query(query, "P1476 x%d" % len(qids)):
        item = qid(row["i"]["value"])
        language = row["l"].get("xml:lang")
        if language:
            # P1476 wins over the label: it is the statement, not the editor's
            # display string.
            into.setdefault(item, {}).setdefault("ti", {})[language] = row["l"]["value"]


def fetch_edges(qids, edges):
    """P144 / P4969, collected as undirected pairs."""
    for prop in [PROP_BASED_ON, PROP_DERIVATIVE]:
        query = """
        SELECT ?i ?v WHERE { VALUES ?i { %s } ?i wdt:%s ?v }
        """ % (values_clause(qids), prop)
        for row in run_query(query, "%s x%d" % (prop, len(qids))):
            left = qid(row["i"]["value"])
            right = qid(row["v"]["value"])
            if right.startswith("Q"):
                edges.add((left, right))


def components(edges, members):
    """Connected components over the adaptation edges, union-find.

    Transitive on purpose. The Apothecary manga's only edge is to the light
    novel; the light novel's is to the novel. A reader on the manga page asking
    "what else is this story" wants both, so the component -- not the direct
    neighbours -- is what gets stored.
    """
    parent = {}

    def find(node):
        parent.setdefault(node, node)
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    def union(left, right):
        left_root, right_root = find(left), find(right)
        if left_root != right_root:
            parent[left_root] = right_root

    for left, right in edges:
        if left in members and right in members:
            union(left, right)

    grouped = {}
    for node in parent:
        grouped.setdefault(find(node), []).append(node)
    by_item = {}
    for group in grouped.values():
        if len(group) < 2:
            continue
        ordered = sorted(group, key=lambda q: int(q[1:]))
        for node in ordered:
            by_item[node] = [other for other in ordered if other != node]
    return by_item


def build():
    sys.stderr.write("Scope query...\n")
    scope = fetch_scope()
    if len(scope) < 5_000:
        # 2026-09-14 the three join properties covered 212 + 8,178 + 4,001
        # items. A run that comes back with a fraction of that is the endpoint
        # misbehaving, not Wikidata losing 5,000 manga overnight.
        raise QueryFailure(
            "scope returned only %d items; expected >5,000 (8,178 on 2026-09-14)" % len(scope)
        )

    facts = {}
    edges = set()
    total_batches = (len(scope) + BATCH - 1) // BATCH
    for index, chunk in enumerate(batches(scope, BATCH), start=1):
        sys.stderr.write("Batch %d/%d (%d items)...\n" % (index, total_batches, len(chunk)))
        fetch_identifiers(chunk, facts)
        fetch_titles(chunk, facts)
        fetch_edges(chunk, edges)

    # Siblings that are not themselves joinable still have to be in the table,
    # or "what are this manga's other formats" answers with a bare QID nobody
    # can render. Second pass, same bounded batching.
    extra = sorted(
        {right for _, right in edges} - set(facts),
        key=lambda q: int(q[1:]) if q[1:].isdigit() else 0,
    )
    if extra:
        sys.stderr.write("Sibling pass: %d items not in scope\n" % len(extra))
        for index, chunk in enumerate(batches(extra, BATCH), start=1):
            sys.stderr.write("  sibling batch %d/%d\n" % (index, (len(extra) + BATCH - 1) // BATCH))
            fetch_identifiers(chunk, facts)
            fetch_titles(chunk, facts)

    # Drop sibling-pass items that are not a book format at all. P4969 points
    # at anime, films and video games as readily as at novels, and a shelf that
    # needs to tell a light novel from its manga has no use for the film.
    keep = set()
    for item, fact in facts.items():
        bucket = next(
            (FORMAT_BY_TYPE[t] for t in fact.get("types", []) if t in FORMAT_BY_TYPE), None
        )
        if bucket or item not in extra:
            keep.add(item)

    sibling_map = components({(a, b) for a, b in edges if a in keep and b in keep}, keep)

    rows = []
    for item in sorted(keep, key=lambda q: int(q[1:])):
        fact = facts[item]
        types = fact.get("types", [])
        bucket = next((FORMAT_BY_TYPE[t] for t in types if t in FORMAT_BY_TYPE), "other")
        row = {"q": int(item[1:]), "f": bucket}
        if types:
            row["ty"] = types[0]
        for key in ("mb", "al", "ml", "n"):
            if fact.get(key):
                row[key] = sorted(fact[key])[0]
        if fact.get("mu"):
            row["mu"] = sorted(fact["mu"])[0]
        titles = fact.get("ti", {})
        if titles.get("en"):
            row["en"] = titles["en"]
        # The one native title, chosen by P407 rather than by guessing from
        # which label happens to exist -- an item can carry a Japanese label
        # for a Korean work and often does.
        native_code = next(
            (NATIVE_LANGUAGE_BY_QID[q] for q in fact.get("lang", [])
             if q in NATIVE_LANGUAGE_BY_QID),
            None,
        )
        if native_code and titles.get(native_code):
            row["na"] = titles[native_code]
            row["nl"] = native_code
        if item in sibling_map:
            row["sb"] = [int(q[1:]) for q in sibling_map[item]]
        rows.append(row)

    measured = {
        "rows": len(rows),
        "withMangaBakaID": sum(1 for r in rows if "mb" in r),
        "withAniListID": sum(1 for r in rows if "al" in r),
        "withMangaUpdatesID": sum(1 for r in rows if "mu" in r),
        "withSiblings": sum(1 for r in rows if "sb" in r),
        "withEnglishTitle": sum(1 for r in rows if "en" in r),
        "withNativeTitle": sum(1 for r in rows if "na" in r),
        "manga": sum(1 for r in rows if r["f"] == "manga"),
        "lightNovel": sum(1 for r in rows if r["f"] == "lightNovel"),
        "novel": sum(1 for r in rows if r["f"] == "novel"),
        "webtoon": sum(1 for r in rows if r["f"] == "webtoon"),
        "other": sum(1 for r in rows if r["f"] == "other"),
    }

    # The named case this whole file exists for. If a schema change on
    # Wikidata's side ever breaks the three-way Apothecary split, the generator
    # should refuse to ship rather than quietly emit a table that has stopped
    # answering the question. The Swift side asserts the same thing again
    # against the real bundled bytes (WikidataIdentityTests).
    by_qid = {row["q"]: row for row in rows}
    for expected_qid, expected_format in [
        (106090656, "manga"), (48751907, "lightNovel"), (106090452, "novel")
    ]:
        row = by_qid.get(expected_qid)
        if row is None or row["f"] != expected_format:
            raise QueryFailure(
                "Apothecary control failed: Q%d should be %s, got %s"
                % (expected_qid, expected_format, row["f"] if row else "missing")
            )

    document = {
        "version": WIRE_VERSION,
        "built": date.today().isoformat(),
        "source": "Wikidata SPARQL (query.wikidata.org), CC0 1.0, no attribution required",
        "notAVolumeDateSource": (
            "Measured 2026-09-14: per-volume dates exist for 171 of 18,202 Wikidata "
            "manga series and per-volume ISBNs for none. Use MangaBaka /v1/series/{id}/works."
        ),
        "counts": measured,
        "rows": rows,
    }

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    raw = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    # mtime=0 so re-running on unchanged data produces byte-identical output and
    # does not show up as a diff. GunzipTests already pins the gzip flavour
    # Python's module writes.
    with gzip.GzipFile(OUTPUT, "wb", compresslevel=9, mtime=0) as handle:
        handle.write(raw)

    sys.stderr.write("\n%s\n" % OUTPUT)
    sys.stderr.write("  %d bytes JSON -> %d bytes gzipped\n" % (len(raw), os.path.getsize(OUTPUT)))
    for key, value in measured.items():
        sys.stderr.write("  %-20s %d\n" % (key, value))


if __name__ == "__main__":
    try:
        build()
    except QueryFailure as failure:
        sys.stderr.write("\nABORTED, nothing written: %s\n" % failure)
        sys.exit(1)
