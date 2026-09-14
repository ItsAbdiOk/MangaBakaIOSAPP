#!/usr/bin/env python3
"""Capture and redact a /v1/my/series/recommendations fixture.

`PersonalRecommendation` and `RecommendationStatus` are decoded only from
hand-built JSON: there is no `Fixtures/*recommend*` file, and because the
endpoint is authenticated the shape sweep does not cover it either. So the
swipe stack is built on the project's own idea of the response, which is
exactly how `library()` broke once — silently, with every test green (review
item 128).

It is not captured automatically because it needs a real personal access
token and returns the reader's own library-derived data. Run it yourself:

    MB_TOKEN=$(grep '^MB_PAT' Configs/Secrets.xcconfig | sed 's/.*= *//') \\
        Scripts/capture-recommendations-fixture.py

It writes MangaBakaTests/Fixtures/recommendations-<date>.json, redacted the
way library.json is: ids renumbered from 1000, titles replaced with
placeholders, every user id "REDACTED". Read the file before committing it —
redaction here is a filter over known keys, and a key nobody anticipated is
precisely what a fixture capture is for.
"""
from __future__ import annotations

import datetime
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

BASE = "https://api.mangabaka.org"
UA = "MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"
ROOT = pathlib.Path(__file__).resolve().parent.parent

# Keys whose values identify the account rather than describe the shape.
USER_KEYS = {"user_id", "userId", "email", "username", "display_name", "name"}
# Keys whose values are free text worth replacing so a fixture cannot leak a
# private note. The shape (string vs null) is preserved.
TEXT_KEYS = {"note", "description", "native_title", "title"}


def redact(node, counter):
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            if key in USER_KEYS and isinstance(value, str):
                out[key] = "REDACTED"
            elif key == "id" and isinstance(value, int):
                out[key] = counter.setdefault(value, 1000 + len(counter))
            elif key in ("series_id", "seriesId") and isinstance(value, int):
                out[key] = counter.setdefault(value, 1000 + len(counter))
            elif key in TEXT_KEYS and isinstance(value, str):
                out[key] = f"Placeholder {key}"
            else:
                out[key] = redact(value, counter)
        return out
    if isinstance(node, list):
        return [redact(item, counter) for item in node]
    return node


def fetch(path: str, token: str):
    request = urllib.request.Request(
        BASE + path,
        headers={"Accept": "application/json", "User-Agent": UA, "x-api-key": token},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    token = os.environ.get("MB_TOKEN", "").strip()
    if not token.startswith("mb-"):
        print("error: set MB_TOKEN to a real personal access token.", file=sys.stderr)
        return 1

    stamp = datetime.date.today().isoformat()
    targets = [
        ("/v1/my/series/recommendations?limit=2", f"recommendations-{stamp}.json"),
        ("/v1/my/series/recommendations/status", f"recommendation-status-{stamp}.json"),
    ]

    for path, name in targets:
        try:
            payload = fetch(path, token)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError,
                json.JSONDecodeError) as error:
            print(f"error: {path}: {error}", file=sys.stderr)
            return 2
        destination = ROOT / "MangaBakaTests" / "Fixtures" / name
        with open(destination, "w", encoding="utf-8") as handle:
            json.dump(redact(payload, {}), handle, indent=1, sort_keys=False)
            handle.write("\n")
        print(f"wrote {destination.relative_to(ROOT)}")

    print()
    print(f"Now add the decode tests, with the provenance line:")
    print(f"  Captured {stamp}: GET {BASE}/v1/my/series/recommendations?limit=2")
    print("Read both files before committing — check nothing personal survived.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
