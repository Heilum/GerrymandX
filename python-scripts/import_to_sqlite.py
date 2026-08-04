#!/usr/bin/env python3
"""Build one election/map SQLite file per state and update National.db.

Run from this directory with the project's virtual environment:
    .venv/bin/python import_to_sqlite.py

Input archives live in data/raw_data and are kept intact; each one is unpacked
into a temporary directory only while that state is being imported.  Output goes
to data/output/<election>/ plus the data/output/dbs.json manifest.

Candidates and parties are *not* stored in the databases any more.  They live in
dbs.json and are identified by deterministic UUIDs (uuid5), so re-running the
import — or rebuilding a single state — always produces the same ids.
"""

from __future__ import annotations

import argparse
import collections
import csv
import io
import json
import re
import shutil
import sqlite3
import tempfile
import uuid
import zipfile
from collections import defaultdict
from pathlib import Path

import geopandas as gpd
import pandas as pd
import shapely
from shapely.ops import unary_union


ROOT = Path(__file__).resolve().parent
INPUT_DIR = ROOT / "data" / "raw_data"
OUTPUT_ROOT = ROOT / "data" / "output"
ELECTION_NAME = "2024-National-President"
ELECTION_DESCRIPTION = "2024 National President Election"
OFFICE = "President"
OUTPUT_DIR = OUTPUT_ROOT / ELECTION_NAME
NATIONAL_DB = OUTPUT_DIR / "National.db"
DB_LIST = OUTPUT_ROOT / "dbs.json"
CDN_BASE = "https://public-assets.peipeixiong.cn/public/jagie/gerrymander"

# Deterministic id namespace.  Never change these strings: doing so invalidates
# every candidate_id already written into a state database.
ID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://gerrymanderx.app/elections")


def party_uuid(code: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{ELECTION_NAME}/party/{code}"))


def candidate_uuid(code: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{ELECTION_NAME}/candidate/{OFFICE}/{code}"))


STATE_NAMES = {
    "ak": "Alaska", "al": "Alabama", "az": "Arizona", "ca": "California",
    "ct": "Connecticut", "de": "Delaware", "fl": "Florida", "ga": "Georgia",
    "ia": "Iowa", "id": "Idaho", "il": "Illinois", "ks": "Kansas",
    "la": "Louisiana", "ma": "Massachusetts", "md": "Maryland", "mo": "Missouri",
    "ms": "Mississippi", "mt": "Montana", "nc": "North Carolina",
    "nd": "North Dakota", "ne": "Nebraska", "nh": "New Hampshire",
    "ny": "New York", "oh": "Ohio", "ri": "Rhode Island", "sc": "South Carolina",
    "tn": "Tennessee", "tx": "Texas", "ut": "Utah", "va": "Virginia",
    "vt": "Vermont", "wa": "Washington", "wi": "Wisconsin", "wv": "West Virginia",
    "wy": "Wyoming",
    # Not present in data/raw_data: VEST's 2024 release is subscriber-only and
    # these archives have not been obtained.  Drop a `xx_2024_gen_*.zip` in and
    # the importer picks it up with no code change.
    "ar": "Arkansas", "co": "Colorado", "hi": "Hawaii", "in": "Indiana",
    "ky": "Kentucky", "me": "Maine", "mi": "Michigan", "mn": "Minnesota",
    "nv": "Nevada", "nj": "New Jersey", "nm": "New Mexico", "ok": "Oklahoma",
    "or": "Oregon", "pa": "Pennsylvania", "sd": "South Dakota",
}

# Party code -> (display name, ARGB colour).  The colours mirror the palette in
# lib/modules/elections/widgets/map/map_painters.dart.
PARTIES = {
    "DEM": ("Democrat", 0xFF2166AC),
    "REP": ("Republican", 0xFFB2182B),
    "LIB": ("Libertarian", 0xFFFFC107),
    "GRN": ("Green", 0xFF4CAF50),
    "IND": ("Independent", 0xFF9E9E9E),
    "WRI": ("Write-In", 0xFF757575),
    "OTH": ("Other", 0xFF616161),
}
# VEST column party letter -> party code.
PARTY_LETTERS = {"D": "DEM", "R": "REP", "L": "LIB", "G": "GRN",
                 "I": "IND", "W": "WRI", "O": "OTH"}

# VEST candidate code -> (display name, canonical party).  States list the same
# person on different ballot lines (Oliver is Libertarian in most states but
# Independent in Alabama), so the party here is the candidate's national one,
# not whatever letter a single state's column happened to use.  Codes missing
# from this table fall back to the code itself as the name and to the party
# letter of the column they came from.
CANDIDATES = {
    "HAR": ("Harris", "DEM"),
    "TRU": ("Trump", "REP"),
    "OLI": ("Oliver", "LIB"),
    # South Carolina labels the Libertarian line by first name (G24PRELCHA).
    "CHA": ("Chase Oliver", "LIB"),
    "STE": ("Stein", "GRN"),
    "KEN": ("Kennedy", "IND"),
    "WES": ("West", "IND"),
    "CRU": ("De la Cruz", "IND"),
    "TER": ("Terry", "IND"),
    "SON": ("Sonski", "IND"),
    "FRU": ("Fruit", "IND"),
    "AYY": ("Ayyadurai", "IND"),
    "DUN": ("Duncan", "IND"),
    # These five were opaque three-letter VEST codes until the MEDSL returns,
    # which carry full names, identified them.
    "BOW": ("Bowman", "IND"),
    "KIE": ("Kishore", "IND"),
    "FOX": ("Fox", "OTH"),
    "MCN": ("McNeil", "OTH"),
    "POT": ("Future Madam Potus", "OTH"),
    "PRE": ("PRE", "OTH"),
    # Only appear in the MEDSL returns.
    "GAR": ("Garrity", "OTH"),
    "SKO": ("Skousen", "OTH"),
    "HUB": ("Huber", "OTH"),
    "WOO": ("Wood", "OTH"),
    "SOD": ("Soderna", "OTH"),
    "EBK": ("Ebke", "OTH"),
    "CHE": ("Cheng", "OTH"),
    "KEL": ("Kelly", "OTH"),
    "JOH": ("Johnson", "OTH"),
    # Nevada is the only state with a formal "none of the above" ballot line.
    "NOT": ("None of These Candidates", "OTH"),
    "WRI": ("Write-In", "WRI"),
    "OTH": ("Other", "OTH"),
}

# MEDSL reports full candidate names; map them onto the codes above.
MEDSL_CANDIDATES = {
    "DONALD J TRUMP": "TRU", "KAMALA D HARRIS": "HAR", "JILL STEIN": "STE",
    "CHASE OLIVER": "OLI", "ROBERT F KENNEDY": "KEN", "ROBERT F KENNEDY JR": "KEN",
    "CORNEL WEST": "WES", "RANDALL TERRY": "TER", "CLAUDIA DE LA CRUZ": "CRU",
    "PETER SONSKI": "SON", "SHIVA AYYADURAI": "AYY", "JOSEPH KISHORE": "KIE",
    "RACHELE FRUIT": "FRU", "JAY J BOWMAN": "BOW", "CHERUNDA LYNN FOX": "FOX",
    "CHERUNDA FOX": "FOX", "ANDRE RAMON MCNEIL": "MCN", "FUTURE MADAM POTUS": "POT",
    "NONE OF THESE CANDIDATES": "NOT", "CHRIS GARRITY": "GAR", "JOEL SKOUSEN": "SKO",
    "BLAKE HUBER": "HUB", "MICHAEL WOOD": "WOO", "JAMES D SODERNA": "SOD",
    "LAURA EBKE": "EBK", "JOHN CHENG": "CHE", "BILLY KELLY": "KEL",
    "NALA BAOZUN SCOTT JOHNSON JR": "JOH", "OTHERS": "OTH",
}

# Ballot-accounting rows that sit in MEDSL's candidate column but are not
# candidates.  Matched as a substring, since the wording varies by state.
MEDSL_ACCOUNTING = re.compile(
    r"TOTAL|OVERVOTE|UNDERVOTE|BALLOTS CAST|CAST VOTES|CONTEST|INVALID|BLANK|SCATTER")

# Wisconsin publishes party totals instead of named candidate columns.
WI_PARTY_CANDIDATE = {"DEM": "HAR", "REP": "TRU", "LIB": "OLI", "GRN": "STE",
                      "WRI": "WRI", "OTH": "OTH"}
AT_LARGE_STATES = {"AK", "DE", "ND", "SD", "VT", "WY"}

# Coordinate grid, in degrees, that vertices are snapped to (~1.1 m).  VEST's
# California layer carries sub-metre vertex spacing — 1.6 M vertices for a
# single county, ~100x any other state — which is far more detail than the map
# can draw and makes recording it painfully slow.  Snapping is preferable to
# simplify() here: neighbouring precincts snap to the same grid points, so
# shared borders stay coincident instead of developing slivers and gaps.  At
# maximum zoom one screen pixel still spans ~30x this grid.
COORD_GRID = 1e-5

# Authoritative state outlines, used for National.db's `states.boundary`.
# Unioning every precinct in a state produces a technically correct but
# unusable outline: 55 MB across 35 states (Maryland alone 12.7 MB), with
# ragged coastlines where precinct edges disagree.  The Census Bureau's
# cartographic boundary file is the reference for US state geometry.
#   https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_state_500k.zip
# Vote totals are never taken from here — only the shape.
STATE_OUTLINES = INPUT_DIR / "cb_2023_us_state_500k.zip"
COUNTY_OUTLINES = INPUT_DIR / "cb_2023_us_county_500k.zip"
CD_OUTLINES = INPUT_DIR / "cb_2023_us_cd118_500k.zip"

# Counties renamed since MEDSL's fips were assigned.
RENAMED_COUNTY_FIPS = {"46113": "46102"}  # Shannon -> Oglala Lakota, SD, 2015

# Source for the states VEST 2024 does not cover.  MIT Election Data + Science
# Lab publishes precinct-level returns with named candidates, parties, county
# fips and — via the US House contest in the same file — each precinct's
# congressional district.  It carries no geometry, which is why precinct
# outlines are looked up separately in the NYT map and are optional.
MEDSL_DIR = INPUT_DIR / "MITdata_PREZ24 copy"
COUSUB_OUTLINES = INPUT_DIR / "cb_2023_us_cousub_500k.zip"
# Census 2020 voting districts, per state, downloaded as needed from
# https://www2.census.gov/geo/tiger/TIGER2020PL/STATE/.  Some states number
# their precincts the same way the Census does, which makes this a direct join.
VTD_DIR = INPUT_DIR / "vtd"

# RDH publishes 2024 precinct results as plain tables, with no geometry — but
# each row carries the Census VTD code for its precinct.  That makes the table
# a crosswalk: it joins to the returns on the precinct id and to the Census VTD
# layer on the VTD code, which is how a precinct gets an outline in states
# where neither source matches the returns directly.
RDH_DIR = INPUT_DIR / "rdh"

# Where a state publishes precinct -> congressional district outright, that
# beats any geometric inference.  Oklahoma's is from the state's own GIS
# portal (OU Center for Spatial Analysis, "Voter Precincts"), cross-checked
# against the Census district polygons before being trusted.
STATE_DISTRICT_LOOKUPS = {"OK": INPUT_DIR / "ok_precinct_congress.json"}

# Official state precinct layers, which beat the NYT map: they carry the
# state's own precinct codes, so they join to the returns directly instead of
# through name matching.  (archive, county field, precinct field, district
# field or None); the county field holds a bare county FIPS.
STATE_PRECINCT_LAYERS = {
    "MN": (INPUT_DIR / "mn_voting_districts.zip", "COUNTYFIPS", "PCTCODE", "CONGDIST"),
}
NYT_DIR = INPUT_DIR / "nyt"

STATE_SCHEMA = """
CREATE TABLE counties (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL);
CREATE TABLE congressional_districts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL);
CREATE TABLE precincts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL, population INTEGER NOT NULL DEFAULT 0);
CREATE TABLE county_precincts (precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE, county_id INTEGER REFERENCES counties(id) ON DELETE CASCADE, PRIMARY KEY(precinct_id, county_id));
CREATE TABLE congressional_district_precincts (precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE, congressional_district_id INTEGER REFERENCES congressional_districts(id) ON DELETE CASCADE, PRIMARY KEY(precinct_id, congressional_district_id));
CREATE TABLE precinct_results (id INTEGER PRIMARY KEY AUTOINCREMENT, precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE, candidate_id TEXT NOT NULL, votes INTEGER NOT NULL DEFAULT 0, UNIQUE(precinct_id, candidate_id));
CREATE TABLE state_regions (id INTEGER PRIMARY KEY AUTOINCREMENT, region_id INTEGER NOT NULL, region_type TEXT CHECK(region_type IN ('county', 'congressional_district')));
CREATE INDEX idx_precinct_results_precinct ON precinct_results(precinct_id);
CREATE INDEX idx_county_precincts_county ON county_precincts(county_id);
CREATE INDEX idx_cd_precincts_district ON congressional_district_precincts(congressional_district_id);
"""

NATIONAL_SCHEMA = """
CREATE TABLE IF NOT EXISTS states (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL, db_name TEXT, vote_summary TEXT);
DROP TABLE IF EXISTS candidates;
DROP TABLE IF EXISTS parties;
-- Each state database now lists its own regions.
DROP TABLE IF EXISTS state_regions;
"""


def register_candidate(code: str, party_letter: str | None) -> str:
    """Return the UUID for a candidate code, learning unknown codes as we go."""
    if code not in CANDIDATES:
        party = PARTY_LETTERS.get(party_letter or "O", "OTH")
        CANDIDATES[code] = (code, party)
        print(f"  ! unknown candidate code {code} (party {party}); "
              f"add it to CANDIDATES for a proper display name", flush=True)
    return candidate_uuid(code)


def columns(frame: gpd.GeoDataFrame) -> dict[str, str]:
    return {str(column).upper(): str(column) for column in frame.columns}


def first_column(frame: gpd.GeoDataFrame, names: list[str]) -> str | None:
    lookup = columns(frame)
    return next((lookup[name] for name in names if name in lookup), None)


def as_text(value: object, fallback: str) -> str:
    if value is None or pd.isna(value) or str(value).strip() == "":
        return fallback
    return str(value).strip()


def as_int(value: object) -> int:
    try:
        if value is None or pd.isna(value):
            return 0
        return max(0, int(float(value)))
    except (TypeError, ValueError):
        return 0


POLYGONAL = {"Polygon", "MultiPolygon"}


def polygonal(geometry):
    """Reduce a geometry to its area, dropping non-polygonal parts.

    Repairing a self-intersecting polygon — and dissolving anything repaired —
    can yield a GeometryCollection whose non-polygonal members are zero-width
    slivers.  The app's WKB reader finds no rings in such a boundary and treats
    the cell as having no geometry at all, which silently drops it from the map
    and stretches the layer's extent towards (0, 0).
    """
    if geometry is None or geometry.is_empty or geometry.geom_type in POLYGONAL:
        return geometry
    parts = [part for part in getattr(geometry, "geoms", []) if part.geom_type in POLYGONAL]
    return unary_union(parts) if parts else None


def wkb(geometry):
    geometry = polygonal(geometry)
    return None if geometry is None or geometry.is_empty else geometry.wkb


def center(geometry):
    if geometry is None or geometry.is_empty:
        return None, None
    point = geometry.centroid
    if not geometry.contains(point):
        point = geometry.representative_point()
    return point.y, point.x


def vector_paths(archive: Path, workdir: Path) -> list[Path]:
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(workdir)
    return sorted(path for path in workdir.rglob("*") if path.suffix.lower() in {".shp", ".geojson", ".json"})


def choose_precinct_path(paths: list[Path]) -> Path:
    ranked = sorted(paths, key=lambda path: (
        "_all_" not in path.stem.lower() and "all_prec" not in path.stem.lower(),
        "cong" in path.stem.lower(), "sld" in path.stem.lower(), len(path.parts), str(path)))
    if not ranked:
        raise ValueError("archive contains no Shapefile or GeoJSON")
    return ranked[0]


def president_columns(frame: gpd.GeoDataFrame) -> list[tuple[str, str]]:
    """Return [(source column, candidate code)] for 2024 president.

    Several columns can map to the same code (Wisconsin's eight independent
    lines all collapse into "Other"), so this is a list, not a dict — the caller
    sums them instead of letting the last column win.
    """
    result: list[tuple[str, str]] = []
    for original in frame.columns:
        name = str(original).upper()
        # Typical VEST field: G24PREDHAR, G24PRERTRU, etc.
        match = re.fullmatch(r"G24PRE([DRLGIWO])([A-Z0-9]{3,})", name)
        if match:
            code = match.group(2)[:3]
            register_candidate(code, match.group(1))
            result.append((str(original), code))
            continue
        # Wisconsin-style party aggregate columns: PREDEM24, PREREP24, ...
        match = re.fullmatch(r"PRE(DEM|REP|LIB|GRE|CON|WGR|NP\d*|IND\d*)24", name)
        if match:
            token = match.group(1)
            party = {"DEM": "DEM", "REP": "REP", "LIB": "LIB", "GRE": "GRN",
                     "WGR": "WRI"}.get(token, "OTH")
            result.append((str(original), WI_PARTY_CANDIDATE[party]))
    return result


# Every spelling of the congressional-district field seen across the archives.
DISTRICT_FIELDS = ["CONG_DIST", "CONGDIST", "CONGRESS", "CONGRESSIONAL_DISTRICT",
                   "CD", "USCD", "US_CD", "CD118"]

# A few states carry no district field at all and encode it only in the names of
# the US House vote columns — GCON07DDAV is district 7.  A precinct has House
# votes for exactly one district, so the district follows from which of those
# columns are populated.
HOUSE_VOTE_COLUMN = re.compile(r"^GCON(\d+)[A-Z]", re.I)


def district_values(frame: gpd.GeoDataFrame) -> pd.Series | None:
    field = first_column(frame, DISTRICT_FIELDS)
    return None if field is None else frame[field]


def districts_from_vote_columns(frame: gpd.GeoDataFrame, code: str) -> pd.Series | None:
    """Derive the district from which US House vote columns are populated."""
    groups: dict[str, list[str]] = {}
    for column in frame.columns:
        match = HOUSE_VOTE_COLUMN.match(str(column))
        if match:
            groups.setdefault(str(int(match.group(1))), []).append(column)
    if not groups:
        return None
    populated = {label: frame[columns].fillna(0).astype(float).gt(0).any(axis=1)
                 for label, columns in groups.items()}
    counts = sum(populated.values())
    labels = []
    for index in range(len(frame)):
        if counts.iloc[index] != 1:
            labels.append(None)
            continue
        labels.append(next(label for label, mask in populated.items() if mask.iloc[index]))
    resolved = sum(1 for label in labels if label)
    print(f"[{code}] district taken from {len(groups)} US House vote columns: "
          f"{resolved}/{len(frame)} precincts resolved", flush=True)
    return pd.Series(labels, index=frame.index)


def districts_from_congressional_layer(base: gpd.GeoDataFrame, paths: list[Path]) -> pd.Series | None:
    """Use the companion *_cong_prec layer when the all-precinct layer lacks CD."""
    congressional = [path for path in paths if "cong" in path.stem.lower()]
    if not congressional:
        return None
    layer = gpd.read_file(congressional[0])
    district = district_values(layer)
    if district is None:
        return None
    for field_name in ["UNIQUE_ID", "GEOID", "VTD", "VTDST", "PRECINCT", "PRECINCTNA", "LABEL"]:
        base_field = first_column(base, [field_name])
        layer_field = first_column(layer, [field_name])
        if base_field and layer_field:
            mapping = dict(zip(layer[layer_field].astype(str), district.map(normalize_district)))
            values = base[base_field].astype(str).map(mapping)
            if values.notna().any():
                return values
    return None


# VEST splits a precinct that straddles districts into one row per portion in
# the companion *_cong_prec layer, named "<base id>-(CONG-NN)".  A plain name
# join against the all-precinct layer therefore misses exactly those precincts,
# which is why they ended up with no district at all.
CONG_SPLIT_SUFFIX = re.compile(r"^(.*?)[-_ ]*\((?:CONG|CD)[-_ ]*([0-9A-Za-z]+)\)\s*$", re.I)


def district_memberships(frame: gpd.GeoDataFrame, paths: list[Path],
                         code: str) -> tuple[dict[str, set[str]], str] | None:
    """Map each precinct id to every district it belongs to, from the cong layer."""
    congressional = [path for path in paths if "cong" in path.stem.lower()]
    if not congressional:
        return None
    layer = gpd.read_file(congressional[0])
    field = first_column(layer, DISTRICT_FIELDS)
    id_field = first_column(layer, ["UNIQUE_ID", "GEOID", "VTD", "VTDST", "PRECINCT"])
    base_field = first_column(frame, [id_field]) if id_field else None
    if id_field is None or base_field is None:
        return None
    if field is None:
        derived = districts_from_vote_columns(layer, code)
        if derived is None:
            return None
        layer = layer.assign(__district=derived)
        field = "__district"

    known = set(frame[base_field].astype(str))
    memberships: dict[str, set[str]] = {}
    split = 0
    for identifier, district in zip(layer[id_field].astype(str), layer[field]):
        label = normalize_district(district)
        if label is None:
            continue
        match = CONG_SPLIT_SUFFIX.match(identifier)
        base = match.group(1) if match else identifier
        if base not in known:
            continue
        if match:
            split += 1
        memberships.setdefault(base, set()).add(label)
    if not memberships:
        return None
    multi = sum(1 for value in memberships.values() if len(value) > 1)
    if multi:
        print(f"[{code}] {multi} precincts span more than one district "
              f"({split} split rows in the congressional layer)", flush=True)
    return memberships, base_field


def districts_from_census(frame: gpd.GeoDataFrame, code: str,
                          reason: str = "no district column") -> pd.Series | None:
    """Assign each precinct a district by locating it in the Census CD polygons."""
    counties = census_layer(COUNTY_OUTLINES)
    match = counties[counties["STUSPS"] == code]
    if match.empty:
        return None
    districts = census_layer(CD_OUTLINES)
    districts = districts[districts["STATEFP"] == str(match["STATEFP"].iloc[0])]
    if districts.empty:
        return None
    points = gpd.GeoDataFrame(geometry=frame.geometry.representative_point(), crs=frame.crs)
    joined = gpd.sjoin(points, districts[["CD118FP", "geometry"]], how="left", predicate="within")
    joined = joined[~joined.index.duplicated(keep="first")]
    print(f"[{code}] {reason}; assigned {joined['CD118FP'].notna().sum()} of "
          f"{len(frame)} precincts from Census district polygons", flush=True)
    return joined["CD118FP"].map(district_label)


def normalize_district(value: object) -> str | None:
    if value is None or pd.isna(value) or str(value).strip() in {"", "0", "00", "nan"}:
        return None
    try:
        return str(int(float(value)))
    except (TypeError, ValueError):
        return str(value).strip()


def repair(geometries: gpd.GeoSeries, code: str, label: str) -> gpd.GeoSeries:
    invalid = ~geometries.is_valid
    if not invalid.any():
        return geometries
    print(f"[{code}] repairing {invalid.sum()} invalid {label} geometries", flush=True)
    # method="structure" always returns polygonal output; the default "linework"
    # method can return a GeometryCollection — see polygonal().
    repaired = geometries.copy()
    repaired.loc[invalid] = repaired.loc[invalid].make_valid(
        method="structure", keep_collapsed=False)
    return repaired


def snap_to_grid(geometries: gpd.GeoSeries, code: str) -> gpd.GeoSeries:
    """Snap vertices to COORD_GRID, tolerating individual failures.

    GEOS raises on some inputs even after a repair pass, and one bad polygon out
    of tens of thousands should not fail the whole state.
    """
    try:
        return geometries.set_precision(COORD_GRID)
    except Exception as error:
        print(f"[{code}] bulk grid snap failed ({error}); retrying per geometry", flush=True)
        snapped, skipped = [], 0
        for geometry in geometries:
            try:
                snapped.append(shapely.set_precision(geometry, COORD_GRID))
            except Exception:
                snapped.append(geometry)
                skipped += 1
        print(f"[{code}] {skipped} geometries left unsnapped", flush=True)
        return gpd.GeoSeries(snapped, index=geometries.index, crs=geometries.crs)


def snap_geometry(geometry, code: str):
    try:
        return shapely.set_precision(geometry, COORD_GRID)
    except Exception as error:
        print(f"[{code}] outline left unsnapped ({error})", flush=True)
        return geometry


def migrate_state_regions() -> None:
    """Move state_regions out of National.db and into each state database.

    The table lists the regions a state contains, which is information the
    state's own database is the natural home for — National.db needed a
    state_id column only because every state's rows shared one table.
    """
    national = sqlite3.connect(NATIONAL_DB)
    tables = {row[0] for row in national.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    existing: dict[str, list[tuple[int, str]]] = {}
    if "state_regions" in tables:
        for db_name, region_id, region_type in national.execute(
                "SELECT s.db_name, r.region_id, r.region_type FROM state_regions r "
                "JOIN states s ON s.id = r.state_id"):
            existing.setdefault(db_name, []).append((region_id, region_type))
        print(f"National.db: {sum(len(v) for v in existing.values())} rows across "
              f"{len(existing)} states", flush=True)
    else:
        print("National.db has no state_regions table; rebuilding from each state", flush=True)

    for path in sorted(OUTPUT_DIR.glob("*.db")):
        if path.stem == "National":
            continue
        db = sqlite3.connect(path)
        db.execute("DROP TABLE IF EXISTS state_regions")
        db.execute("CREATE TABLE state_regions (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                   "region_id INTEGER NOT NULL, region_type TEXT "
                   "CHECK(region_type IN ('county', 'congressional_district')))")
        rows = existing.get(path.name)
        if not rows:
            # No National.db rows to carry over: derive from the state's own tables.
            rows = [(r[0], "county") for r in db.execute("SELECT id FROM counties")]
            rows += [(r[0], "congressional_district")
                     for r in db.execute("SELECT id FROM congressional_districts")]
        db.executemany("INSERT INTO state_regions(region_id,region_type) VALUES (?,?)",
                       sorted(set(rows), key=lambda item: (item[1], item[0])))
        db.commit()
        count = db.execute("SELECT count(*) FROM state_regions").fetchone()[0]
        db.close()
        print(f"  {path.name}: {count} regions", flush=True)

    national.execute("DROP TABLE IF EXISTS state_regions")
    national.commit()
    national.execute("VACUUM")
    national.close()
    print("National.db: state_regions dropped", flush=True)


def write_state_regions(db: sqlite3.Connection, county_ids, district_ids) -> None:
    """Record which regions the state contains, inside the state's own database."""
    db.executemany("INSERT INTO state_regions(region_id,region_type) VALUES (?,?)",
                   [(region_id, "county") for region_id in sorted(county_ids)])
    db.executemany("INSERT INTO state_regions(region_id,region_type) VALUES (?,?)",
                   [(region_id, "congressional_district") for region_id in sorted(district_ids)])


def ensure_national_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(NATIONAL_SCHEMA)
    existing = {row[1] for row in conn.execute("PRAGMA table_info(states)")}
    for name, definition in (("db_name", "TEXT"), ("vote_summary", "TEXT")):
        if name not in existing:
            conn.execute(f"ALTER TABLE states ADD COLUMN {name} {definition}")
    conn.commit()


def import_state(archive: Path, national: sqlite3.Connection, overwrite: bool) -> dict:
    code = archive.name[:2].upper()
    state_name = STATE_NAMES[code.lower()]
    target = OUTPUT_DIR / f"{code}.db"
    if target.exists() and not overwrite:
        return {"code": code, "state": state_name, "skipped": True}

    with tempfile.TemporaryDirectory(prefix=f"gerrymander-{code}-") as temp:
        paths = vector_paths(archive, Path(temp))
        base_path = choose_precinct_path(paths)
        print(f"[{code}] reading {base_path.relative_to(temp)}", flush=True)
        gdf = gpd.read_file(base_path)
        if gdf.empty:
            raise ValueError("precinct layer is empty")
        if gdf.crs is None:
            raise ValueError("precinct layer has no CRS")
        gdf = gdf.to_crs("EPSG:4326")
        # Repair before snapping: GEOS raises a TopologyException when asked to
        # snap self-intersecting input.  Snapping can in turn invalidate a
        # geometry, so repair again afterwards.
        gdf["geometry"] = repair(gdf.geometry, code, "precinct")
        before = int(gdf.geometry.count_coordinates().sum())
        gdf["geometry"] = snap_to_grid(gdf.geometry, code)
        after = int(gdf.geometry.count_coordinates().sum())
        if after < before:
            print(f"[{code}] snapped to {COORD_GRID:g}° grid: "
                  f"{before:,} -> {after:,} vertices ({after / before:.1%})", flush=True)
        dropped = gdf.geometry.isna() | gdf.geometry.is_empty
        if dropped.any():
            print(f"[{code}] dropping {dropped.sum()} precincts that collapsed when snapped", flush=True)
            gdf = gdf[~dropped].reset_index(drop=True)
        gdf["geometry"] = repair(gdf.geometry, code, "snapped precinct")
        pres_cols = president_columns(gdf)
        if not pres_cols:
            raise ValueError("no recognizable 2024 presidential-result columns")

        county_field = first_column(gdf, ["COUNTY", "COUNTY_NAM", "COUNTYNAME", "CNTY_NAME", "CONAME", "COUNTYFP", "COUNTY_FIPS"])
        precinct_field = first_column(gdf, ["UNIQUE_ID", "GEOID", "VTD", "VTDST", "PRECINCT", "PRECINCTNA", "PRECINCT_NA", "WARDID", "LABEL"])
        population_field = first_column(gdf, ["PERSONS", "POPULATION", "TOTPOP", "TOTALPOP"])
        gdf["__county"] = gdf[county_field].map(lambda value: as_text(value, "Unknown")) if county_field else "Unknown"
        gdf["__precinct"] = [as_text(value, f"Precinct_{index + 1}") for index, value in enumerate(gdf[precinct_field])] if precinct_field else [f"Precinct_{index + 1}" for index in range(len(gdf))]

        # Districts resolve in order of authority: a field on the precinct
        # layer, then the companion congressional layer, then the House vote
        # column names, and only then the Census polygons.  A precinct that
        # straddles districts belongs to each of them, which
        # congressional_district_precincts is keyed to express.
        column = district_values(gdf)
        gdf["__districts"] = ([[normalize_district(v)] if normalize_district(v) else []
                               for v in column]
                              if column is not None else [[] for _ in range(len(gdf))])
        if gdf["__districts"].map(len).eq(0).all():
            memberships = district_memberships(gdf, paths, code)
            if memberships is not None:
                table, base_field = memberships
                gdf["__districts"] = [sorted(table.get(str(value), ()))
                                      for value in gdf[base_field]]
        # New Hampshire has neither a district field nor a cong layer, but its
        # main layer does carry the House vote columns.
        blank = gdf["__districts"].map(len) == 0
        if blank.all():
            derived = districts_from_vote_columns(gdf, code)
            if derived is not None:
                gdf["__districts"] = [[normalize_district(v)] if normalize_district(v) else []
                                      for v in derived]

        # Anything still without a district falls back to the Census polygons.
        blank = gdf["__districts"].map(len) == 0
        if blank.any():
            filled = districts_from_census(
                gdf[blank], code, reason=f"{blank.sum()} precincts have no district")
            if filled is not None:
                # Rebuild the column outright: assigning lists through .loc lets
                # pandas align and broadcast them, which silently turns unmatched
                # rows into NaN and can duplicate labels into a row.
                found = {index: label for index, label in zip(gdf.index[blank], filled) if label}
                gdf["__districts"] = [
                    list(values) if values else ([found[index]] if index in found else [])
                    for index, values in zip(gdf.index, gdf["__districts"])]
        gdf["__district"] = [values[0] if values else None
                             for values in gdf["__districts"]]

        # Dissolving is where geometry really blows up: unioning thousands of
        # precincts keeps a node for every near-duplicate vertex along shared
        # borders, which is how a single county ends up with 1.6 M vertices.
        # Snapping the result collapses those back onto the grid.
        state_geom = snap_geometry(gdf.geometry.union_all(), code)
        county_geoms = snap_to_grid(gdf.dissolve(by="__county").geometry, code)
        exploded = gdf[["__districts", "geometry"]].explode("__districts").dropna(subset=["__districts"])
        district_geoms = snap_to_grid(
            exploded.dissolve(by="__districts").geometry, code)
        if district_geoms.empty and code in AT_LARGE_STATES:
            district_geoms = gpd.GeoSeries([state_geom], index=["At-large"], crs=gdf.crs)
            gdf["__districts"] = [["At-large"] for _ in range(len(gdf))]
        if len(district_geoms) == 1:
            # A state with a single district has every precinct in it by
            # definition; no geometry needs to place them.
            only = [district_geoms.index[0]]
            gdf["__districts"] = [list(only) for _ in range(len(gdf))]
        candidate_totals: defaultdict[str, int] = defaultdict(int)

        temp_target = target.with_suffix(".db.tmp")
        temp_target.unlink(missing_ok=True)
        db = sqlite3.connect(temp_target)
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(STATE_SCHEMA)
        county_ids, district_ids = {}, {}
        for county_id, (county, geometry) in enumerate(county_geoms.items(), 1):
            lat, lon = center(geometry)
            db.execute("INSERT INTO counties(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)", (county_id, county, wkb(geometry), lat, lon))
            county_ids[county] = county_id
        for district_id, (district, geometry) in enumerate(district_geoms.items(), 1):
            lat, lon = center(geometry)
            db.execute("INSERT INTO congressional_districts(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)", (district_id, f"District {district}", wkb(geometry), lat, lon))
            district_ids[district] = district_id

        for precinct_id, (_, row) in enumerate(gdf.iterrows(), 1):
            row_votes: defaultdict[str, int] = defaultdict(int)
            for column, candidate in pres_cols:
                row_votes[candidate] += as_int(row[column])
            for candidate, votes in row_votes.items():
                candidate_totals[candidate] += votes
            fallback_population = sum(row_votes.values())
            population = as_int(row[population_field]) if population_field else fallback_population
            lat, lon = center(row.geometry)
            db.execute("INSERT INTO precincts(id,name,boundary,center_lat,center_lon,population) VALUES (?,?,?,?,?,?)", (precinct_id, row["__precinct"], wkb(row.geometry), lat, lon, population))
            db.execute("INSERT INTO county_precincts(precinct_id,county_id) VALUES (?,?)", (precinct_id, county_ids[row["__county"]]))
            # dict.fromkeys keeps order while guaranteeing the (precinct,
            # district) pair is inserted once.
            for label in dict.fromkeys(row["__districts"]):
                if label in district_ids:
                    db.execute("INSERT INTO congressional_district_precincts(precinct_id,congressional_district_id) VALUES (?,?)", (precinct_id, district_ids[label]))
            for candidate, votes in row_votes.items():
                if votes:
                    db.execute("INSERT INTO precinct_results(precinct_id,candidate_id,votes) VALUES (?,?,?)", (precinct_id, candidate_uuid(candidate), votes))
        write_state_regions(db, county_ids.values(), district_ids.values())
        db.commit()
        db.close()
        shutil.move(temp_target, target)

    national.execute("DELETE FROM states WHERE name=?", (state_name,))
    state_lat, state_lon = center(state_geom)
    summary = [{"candidate_id": candidate_uuid(candidate), "votes": votes}
               for candidate, votes in sorted(candidate_totals.items()) if votes]
    national.execute("INSERT INTO states(name,boundary,center_lat,center_lon,db_name,vote_summary) VALUES (?,?,?,?,?,?)", (state_name, wkb(state_geom), state_lat, state_lon, target.name, json.dumps(summary, separators=(",", ":"))))
    national.commit()
    return {"code": code, "state": state_name, "precincts": len(gdf), "counties": len(county_ids), "districts": len(district_ids), "votes": sum(candidate_totals.values())}


def district_label(value: object) -> str | None:
    """Census encodes an at-large district as '00', which normalize_district
    would discard as 'no district'."""
    if str(value).strip() == "00":
        return "At-large"
    return normalize_district(value)


_census_layers: dict[Path, gpd.GeoDataFrame] = {}


def census_layer(path: Path) -> gpd.GeoDataFrame:
    if path not in _census_layers:
        _census_layers[path] = gpd.read_file(f"/vsizip/{path}").to_crs("EPSG:4326")
    return _census_layers[path]


# Wording that differs between sources for the same precinct: MEDSL writes
# "ALCONA TOWNSHIP 1 Ward 0" where the NYT writes "Alcona Township, Precinct 1".
PRECINCT_FILLER = re.compile(
    r"\b(PRECINCT|PCT|WARD|TWP|TOWNSHIP|VOTING|DISTRICT|DIST|NO|NUM)\b")
PRECINCT_ZERO_WARD = re.compile(r"\bWARD\s*0+\b")


def precinct_key(value: object) -> str:
    """Normalise a precinct identifier for matching across sources.

    Measured against the NYT shapes this lifts New Mexico from 1% to 97%,
    South Dakota from 22% to 79% and Michigan from 0% to 58%, with no key
    collisions in thirteen of the fifteen states.
    """
    text = re.sub(r"\s+(VSC|VOTE CENTER|VC)$", "", str(value).upper().strip())
    text = PRECINCT_ZERO_WARD.sub(" ", text)  # "Ward 0" means no ward at all
    text = PRECINCT_FILLER.sub(" ", text)
    text = re.sub(r"[^A-Z0-9]", " ", text)
    return "".join(part.lstrip("0") or "0" for part in text.split()) or "0"


def medsl_rows(code: str) -> list[dict]:
    archive = MEDSL_DIR / f"{code.lower()}24.zip"
    if not archive.exists():
        raise ValueError(f"no MEDSL archive at {archive}")
    with zipfile.ZipFile(archive) as bundle:
        name = bundle.namelist()[0]
        with bundle.open(name) as handle:
            return list(csv.DictReader(io.TextIOWrapper(handle, "utf-8")))


def nyt_boundaries(code: str) -> dict[tuple[str, str], object]:
    """(county fips, normalised precinct) -> geometry, from the NYT map."""
    source = NYT_DIR / f"{code}.geojson.gz"
    if not source.exists():
        return {}
    layer = gpd.read_file(f"/vsigzip/{source}")
    if layer.crs is None:
        layer = layer.set_crs("EPSG:4326")
    layer = layer.to_crs("EPSG:4326")
    layer["geometry"] = snap_to_grid(repair(layer.geometry, code, "NYT precinct"), code)
    grouped: dict[tuple[str, str], list] = {}
    for geoid, geometry in zip(layer["GEOID"], layer.geometry):
        text = str(geoid)
        grouped.setdefault((text[:5], precinct_key(text[5:])), []).append(geometry)
    # Where two shapes normalise to the same key the match is ambiguous; leave
    # those precincts without geometry rather than attach an arbitrary one.
    ambiguous = sum(1 for shapes in grouped.values() if len(shapes) > 1)
    if ambiguous:
        print(f"[{code}] {ambiguous} ambiguous precinct keys left unmatched", flush=True)
    return {key: shapes[0] for key, shapes in grouped.items() if len(shapes) == 1}


def drop_county_totals(tally: dict, display: dict, code: str) -> list:
    """Find rows that restate their county's total rather than a real precinct.

    New Jersey ships a "COUNTY TOTAL" row alongside Gloucester's 25 precincts,
    which double-counts 164,635 votes.  Matching on the name alone is unsafe —
    Harney County, Oregon reports its whole county in one row also called
    "TOTAL", and dropping that would lose the county entirely.  So a row is only
    dropped when its votes actually equal the sum of the county's other rows.
    """
    by_county: dict[str, list] = {}
    for key in tally:
        by_county.setdefault(key[0], []).append(key)

    doomed = []
    for fips, keys in by_county.items():
        if len(keys) < 2:
            continue
        totals = {key: sum(tally[key].values()) for key in keys}
        for key in keys:
            others = sum(value for other, value in totals.items() if other != key)
            if others and totals[key] == others:
                doomed.append(key)
                name = display.get(key, key[1])
                print(f"[{code}] dropping {name!r} in county {fips}: its {totals[key]:,} "
                      f"votes restate the county's other {len(keys) - 1} precincts", flush=True)
    return doomed


SUBDIVISION_SUFFIX = re.compile(
    r"\s+(Boro|Borough|City|Twp|Township|Village|Town|Plantation)\s*$", re.I)


def subdivision_name(precinct: str) -> str:
    """Reduce a precinct name to the municipality or township it belongs to."""
    name = re.split(r"[/]|\s+-\s+", str(precinct))[0]
    name = re.sub(r"\s+(Ward|District|Precinct|Dist)\b.*$", "", name, flags=re.I)
    name = SUBDIVISION_SUFFIX.sub("", name).strip()
    # The Census writes "St. Agatha" where the returns say "Saint Agatha".
    return re.sub(r"^Saint\b", "St.", name, flags=re.I).strip()


def subdivision_match(fips: str, precinct: str) -> gpd.GeoDataFrame | None:
    """Find the Census county subdivision a precinct name refers to.

    Matching is restricted to the precinct's own county: township names such as
    "Washington" or "Noble" recur many times across a state.
    """
    if not COUSUB_OUTLINES.exists():
        return None
    name = subdivision_name(precinct)
    if not name:
        return None
    layer = census_layer(COUSUB_OUTLINES)
    match = layer[(layer["STATEFP"] == fips[:2]) & (layer["COUNTYFP"] == fips[2:])
                  & (layer["NAME"].str.casefold() == name.casefold())]
    return None if match.empty else match


def subdivision_district(fips: str, precinct: str, code: str) -> str | None:
    """Place a precinct via the Census county subdivision its name refers to.

    Municipality and township names ("Glassboro Boro", "Noble - Pioneer") are
    Census county subdivisions, so one lying wholly inside a single district
    settles every precinct named after it — no precinct geometry needed.  The
    match is restricted to the precinct's own county because township names
    such as "Washington" recur across a state.
    """
    if not COUSUB_OUTLINES.exists():
        return None
    match = subdivision_match(fips, precinct)
    if match is None:
        return None
    districts = census_layer(CD_OUTLINES)
    districts = districts[districts["STATEFP"] == fips[:2]]
    area = match.geometry.union_all()
    if area.area <= 0:
        return None
    # A sliver of overlap is a boundary artefact, not membership.
    hits = {district_label(row["CD118FP"]) for _, row in districts.iterrows()
            if row.geometry.intersection(area).area > area.area * 0.02}
    hits.discard(None)
    return next(iter(hits)) if len(hits) == 1 else None


def rdh_vtd_crosswalk(code: str) -> dict[tuple[str, str], str]:
    """{(county fips, precinct key): Census VTD key} from an RDH results table."""
    path = RDH_DIR / f"{code.lower()}_2024_gen_prec.csv"
    if not path.exists():
        return {}
    counties = census_layer(COUNTY_OUTLINES)
    match = counties[counties["STUSPS"] == code]
    if match.empty:
        return {}
    statefp = str(match["STATEFP"].iloc[0])
    crosswalk = {}
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            county = str(row.get("COUNTYFP") or "").zfill(3)[-3:]
            precinct = row.get("Precinct") or row.get("PRECINCT")
            vtd = str(row.get("VTD code") or row.get("VTD_CODE") or "").strip()
            if county and precinct and vtd:
                crosswalk[(statefp + county, precinct_key(precinct))] = precinct_key(vtd)
    if crosswalk:
        print(f"[{code}] {path.name}: {len(crosswalk):,} precinct -> VTD entries", flush=True)
    return crosswalk


def census_vtd_boundaries(code: str) -> dict[tuple[str, str], object]:
    """{(county fips, precinct key): geometry} from the Census 2020 VTD layer."""
    counties = census_layer(COUNTY_OUTLINES)
    match = counties[counties["STUSPS"] == code]
    if match.empty:
        return {}
    statefp = str(match["STATEFP"].iloc[0])
    path = VTD_DIR / f"tl_2020_{statefp}_vtd20.zip"
    if not path.exists():
        return {}
    layer = gpd.read_file(f"/vsizip/{path}").to_crs("EPSG:4326")
    layer["geometry"] = snap_to_grid(repair(layer.geometry, code, "Census VTD"), code)
    return {(statefp + str(row["COUNTYFP20"]), precinct_key(row["VTDST20"])): row.geometry
            for _, row in layer.iterrows()}


def state_precinct_layer(code: str) -> tuple[dict, dict] | None:
    """Load a state's own precinct layer as {(fips, key): geometry} plus districts."""
    entry = STATE_PRECINCT_LAYERS.get(code)
    if entry is None:
        return None
    path, county_field, precinct_field, district_field = entry
    if not path.exists():
        return None
    layer = gpd.read_file(f"/vsizip/{path}").to_crs("EPSG:4326")
    layer["geometry"] = snap_to_grid(repair(layer.geometry, code, "state precinct"), code)
    fips = str(census_layer(COUNTY_OUTLINES).loc[
        census_layer(COUNTY_OUTLINES)["STUSPS"] == code, "STATEFP"].iloc[0])
    shapes, districts = {}, {}
    for _, row in layer.iterrows():
        key = (fips + str(row[county_field]).zfill(3), precinct_key(row[precinct_field]))
        shapes[key] = row.geometry
        if district_field:
            label = normalize_district(row[district_field])
            if label:
                districts[key] = label
    print(f"[{code}] {path.name}: {len(shapes):,} official precinct outlines", flush=True)
    return shapes, districts


def import_medsl_state(code: str, national: sqlite3.Connection, overwrite: bool) -> dict:
    """Import a state from the MEDSL precinct returns.

    The returns are the backbone: every precinct carries its votes, its county
    (via county_fips) and its congressional district (via the US HOUSE rows in
    the same file).  County and district totals are therefore aggregated from
    precincts exactly as for a VEST state, and stay complete even where a
    precinct has no polygon.  Geometry is attached separately and is optional:
    Census for counties and districts, the NYT map for precincts where its
    identifiers line up.  A precinct with no polygon still contributes its
    votes; it simply is not drawn.
    """
    state_name = STATE_NAMES[code.lower()]
    target = OUTPUT_DIR / f"{code}.db"
    if target.exists() and not overwrite:
        return {"code": code, "state": state_name, "skipped": True}

    rows = medsl_rows(code)
    print(f"[{code}] reading {code.lower()}24.zip (MEDSL returns)", flush=True)

    # precinct -> congressional district, taken from the US House contest.
    district_of: dict[tuple[str, str], str] = {}
    for row in rows:
        if row["office"] != "US HOUSE":
            continue
        district = str(row["district"]).strip()
        if district and district.upper() != "STATEWIDE":
            district_of[(str(row["county_fips"]).zfill(5),
                         precinct_key(row["precinct"]))] = district

    votes: defaultdict[tuple, dict[str, int]] = defaultdict(dict)
    display: dict[tuple[str, str], str] = {}
    unknown, suppressed = collections.Counter(), 0
    for row in rows:
        if row["office"] != "US PRESIDENT":
            continue
        name = row["candidate"].strip().upper()
        if MEDSL_ACCOUNTING.search(name):
            continue
        try:
            count = int(float(row["votes"]))
        except (TypeError, ValueError):
            suppressed += 1
            continue
        if row["writein"] == "TRUE":
            candidate = "WRI"
        else:
            candidate = MEDSL_CANDIDATES.get(name)
            if candidate is None:
                unknown[name] += count
                candidate = "OTH"
        # Key on the normalised precinct id so that a precinct split across
        # vote-service-centre rows ("34-01" and "34-01 VSC" in Hawaii) becomes
        # one precinct with one polygon rather than two overlapping ones.  This
        # merges nothing in the other fourteen states.
        fips = str(row["county_fips"]).zfill(5)
        raw = str(row["precinct"])
        key = (fips, precinct_key(raw), candidate)
        display.setdefault((fips, precinct_key(raw)), raw)
        if len(raw) < len(display[(fips, precinct_key(raw))]):
            display[(fips, precinct_key(raw))] = raw
        votes[key][row["mode"]] = votes[key].get(row["mode"], 0) + count
    if suppressed:
        print(f"[{code}] {suppressed} result rows had a suppressed vote count", flush=True)
    for name, count in unknown.most_common():
        print(f"[{code}] unmapped candidate {name!r} ({count:,} votes) counted as Other", flush=True)

    tally: defaultdict[tuple[str, str], dict[str, int]] = defaultdict(dict)
    for (fips, precinct, candidate), modes in votes.items():
        total = modes["TOTAL"] if "TOTAL" in modes else sum(modes.values())
        if total:
            slot = tally[(fips, precinct)]
            slot[candidate] = slot.get(candidate, 0) + total

    for key in drop_county_totals(tally, display, code):
        del tally[key]

    counties = census_layer(COUNTY_OUTLINES)
    counties = counties[counties["STUSPS"] == code].reset_index(drop=True)
    if counties.empty:
        raise ValueError(f"no Census counties for {code}")
    statefp = str(counties["STATEFP"].iloc[0])
    counties["geometry"] = snap_to_grid(counties.geometry, code)
    county_name = {str(g): str(n) for g, n in zip(counties["GEOID"], counties["NAME"])}
    county_name.update({old: county_name[new] for old, new in RENAMED_COUNTY_FIPS.items()
                        if new in county_name})
    county_geom = {str(row["NAME"]): row.geometry for _, row in counties.iterrows()}

    districts = census_layer(CD_OUTLINES)
    districts = districts[districts["STATEFP"] == statefp].reset_index(drop=True)
    districts["geometry"] = snap_to_grid(districts.geometry, code)
    district_geom = {district_label(row["CD118FP"]): row.geometry
                     for _, row in districts.iterrows()}
    district_geom.pop(None, None)
    at_large = list(district_geom) == ["At-large"]

    if len(district_geom) == 1:
        # Single-district state: every precinct belongs to it by definition.
        only = next(iter(district_geom))
        for key in tally:
            district_of[key] = only

    shapes = nyt_boundaries(code)
    official = state_precinct_layer(code)
    if official is not None:
        state_shapes, state_districts = official
        shapes = {**shapes, **{k: v for k, v in state_shapes.items() if k in tally}}
        for key, label in state_districts.items():
            if key in tally:
                district_of.setdefault(key, label)
    if shapes:
        matched = sum(1 for key in tally if key in shapes)
        print(f"[{code}] precinct outlines: {matched:,}/{len(tally):,} matched "
              f"({matched / len(tally):.1%}) from {len(shapes):,} NYT shapes", flush=True)
    else:
        print(f"[{code}] no NYT precinct outlines available", flush=True)

    # Census voting districts, where the state numbers precincts the same way.
    vtd = census_vtd_boundaries(code)
    if vtd:
        added = sum(1 for key in tally if key not in shapes and key in vtd)
        shapes.update({key: vtd[key] for key in tally if key not in shapes and key in vtd})
        if added:
            print(f"[{code}] {added} precinct outlines from the Census 2020 VTD layer", flush=True)
        # Same layer, reached through the RDH crosswalk for precincts whose own
        # id does not match a VTD code.
        crosswalk = rdh_vtd_crosswalk(code)
        if crosswalk:
            bridged = 0
            for key in tally:
                if key in shapes:
                    continue
                vtd_key = crosswalk.get(key)
                if vtd_key and (key[0], vtd_key) in vtd:
                    shapes[key] = vtd[(key[0], vtd_key)]
                    bridged += 1
            if bridged:
                print(f"[{code}] {bridged} more via the RDH precinct -> VTD crosswalk", flush=True)

    # Where neither has a matching shape, fall back to the Census outline
    # of the municipality or township the precinct is named after.  A precinct
    # that subdivides one (several wards of a town) is skipped: they would all
    # be handed the same polygon and drawn on top of each other.
    if COUSUB_OUTLINES.exists():
        wanted = [key for key in tally if key not in shapes]
        claims: dict[tuple, list] = {}
        for key in wanted:
            match = subdivision_match(key[0], display.get(key, key[1]))
            if match is not None:
                claims.setdefault((key[0], match.iloc[0]["GEOID"]), []).append(key)
        added = 0
        for (fips, _), keys in claims.items():
            if len(keys) != 1:
                continue
            match = subdivision_match(fips, display.get(keys[0], keys[0][1]))
            shapes[keys[0]] = snap_geometry(match.geometry.union_all(), code)
            added += 1
        shared = sum(len(v) for v in claims.values() if len(v) > 1)
        if added or shared:
            print(f"[{code}] {added} precinct outlines taken from Census subdivisions"
                  + (f"; {shared} share a subdivision and were left without one" if shared else ""),
                  flush=True)

    # Precincts whose US House row is missing get their district from the
    # Census polygons instead, wherever a shape was matched for them.
    if not at_large:
        orphans = [key for key in tally
                   if key not in district_of and key in shapes]
        if orphans:
            frame = gpd.GeoDataFrame(
                {"key": orphans}, geometry=[shapes[key] for key in orphans], crs="EPSG:4326")
            filled = districts_from_census(
                frame, code, reason=f"{len(orphans)} precincts have no US House row")
            if filled is not None:
                for key, label in zip(orphans, filled):
                    if label:
                        district_of[key] = label

        # A named municipality or township is a Census county subdivision, so
        # one that lies wholly inside a district places its precincts too —
        # this is what resolves Gloucester County, New Jersey.
        adopted = 0
        for key in tally:
            if key in district_of:
                continue
            label = subdivision_district(key[0], display.get(key, key[1]), code)
            if label:
                district_of[key] = label
                adopted += 1
        if adopted:
            print(f"[{code}] {adopted} precincts placed by their Census subdivision", flush=True)

        # A state may publish the mapping outright.
        lookup = STATE_DISTRICT_LOOKUPS.get(code)
        if lookup and lookup.exists():
            table = json.loads(lookup.read_text())
            adopted = 0
            for key in tally:
                if key in district_of:
                    continue
                label = table.get(display.get(key, key[1]))
                if label:
                    district_of[key] = label
                    adopted += 1
            if adopted:
                print(f"[{code}] {adopted} precincts placed from {lookup.name}", flush=True)

        # A county lying wholly inside one district puts every precinct of that
        # county in it.  This needs no geometry, which is what makes it the only
        # option left for precincts that have neither a US House row nor a
        # matched outline.
        in_county: dict[str, set[str]] = {}
        for fips, precinct in tally:
            label = normalize_district(district_of.get((fips, precinct)) or "")
            if label:
                in_county.setdefault(fips, set()).add(label)
        adopted = 0
        for key in tally:
            if key in district_of:
                continue
            labels = in_county.get(key[0])
            if labels and len(labels) == 1:
                district_of[key] = next(iter(labels))
                adopted += 1
        if adopted:
            print(f"[{code}] {adopted} precincts adopted their county's only district", flush=True)

    temp_target = target.with_suffix(".db.tmp")
    temp_target.unlink(missing_ok=True)
    db = sqlite3.connect(temp_target)
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(STATE_SCHEMA)

    county_ids, district_ids = {}, {}
    for county_id, (name, geometry) in enumerate(sorted(county_geom.items()), 1):
        lat, lon = center(geometry)
        db.execute("INSERT INTO counties(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)",
                   (county_id, name, wkb(geometry), lat, lon))
        county_ids[name] = county_id
    for district_id, (name, geometry) in enumerate(sorted(district_geom.items()), 1):
        lat, lon = center(geometry)
        db.execute("INSERT INTO congressional_districts(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)",
                   (district_id, f"District {name}", wkb(geometry), lat, lon))
        district_ids[name] = district_id

    candidate_totals: defaultdict[str, int] = defaultdict(int)
    drawn, no_county, no_district = 0, set(), 0
    for precinct_id, ((fips, precinct), row_votes) in enumerate(sorted(tally.items()), 1):
        for candidate, count in row_votes.items():
            candidate_totals[candidate] += count
        geometry = shapes.get((fips, precinct))
        blob = wkb(geometry) if geometry is not None else None
        if blob is not None:
            drawn += 1
        lat, lon = center(geometry) if geometry is not None else (None, None)
        db.execute("INSERT INTO precincts(id,name,boundary,center_lat,center_lon,population) VALUES (?,?,?,?,?,?)",
                   (precinct_id, display.get((fips, precinct), precinct), blob, lat, lon,
                    sum(row_votes.values())))

        name = county_name.get(fips)
        if name is None or name not in county_ids:
            no_county.add(fips)
        else:
            db.execute("INSERT INTO county_precincts(precinct_id,county_id) VALUES (?,?)",
                       (precinct_id, county_ids[name]))

        district = district_of.get((fips, precinct))
        label = "At-large" if at_large else (normalize_district(district) if district else None)
        if label in district_ids:
            db.execute("INSERT INTO congressional_district_precincts(precinct_id,congressional_district_id) VALUES (?,?)",
                       (precinct_id, district_ids[label]))
        else:
            no_district += 1

        for candidate, count in row_votes.items():
            db.execute("INSERT INTO precinct_results(precinct_id,candidate_id,votes) VALUES (?,?,?)",
                       (precinct_id, candidate_uuid(candidate), count))
    write_state_regions(db, county_ids.values(), district_ids.values())
    db.commit()
    db.close()
    shutil.move(temp_target, target)

    if no_county:
        print(f"[{code}] {len(no_county)} county fips had no Census match: {sorted(no_county)}", flush=True)
    if no_district:
        print(f"[{code}] {no_district:,}/{len(tally):,} precincts have no district; "
              f"their votes count towards the state but not towards any district", flush=True)

    national.execute("DELETE FROM states WHERE name=?", (state_name,))
    state_geom = snap_geometry(unary_union(list(county_geom.values())), code)
    state_lat, state_lon = center(state_geom)
    summary = [{"candidate_id": candidate_uuid(candidate), "votes": count}
               for candidate, count in sorted(candidate_totals.items()) if count]
    national.execute(
        "INSERT INTO states(name,boundary,center_lat,center_lon,db_name,vote_summary) VALUES (?,?,?,?,?,?)",
        (state_name, wkb(state_geom), state_lat, state_lon, target.name,
         json.dumps(summary, separators=(",", ":"))))
    national.commit()
    return {"code": code, "state": state_name, "source": "medsl",
            "precincts": len(tally), "drawn": drawn, "counties": len(county_ids),
            "districts": len(district_ids), "votes": sum(candidate_totals.values())}


def apply_state_outlines(national: sqlite3.Connection) -> None:
    """Replace `states.boundary` with the authoritative Census outline.

    Only the geometry and its centre are touched: `vote_summary` and `db_name`
    stay exactly as computed from the raw precinct data, and no state row is
    created — a state the election data does not cover stays absent.
    """
    if not STATE_OUTLINES.exists():
        print(f"state outlines not found at {STATE_OUTLINES}; keeping precinct-derived "
              f"boundaries (download {STATE_OUTLINES.name} to replace them)", flush=True)
        return

    outlines = gpd.read_file(f"/vsizip/{STATE_OUTLINES}").to_crs("EPSG:4326")
    field = first_column(outlines, ["NAME", "STATE_NAME"])
    if field is None:
        print(f"{STATE_OUTLINES.name} has no NAME column; keeping existing boundaries", flush=True)
        return
    outlines["geometry"] = snap_to_grid(outlines.geometry, "US")
    by_name = {str(row[field]).strip(): row.geometry for _, row in outlines.iterrows()}

    replaced, before, after, unmatched = 0, 0, 0, []
    for state_id, name, boundary in national.execute(
            "SELECT id, name, boundary FROM states").fetchall():
        geometry = by_name.get(name)
        if geometry is None:
            unmatched.append(name)
            continue
        lat, lon = center(geometry)
        blob = wkb(geometry)
        if blob is None:
            unmatched.append(name)
            continue
        before += len(boundary or b"")
        after += len(blob)
        national.execute(
            "UPDATE states SET boundary=?, center_lat=?, center_lon=? WHERE id=?",
            (blob, lat, lon, state_id))
        replaced += 1
    national.commit()
    print(f"state outlines: replaced {replaced} boundaries, "
          f"{before / 1048576:.1f} MB -> {after / 1048576:.1f} MB"
          + (f"; no match for {unmatched}" if unmatched else ""), flush=True)


def display_name(db_stem: str) -> str:
    return "National" if db_stem == "National" else STATE_NAMES.get(db_stem.lower(), db_stem)


def update_manifest():
    stems = ["National"] + sorted(path.stem for path in OUTPUT_DIR.glob("*.db") if path.stem != "National")
    used_parties = {party for _, party in CANDIDATES.values()}
    payload = [{
        "name": ELECTION_NAME,
        "description": ELECTION_DESCRIPTION,
        "candidates": [
            {"id": candidate_uuid(code), "office": OFFICE, "name": name, "party_id": party_uuid(party)}
            for code, (name, party) in sorted(CANDIDATES.items(), key=lambda item: item[1][0])
        ],
        "parties": [
            {"id": party_uuid(code), "name": code, "color": color}
            for code, (_, color) in PARTIES.items() if code in used_parties
        ],
        "dbs": [
            {"name": display_name(stem), "url": f"{CDN_BASE}/{ELECTION_NAME}/{stem}.db"}
            for stem in stems
        ],
    }]
    DB_LIST.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {DB_LIST.relative_to(ROOT)} "
          f"({len(payload[0]['candidates'])} candidates, {len(payload[0]['parties'])} parties, {len(stems)} dbs)")


def migrate_existing():
    """Convert already-built databases from integer candidate ids to UUIDs.

    Reads the old National.db candidates table for the int -> code mapping, so
    it must run before that table is dropped.  Use this instead of a full
    re-import when the geometry in data/output is already correct.
    """
    national = sqlite3.connect(NATIONAL_DB)
    tables = {row[0] for row in national.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "candidates" not in tables:
        national.close()
        raise SystemExit("National.db has no candidates table — nothing to migrate")
    mapping = {}
    for old_id, name in national.execute("SELECT id, name FROM candidates"):
        code = str(name).strip().upper()[:3]
        register_candidate(code, None)
        mapping[old_id] = candidate_uuid(code)
    print(f"migrating {len(mapping)} candidate ids")

    for path in sorted(OUTPUT_DIR.glob("*.db")):
        if path.stem == "National":
            continue
        db = sqlite3.connect(path)
        types = {row[1]: row[2] for row in db.execute("PRAGMA table_info(precinct_results)")}
        if types.get("candidate_id") == "TEXT":
            print(f"[{path.stem}] already migrated")
            db.close()
            continue
        unknown = [row[0] for row in db.execute("SELECT DISTINCT candidate_id FROM precinct_results") if row[0] not in mapping]
        if unknown:
            db.close()
            raise SystemExit(f"[{path.stem}] candidate ids missing from National.db: {unknown}")
        db.executescript("""
        PRAGMA foreign_keys=OFF;
        CREATE TABLE precinct_results_new (id INTEGER PRIMARY KEY AUTOINCREMENT, precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE, candidate_id TEXT NOT NULL, votes INTEGER NOT NULL DEFAULT 0, UNIQUE(precinct_id, candidate_id));
        """)
        db.executemany("INSERT INTO precinct_results_new(id,precinct_id,candidate_id,votes) VALUES (?,?,?,?)",
                       ((row[0], row[1], mapping[row[2]], row[3])
                        for row in db.execute("SELECT id,precinct_id,candidate_id,votes FROM precinct_results")))
        db.executescript("""
        DROP TABLE precinct_results;
        ALTER TABLE precinct_results_new RENAME TO precinct_results;
        CREATE INDEX IF NOT EXISTS idx_precinct_results_precinct ON precinct_results(precinct_id);
        PRAGMA foreign_keys=ON;
        """)
        db.commit()
        count = db.execute("SELECT count(*) FROM precinct_results").fetchone()[0]
        db.close()
        print(f"[{path.stem}] migrated {count} results")

    for state_id, summary in national.execute("SELECT id, vote_summary FROM states").fetchall():
        if not summary:
            continue
        rows = json.loads(summary)
        for row in rows:
            old = row["candidate_id"]
            if isinstance(old, int):
                row["candidate_id"] = mapping[old]
        national.execute("UPDATE states SET vote_summary=? WHERE id=?",
                         (json.dumps(rows, separators=(",", ":")), state_id))
    national.commit()
    ensure_national_schema(national)
    national.close()
    print("National.db: vote_summary remapped, candidates/parties tables dropped")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--overwrite", action="store_true", help="rebuild an already existing state database")
    parser.add_argument("--states", nargs="*", help="two-letter state codes to import (default: every ZIP in data/raw_data)")
    parser.add_argument("--migrate", action="store_true", help="convert existing output databases to UUID candidate ids instead of importing")
    parser.add_argument("--manifest-only", action="store_true", help="only rewrite data/output/dbs.json")
    parser.add_argument("--outlines-only", action="store_true", help="only refresh National.db state boundaries")
    parser.add_argument("--migrate-regions", action="store_true", help="move state_regions from National.db into each state database")
    args = parser.parse_args()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if args.manifest_only:
        update_manifest()
        return
    if args.migrate_regions:
        migrate_state_regions()
        return
    if args.outlines_only:
        national = sqlite3.connect(NATIONAL_DB)
        apply_state_outlines(national)
        national.close()
        return
    if args.migrate:
        migrate_existing()
        update_manifest()
        return

    archives = sorted(INPUT_DIR.glob("*_2024_gen_*.zip"))
    # The duplicate Illinois ZIP is byte-identical; process the canonical name once.
    archives = [path for path in archives if " (" not in path.name]
    wanted = {item.upper() for item in args.states or []}
    if wanted:
        archives = [path for path in archives if path.name[:2].upper() in wanted]
    national = sqlite3.connect(NATIONAL_DB)
    ensure_national_schema(national)
    failures = []
    for archive in archives:
        try:
            report = import_state(archive, national, args.overwrite)
            print(report, flush=True)
        except Exception as error:
            national.rollback()
            failures.append((archive.name, str(error)))
            print(f"FAILED {archive.name}: {error}", flush=True)
    # States with no VEST archive come from the MEDSL returns instead.
    vest_codes = {path.name[:2].upper() for path in INPUT_DIR.glob("*_2024_gen_*.zip")}
    medsl_codes = sorted({path.name[:2].upper() for path in MEDSL_DIR.glob("*24.zip")} - vest_codes) \
        if MEDSL_DIR.exists() else []
    if wanted:
        medsl_codes = [code for code in medsl_codes if code in wanted]
    for code in medsl_codes:
        try:
            print(import_medsl_state(code, national, args.overwrite), flush=True)
        except Exception as error:
            national.rollback()
            failures.append((f"medsl/{code}", str(error)))
            print(f"FAILED medsl/{code}: {error}", flush=True)

    apply_state_outlines(national)
    national.close()
    update_manifest()
    if failures:
        print("\nFailures:")
        for name, error in failures:
            print(f"- {name}: {error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
