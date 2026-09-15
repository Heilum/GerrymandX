#!/usr/bin/env python3
"""Stamp new_data/new_elections.json with a version, published names and hashes.

    {"version": 202609151630,
     "2024": [{"stateName": "Texas",
               "db": ".../2024/TX-2024-202609151630.db",
               "size": 123456, "sha256": "..."}, ...], ...}

Every database is published under a time-stamped name, `<CODE>-<YEAR>-<stamp>.db`
(`National-<YEAR>-<stamp>.db`), and a database gets a new stamp only when its
content changes.  A changed file therefore lands at a URL the CDN has never
cached and is served at once; only the two fixed entry points —
new_elections.json and each year's manifest.json — need a CDN refresh.

Local files keep their plain build names.  `new_data/published.json` remembers,
per year and state, the hash and name last published, which is how an unchanged
database keeps its name across rebuilds.  Each year's manifest.json gets the
published URLs too.

The app polls new_elections.json: a higher `version` makes it adopt the new
manifest, and every downloaded database whose `sha256` differs is downloaded
again in the background; one whose name alone changed is renamed in place.
Installed apps predating the versioning read only the year keys whose values
are lists, so the extra top-level key and fields are ignored.

Run from this directory after a build (the build scripts also call it):
    .venv/bin/python manifest_version.py
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NEW_DATA = ROOT / "new_data"
NEW_ELECTIONS = NEW_DATA / "new_elections.json"
PUBLISHED = NEW_DATA / "published.json"
CDN_BASE = "https://files.xp-oncology.cn/gerrymander"


def _read_json(path: Path, default):
    return json.loads(path.read_text()) if path.exists() else default


def _write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def published_name(published: dict, year: str, code: str, sha256: str, stamp: str) -> str:
    """The name [code]'s database is published under: the recorded one while
    its content is unchanged, else a fresh `<code>-<year>-<stamp>.db`."""
    key = f"{year}/{code}"
    record = published.get(key)
    if record is None or record["sha256"] != sha256:
        record = {"sha256": sha256, "name": f"{code}-{year}-{stamp}.db"}
        published[key] = record
    return record["name"]


def stamp(path: Path = NEW_ELECTIONS) -> int:
    payload = json.loads(path.read_text())
    previous_version = payload.pop("version", None)
    previous = json.loads(json.dumps(payload))
    published = _read_json(PUBLISHED, {})
    now = datetime.now(timezone.utc).strftime("%Y%m%d%H%M")

    for year, entries in payload.items():
        if not isinstance(entries, list):
            continue
        manifest_path = NEW_DATA / year / "manifest.json"
        manifest = _read_json(manifest_path, None)
        if manifest is None:
            continue
        states = {s["code"]: s for s in manifest.get("states", [])}

        for s in states.values():
            name = published_name(published, year, s["code"], s["sha256"], now)
            s["url"] = f"{CDN_BASE}/{year}/{name}"
        national = manifest.get("national")
        if national:
            name = published_name(published, year, "National", national["sha256"], now)
            national["url"] = f"{CDN_BASE}/{year}/{name}"
        _write_json(manifest_path, manifest)

        for entry in entries:
            code = entry["db"].rsplit("/", 1)[-1].split("-")[0]
            s = states.get(code)
            if s is None:
                entry.pop("size", None)
                entry.pop("sha256", None)
                continue
            entry.update(db=s["url"], size=s["size"], sha256=s["sha256"])

    _write_json(PUBLISHED, dict(sorted(published.items())))

    changed = previous_version is None or payload != previous
    version = max(int(now), (previous_version or 0) + 1) if changed else previous_version
    _write_json(path, {"version": version, **dict(sorted(payload.items(), key=lambda kv: kv[0]))})
    print(f"{path.name}: version {version}" + ("" if changed else " (unchanged)"), flush=True)
    return version


if __name__ == "__main__":
    stamp()
