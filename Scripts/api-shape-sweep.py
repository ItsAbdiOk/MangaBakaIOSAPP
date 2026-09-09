"""Fetch every endpoint the app decodes and record the JSON type of each field.

The point is to find the divergence class that already cost us the stack twice:
the same logical object coming back with a different JSON type depending on
which endpoint version returned it.
"""
import json, os, sys, time, urllib.request, urllib.error

TOKEN = os.environ.get("MB_TOKEN", "")
BASE = "https://api.mangabaka.org"
UA = "MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"

def get(path):
    req = urllib.request.Request(BASE + path, headers={"User-Agent": UA, "x-api-key": TOKEN})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return {"_http_error": e.code, **json.load(e)}
        except Exception:
            return {"_http_error": e.code}

# path -> how to reach the series-shaped object(s) inside the response
ENDPOINTS = [
    ("/v2/series/discover/rising?limit=3",            "data[]"),
    ("/v2/series/discover/hidden-gems?limit=3",       "data[]"),
    ("/v2/series/search?limit=3&q=berserk",           "data[]"),
    ("/v2/series/2",                                  "data"),
    ("/v2/series/2/similar?limit=3",                  "data[].series"),
    ("/v2/series/2/readers-also-like?limit=3",        "data[].series"),
    ("/v1/series/mix?limit=3&strict=false&series=2",  "data[].series"),
    ("/v1/my/library?limit=3",                        "data[].Series"),
]

def extract(payload, spec):
    node = payload
    for part in spec.split("."):
        if part.endswith("[]"):
            key = part[:-2]
            node = (node.get(key) if isinstance(node, dict) else None) or []
            if not node:
                return []
            node = node[0]
        else:
            node = (node.get(part) if isinstance(node, dict) else None) or {}
    return [node] if node else []

def jtype(v):
    if v is None:
        return "null"
    return {bool: "bool", int: "number", float: "number", str: "string",
            list: "array", dict: "object"}.get(type(v), type(v).__name__)

shapes = {}
for path, spec in ENDPOINTS:
    payload = get(path)
    if "_http_error" in payload:
        print(f"!! {path} -> HTTP {payload['_http_error']} {str(payload.get('message'))[:70]}", file=sys.stderr)
        continue
    found = extract(payload, spec)
    if not found:
        print(f"!! {path} -> nothing at {spec}", file=sys.stderr)
        continue
    obj = found[0]
    fields = {k: jtype(v) for k, v in obj.items()}
    # Cover is the field that already bit us, so record its inner shape too.
    cov = obj.get("cover")
    if isinstance(cov, dict):
        for k, v in cov.items():
            fields[f"cover.{k}"] = jtype(v)
    shapes[path] = fields
    time.sleep(0.4)

json.dump(shapes, open(sys.argv[1], "w"), indent=1, sort_keys=True)

# Report only the fields the app actually models, and only where they disagree.
MODELLED = [
    "id", "state", "merged_with", "titles", "cover", "description", "authors",
    "artists", "status", "rating", "type", "content_rating", "total_chapters",
    "final_volume", "publishers", "anime", "source",
    "cover.raw", "cover.x150", "cover.x250", "cover.x350",
    "cover.blurhash", "cover.width", "cover.height",
]
print(f"{'field':18} " + " ".join(f"{p.split('?')[0][-16:]:>17}" for p in shapes))
for field in MODELLED:
    types = {p: s.get(field, "-") for p, s in shapes.items()}
    present = {t for t in types.values() if t not in ("-", "null")}
    flag = "  <-- DIVERGES" if len(present) > 1 else ""
    if flag or "-" in types.values():
        print(f"{field:18} " + " ".join(f"{t:>17}" for t in types.values()) + flag)
