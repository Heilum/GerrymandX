#!/usr/bin/env python3
"""Unwrap geometries that cross the antimeridian in an existing database.

Alaska's Aleutian Islands run past 180° W: the Near Islands (Attu, Shemya,
...) sit at 172°–180° *East*.  In plain longitude they land on the far right
of the map, 350° away from the rest of the state, and the state's extent
becomes 359° wide — the map then fits at a fraction of its size and cannot be
zoomed far enough to see anything.

This shifts every polygon part that lies east of the antimeridian by -360°,
so it sits just west of -180° next to the rest of the chain, and rewrites the
boundary in place.  Stored centres are left alone: they were computed from
the whole geometry and already lie on the -180° side.

Usage:
    .venv/bin/python fix_antimeridian.py data/output/2024-National-President/AK.db [more.db ...]

import_to_sqlite.py applies the same rule (see unwrap_antimeridian) when a
state is (re)built, so this is only needed for databases built before then.
"""

from __future__ import annotations

import hashlib
import sqlite3
import sys
from pathlib import Path

import shapely
from shapely import wkb as shapely_wkb
from shapely.geometry.base import BaseGeometry

# A geometry whose bounds reach both of these is taken to straddle the
# antimeridian rather than to span the globe.
SEAM_WEST = -170.0
SEAM_EAST = 170.0

GEOMETRY_TABLES = ("precincts", "counties", "congressional_districts", "states")


def crosses_antimeridian(geometry: BaseGeometry) -> bool:
    if geometry is None or geometry.is_empty:
        return False
    minx, _, maxx, _ = geometry.bounds
    return minx < SEAM_WEST and maxx > SEAM_EAST


def unwrap_antimeridian(geometry: BaseGeometry) -> BaseGeometry:
    """Move the parts of [geometry] east of 180° to the -180° side.

    Parts entirely in positive longitude are translated by -360°.  A single
    part that itself has vertices on both sides (a ring drawn across the seam)
    has only its positive-longitude vertices shifted, which is the same
    operation vertex by vertex.
    """
    if not crosses_antimeridian(geometry):
        return geometry

    def shift(coords):
        coords = coords.copy()
        east = coords[:, 0] > 0
        coords[east, 0] -= 360.0
        return coords

    return shapely.transform(geometry, shift)


def fix_database(path: Path) -> int:
    db = sqlite3.connect(path)
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    changed = 0
    for table in GEOMETRY_TABLES:
        if table not in tables:
            continue
        rows = db.execute(f"SELECT id, name, boundary FROM {table} WHERE boundary IS NOT NULL").fetchall()
        for row_id, name, blob in rows:
            geometry = shapely_wkb.loads(bytes(blob))
            if not crosses_antimeridian(geometry):
                continue
            fixed = unwrap_antimeridian(geometry)
            db.execute(f"UPDATE {table} SET boundary=? WHERE id=?", (fixed.wkb, row_id))
            changed += 1
            print(f"  {table} #{row_id} {name}: {geometry.bounds[0]:.3f}..{geometry.bounds[2]:.3f}"
                  f" -> {fixed.bounds[0]:.3f}..{fixed.bounds[2]:.3f}", flush=True)
    db.commit()
    if changed:
        db.execute("VACUUM")
    db.close()
    return changed


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    for arg in argv[1:]:
        path = Path(arg)
        print(f"{path}:", flush=True)
        changed = fix_database(path)
        print(f"  {changed} geometries unwrapped; {path.stat().st_size:,} bytes; sha256 {sha256(path)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
