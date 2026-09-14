#!/usr/bin/env python3
"""Query App Store Connect about builds, without a human reading a dashboard.

Answers the questions that come up constantly during a TestFlight loop: what
number is the latest build, did it pass, which action failed, and what did the
failure actually say.

Credentials are never read into this program's output. The private key is read
from disk, used to sign a short-lived token, and never printed. Configure once:

    export ASC_KEY_ID=XXXXXXXXXX
    export ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    # key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8

or put those two lines in Configs/asc.env (gitignored) and this will read it.

Usage:
    ./Scripts/asc.py status          latest Xcode Cloud runs and their result
    ./Scripts/asc.py builds          TestFlight builds and processing state
    ./Scripts/asc.py why [RUN_ID]    why a run failed, with the real messages
    ./Scripts/asc.py notes [BUILD]   write the build's commit subject into its
                                     TestFlight release notes (default: newest)
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

API = "https://api.appstoreconnect.apple.com/v1"
APP_BUNDLE_ID = "dev.abdirahmanmohamed.mangabaka"


def _b64(raw: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _load_env() -> None:
    """Read Configs/asc.env if the variables are not already set."""
    if os.environ.get("ASC_KEY_ID") and os.environ.get("ASC_ISSUER_ID"):
        return
    env = Path(__file__).resolve().parent.parent / "Configs" / "asc.env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def token() -> str:
    """Sign a 15-minute ES256 token. The key never leaves this function."""
    _load_env()
    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit(
            "error: ASC_KEY_ID and ASC_ISSUER_ID are not set.\n"
            "Put them in Configs/asc.env (gitignored) or export them.\n"
            "See the header of this file."
        )

    candidates = [
        Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8",
        Path.home() / "private_keys" / f"AuthKey_{key_id}.p8",
        Path.home() / f"AuthKey_{key_id}.p8",
    ]
    path = next((p for p in candidates if p.exists()), None)
    if path is None:
        sys.exit(
            f"error: could not find AuthKey_{key_id}.p8.\n"
            "Looked in:\n  " + "\n  ".join(str(p) for p in candidates)
        )

    private_key = serialization.load_pem_private_key(path.read_bytes(), password=None)

    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{_b64(json.dumps(header).encode())}.{_b64(json.dumps(payload).encode())}"

    der = private_key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{_b64(signature)}"


def get(path: str, **params) -> dict:
    url = f"{API}/{path}"
    if params:
        from urllib.parse import urlencode
        url += "?" + urlencode(params)
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:600]
        sys.exit(f"error: App Store Connect returned {error.code}\n{body}")


def send(method: str, path: str, body: dict) -> dict | None:
    """PATCH or POST a JSON:API document. The only writes this program makes."""
    request = urllib.request.Request(
        f"{API}/{path}",
        method=method,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token()}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        body_text = error.read().decode(errors="replace")[:600]
        sys.exit(f"error: App Store Connect returned {error.code}\n{body_text}")


def app_id() -> str:
    apps = get("apps", **{"filter[bundleId]": APP_BUNDLE_ID}).get("data", [])
    if not apps:
        sys.exit(f"error: no app found for bundle id {APP_BUNDLE_ID}")
    return apps[0]["id"]


def cmd_status() -> None:
    """Recent Xcode Cloud runs, newest first.

    Explicitly sorted: the API returns oldest first by default, which hides the
    builds anyone actually asks about.
    """
    products = get("ciProducts").get("data", [])
    product = next(
        (p for p in products if p["attributes"].get("name") in ("MangaBaka", "BakaManga")),
        products[0] if products else None,
    )
    if product is None:
        sys.exit("error: no Xcode Cloud product found for this account.")

    runs = get(f"ciProducts/{product['id']}/buildRuns", limit=10, sort="-number").get("data", [])
    if not runs:
        print("No Xcode Cloud runs yet.")
        return

    print(f"{'BUILD':>6}  {'RESULT':<12} {'STATE':<12} STARTED")
    for run in runs:
        a = run["attributes"]
        print(
            f"{str(a.get('number','?')):>6}  "
            f"{str(a.get('completionStatus') or '-'):<12} "
            f"{str(a.get('executionProgress') or '-'):<12} "
            f"{(a.get('startedDate') or '')[:19]}   id={run['id']}"
        )


def cmd_builds() -> None:
    """TestFlight builds and whether they are usable yet."""
    builds = get(
        f"apps/{app_id()}/builds",
        limit=8,
        **{"fields[builds]": "version,processingState,uploadedDate,expired"},
    ).get("data", [])
    if not builds:
        print("No builds uploaded yet.")
        return

    print(f"{'BUILD':>6}  {'STATE':<12} {'EXPIRED':<8} UPLOADED")
    for build in builds:
        a = build["attributes"]
        print(
            f"{str(a.get('version','?')):>6}  "
            f"{str(a.get('processingState') or '-'):<12} "
            f"{str(a.get('expired')):<8} "
            f"{(a.get('uploadedDate') or '')[:19]}"
        )


def cmd_why(run_id: str | None) -> None:
    """The actual failure messages for a run, rather than 'Build failed'."""
    if run_id is None:
        products = get("ciProducts").get("data", [])
        if not products:
            sys.exit("error: no Xcode Cloud product found.")
        runs = get(f"ciProducts/{products[0]['id']}/buildRuns", limit=10, sort="-number").get("data", [])
        failed = next(
            (r for r in runs if r["attributes"].get("completionStatus") not in (None, "SUCCEEDED")),
            None,
        )
        if failed is None:
            print("No failed run in the last 10. Nothing to explain.")
            return
        run_id = failed["id"]
        print(f"Most recent failure: build {failed['attributes'].get('number')}\n")

    actions = get(f"ciBuildRuns/{run_id}/actions").get("data", [])
    for action in actions:
        a = action["attributes"]
        status = a.get("completionStatus") or a.get("executionProgress")
        print(f"— {a.get('name')}: {status}")
        if status in ("SUCCEEDED", None):
            continue
        issues = get(f"ciBuildActions/{action['id']}/issues", limit=20).get("data", [])
        if not issues:
            print("    (no issues reported; check the log in App Store Connect)")
        for issue in issues:
            ia = issue["attributes"]
            message = " ".join((ia.get("message") or "").split())
            print(f"    [{ia.get('issueType')}] {message[:300]}")


def cmd_notes(wanted: str | None) -> None:
    """Put the commit subject on the TestFlight card.

    TestFlight shows the marketing version, not the build number, so two builds
    of 0.1.0 look identical on the phone — which is exactly how build 82 came to
    look like build 81 on 2026-09-14. The commit subject is the one line that
    already says what changed, so it becomes the release note.

    The Xcode Cloud run number and the build number are the same value (checked
    across runs 80-82), which is what lets the commit be found from the build.
    """
    builds = get(f"apps/{app_id()}/builds", limit=20).get("data", [])
    if wanted:
        build = next((b for b in builds if b["attributes"].get("version") == wanted), None)
        if build is None:
            sys.exit(f"error: no build {wanted} among the newest 20.")
    else:
        build = max(builds, key=lambda b: b["attributes"].get("uploadedDate") or "", default=None)
        if build is None:
            sys.exit("error: no builds uploaded yet.")
    number = build["attributes"].get("version")

    subject = commit_subject(number)
    if subject is None:
        sys.exit(f"error: no Xcode Cloud run numbered {number}, so no commit to quote.")

    localizations = get(f"builds/{build['id']}/betaBuildLocalizations").get("data", [])
    if not localizations:
        # A build Apple has not finished processing has no localization to
        # patch yet; creating one is the same write, with a locale.
        send("POST", "betaBuildLocalizations", {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": "en-GB", "whatsNew": subject},
                "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}},
            }
        })
        print(f"build {number}: created en-GB notes — {subject}")
        return

    for localization in localizations:
        send("PATCH", f"betaBuildLocalizations/{localization['id']}", {
            "data": {
                "type": "betaBuildLocalizations",
                "id": localization["id"],
                "attributes": {"whatsNew": subject},
            }
        })
    locales = ", ".join(loc["attributes"].get("locale", "?") for loc in localizations)
    print(f"build {number}: notes set for {locales} — {subject}")


def commit_subject(build_number: str) -> str | None:
    """The first line of the commit the given build was cut from.

    Read from App Store Connect rather than from local git: the newest local
    commit is not always the one that built, and a note that names the wrong
    change is worse than no note.
    """
    products = get("ciProducts").get("data", [])
    product = next(
        (p for p in products if p["attributes"].get("name") in ("MangaBaka", "BakaManga")),
        None,
    )
    if product is None:
        sys.exit("error: no Xcode Cloud product found for this account.")
    runs = get(f"ciProducts/{product['id']}/buildRuns", limit=25, sort="-number").get("data", [])
    run = next(
        (r for r in runs if str(r["attributes"].get("number")) == str(build_number)), None
    )
    if run is None:
        return None
    message = (run["attributes"].get("sourceCommit") or {}).get("message") or ""
    subject = message.splitlines()[0].strip() if message else ""
    # 4,000 is Apple's ceiling on whatsNew; a subject never reaches it, but a
    # runaway one-line commit message would.
    return subject[:4000] or None


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "status":
        cmd_status()
    elif command == "builds":
        cmd_builds()
    elif command == "why":
        cmd_why(sys.argv[2] if len(sys.argv) > 2 else None)
    elif command == "notes":
        cmd_notes(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
