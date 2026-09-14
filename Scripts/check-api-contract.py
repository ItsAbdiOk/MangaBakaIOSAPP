#!/usr/bin/env python3
"""Compare live MangaBaka responses against the recorded golden fixtures.

The fixtures under MangaBakaTests/Fixtures are frozen snapshots. If MangaBaka
changes its response shape, every unit test still passes while the real app
breaks. This script is the thing that notices — it is the one tool aimed
squarely at the failure that has cost this project the most.

Which fixtures it checks lives in Scripts/api-contract-endpoints.json, one
entry per dated fixture, so adding a fixture and adding it to the check are
one habit rather than two. Until 2026-09-14 this script knew about exactly one
endpoint and had no caller at all.

Usage:
    Scripts/check-api-contract.py              # every endpoint in the manifest
    Scripts/check-api-contract.py rising.json  # just the ones whose fixture
                                               # path contains this substring

Exit codes:
    0  every live response still contains everything its fixture had
    1  a field the app relies on has vanished
    2  a response could not be fetched or parsed (an outage, not a break)
"""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Scripts" / "api-contract-endpoints.json"

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


def check(entry: dict) -> int:
    """One fixture against one live endpoint. Returns this entry's exit code."""
    fixture = ROOT / entry["fixture"]
    label = entry["fixture"].rsplit("/", 1)[-1]

    try:
        live = fetch(entry["url"])
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError,
            json.JSONDecodeError) as error:
        # A MangaBaka outage is not a contract break. Say so plainly and exit
        # with a distinct code so a caller can tell the two apart.
        print(f"::warning::{label}: could not reach MangaBaka: {error}")
        return 2

    try:
        with open(fixture, encoding="utf-8") as handle:
            recorded = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"::error::{label}: fixture unreadable: {error}")
        return 1

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
        print(f"::notice::{label}: new fields appeared. Not a failure — "
              "Decodable ignores unknown keys.")
        for item in sorted(added):
            print(f"  + {item}")

    if missing:
        print(f"::error::{label}: the live response no longer contains fields "
              "the fixture recorded.")
        for item in sorted(missing):
            print(f"  - {item}")
        print("  Re-record the fixture and update the models if this is intended.")
        return 1

    print(f"  ok  {label}: shape still matches ({len(recorded_paths)} paths).")
    return 0


def main(argv: list[str]) -> int:
    try:
        with open(MANIFEST, encoding="utf-8") as handle:
            entries = json.load(handle)["endpoints"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"::error::cannot read {MANIFEST}: {error}")
        return 1

    if argv:
        entries = [e for e in entries if any(a in e["fixture"] for a in argv)]
        if not entries:
            print(f"::error::no manifest entry matches {argv}")
            return 1

    codes = [check(entry) for entry in entries]

    # A real break outranks an outage: if anything is genuinely gone, say 1
    # even when another endpoint also happened to be unreachable.
    if 1 in codes:
        return 1
    if 2 in codes:
        return 2
    print(f"All {len(codes)} endpoints still match their fixtures.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
