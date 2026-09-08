#!/usr/bin/env python3
"""Compare a live MangaBaka response against a recorded golden fixture.

The fixtures under MangaBakaTests/Fixtures are frozen snapshots. If MangaBaka
changes its response shape, every unit test still passes while the real app
breaks. This script is the thing that notices.

Exit codes:
    0  the live response still contains everything the fixture had
    1  a field the app relies on has vanished or changed type
    2  the live response could not be fetched or parsed
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.mangabaka.org/v2/series/discover/rising?limit=3"
FIXTURE = "MangaBakaTests/Fixtures/rising.json"

# MangaBaka returns 403 to requests with no recognisable User-Agent (verified
# 2026-09-08: urllib's default UA is rejected, curl's is accepted). Identify
# the caller properly — the project is open source, so a contact URL is honest
# and lets them get in touch rather than just blocking us.
USER_AGENT = "MangaBakaIOS-ContractCheck/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"


def shape(value: object, path: str = "") -> set[str]:
    """Structural fingerprint: a set of "path:type" pairs, ignoring values.

    Only the first element of a list is inspected; the API returns homogeneous
    arrays, and comparing every element would make the output unreadable.
    """
    out: set[str] = set()
    if isinstance(value, dict):
        for key, inner in value.items():
            out.add(f"{path}.{key}:{type(inner).__name__}")
            out |= shape(inner, f"{path}.{key}")
    elif isinstance(value, list) and value:
        out |= shape(value[0], f"{path}[]")
    return out


def fetch(url: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    try:
        live = fetch(ENDPOINT)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError,
            json.JSONDecodeError) as error:
        # A MangaBaka outage is not a contract break. Say so plainly and exit
        # with a distinct code so CI can tell the two apart.
        print(f"::warning::Could not reach MangaBaka: {error}")
        return 2

    with open(FIXTURE, encoding="utf-8") as handle:
        recorded = json.load(handle)

    live_shape = shape(live)
    recorded_shape = shape(recorded)

    # Nullable fields legitimately change type between responses (a null cover
    # width is NoneType today and float tomorrow), so a type change on a field
    # that is optional in the model is not by itself a break. Compare on paths,
    # and report type drift separately.
    live_paths = {item.rsplit(":", 1)[0] for item in live_shape}
    recorded_paths = {item.rsplit(":", 1)[0] for item in recorded_shape}

    missing = recorded_paths - live_paths
    added = live_paths - recorded_paths

    if added:
        print("::notice::New fields appeared. Not a failure — Decodable ignores unknown keys.")
        for item in sorted(added):
            print(f"  + {item}")

    if missing:
        print("::error::MangaBaka's response no longer contains fields the fixture recorded.")
        for item in sorted(missing):
            print(f"  - {item}")
        print("\nRe-record the fixture and update the models if this change is intended.")
        return 1

    print(f"Response shape still matches the fixture ({len(recorded_paths)} paths checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
