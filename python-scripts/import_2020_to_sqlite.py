#!/usr/bin/env python3
"""Build one election/map SQLite file per state for the 2020 presidential race.

Run from this directory with the project's virtual environment:
    .venv/bin/python import_2020_to_sqlite.py

This is the 2020 sibling of import_to_sqlite.py and writes the same schema, the
same National.db and the same dbs.json manifest — only the election, the input
archives and the output directory differ:

    data/2020-raw-data/dataverse_files (1)/xx_2020.zip  ->  data/2020-output/

Unlike 2024, VEST covers the whole country for 2020: all 50 states *and* the
District of Columbia are published as a single precinct shapefile carrying both
the geometry and the returns.  There is therefore no MEDSL fallback here and no
state without precinct boundaries — every code path is the VEST one.

Candidates and parties are not stored in the databases.  They live in dbs.json
and are identified by deterministic UUIDs (uuid5) derived from the election
name, so the 2020 ids are distinct from the 2024 ones and re-running the import
always reproduces them.
"""

from __future__ import annotations

import argparse
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
INPUT_DIR = ROOT / "data" / "2020-raw-data"
# The Harvard Dataverse bundle unpacks to this directory; the per-state archives
# sit directly inside it next to documentation.txt.
ARCHIVE_DIR = INPUT_DIR / "dataverse_files (1)"
OUTPUT_ROOT = ROOT / "data" / "2020-output"
ELECTION_NAME = "2020-National-President"
ELECTION_DESCRIPTION = "2020 National President Election"
OFFICE = "President"
OUTPUT_DIR = OUTPUT_ROOT / ELECTION_NAME
NATIONAL_DB = OUTPUT_DIR / "National.db"
DB_LIST = OUTPUT_ROOT / "dbs.json"
CDN_BASE = "https://files.xp-oncology.cn/gerrymander"

# Deterministic id namespace, shared with import_to_sqlite.py.  Never change
# these strings: doing so invalidates every candidate_id already written into a
# state database.
ID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://gerrymanderx.app/elections")


def party_uuid(code: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{ELECTION_NAME}/party/{code}"))


def candidate_uuid(code: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{ELECTION_NAME}/candidate/{OFFICE}/{code}"))


STATE_NAMES = {
    "ak": "Alaska", "al": "Alabama", "ar": "Arkansas", "az": "Arizona",
    "ca": "California", "co": "Colorado", "ct": "Connecticut",
    "dc": "District of Columbia", "de": "Delaware", "fl": "Florida",
    "ga": "Georgia", "hi": "Hawaii", "ia": "Iowa", "id": "Idaho",
    "il": "Illinois", "in": "Indiana", "ks": "Kansas", "ky": "Kentucky",
    "la": "Louisiana", "ma": "Massachusetts", "md": "Maryland", "me": "Maine",
    "mi": "Michigan", "mn": "Minnesota", "mo": "Missouri", "ms": "Mississippi",
    "mt": "Montana", "nc": "North Carolina", "nd": "North Dakota",
    "ne": "Nebraska", "nh": "New Hampshire", "nj": "New Jersey",
    "nm": "New Mexico", "nv": "Nevada", "ny": "New York", "oh": "Ohio",
    "ok": "Oklahoma", "or": "Oregon", "pa": "Pennsylvania",
    "ri": "Rhode Island", "sc": "South Carolina", "sd": "South Dakota",
    "tn": "Tennessee", "tx": "Texas", "ut": "Utah", "va": "Virginia",
    "vt": "Vermont", "wa": "Washington", "wi": "Wisconsin",
    "wv": "West Virginia", "wy": "Wyoming",
}

# Party code -> (display name, ARGB colour).  The colours mirror the palette in
# lib/modules/elections/widgets/map/map_painters.dart, so the 2020 set is kept
# identical to 2024's: minor parties collapse into Independent or Other rather
# than introducing colours the map has no rendering rule for.
PARTIES = {
    "DEM": ("Democrat", 0xFF2166AC),
    "REP": ("Republican", 0xFFB2182B),
    "LIB": ("Libertarian", 0xFFFFC107),
    "GRN": ("Green", 0xFF4CAF50),
    "IND": ("Independent", 0xFF9E9E9E),
    "WRI": ("Write-In", 0xFF757575),
    "OTH": ("Other", 0xFF616161),
}
# VEST column party letter -> party code.  2020 uses far more letters than 2024
# because minor parties ran under state-specific labels (C for Constitution,
# A for Alliance / American Solidarity, S for Socialism and Liberation, ...).
# Only the seven above exist as parties here, so anything unrecognised lands in
# "Other"; the canonical party of a known candidate comes from CANDIDATES.
PARTY_LETTERS = {"D": "DEM", "R": "REP", "L": "LIB", "G": "GRN",
                 "I": "IND", "W": "WRI", "O": "OTH"}

# VEST candidate code -> (display name, canonical party).  Taken from the
# per-state legends in documentation.txt, which spell out every G20PRE column.
# The party recorded here is the candidate's national one, not whatever ballot
# line a single state used: Don Blankenship is the Constitution Party nominee
# even though Nevada lists him as Independent American and Michigan as US
# Taxpayers, and Howie Hawkins is Green even where he appears as Mountain Party
# (WV) or as a write-in (WI).
CANDIDATES = {
    "BID": ("Biden", "DEM"),
    "TRU": ("Trump", "REP"),
    "JOR": ("Jorgensen", "LIB"),
    "HAW": ("Hawkins", "GRN"),
    # Alaska's Green Party nominated Jesse Ventura instead of Hawkins.
    "VEN": ("Ventura", "GRN"),
    "BLA": ("Blankenship", "OTH"),
    "CAR": ("Carroll", "OTH"),
    "DEL": ("De La Fuente", "OTH"),
    "LAR": ("La Riva", "OTH"),
    "KEN": ("Kennedy", "OTH"),
    "MYE": ("Myers", "OTH"),
    "SEG": ("Segal", "OTH"),
    "TIT": ("Tittle", "OTH"),
    "HUN": ("Hunter", "OTH"),
    "HAM": ("Hammons", "OTH"),
    "KIN": ("King", "OTH"),
    "WES": ("West", "IND"),
    "PIE": ("Pierce", "IND"),
    "COL": ("Collins", "IND"),
    "GAM": ("Gammon", "IND"),
    "MCH": ("McHugh", "IND"),
    "SIM": ("Simmons", "IND"),
    "BOD": ("Boddie", "WRI"),
    "CHA": ("Charles", "WRI"),
    "WEL": ("Wells", "WRI"),
    "SAN": ("Sanders", "WRI"),
    # Nevada is the only state with a formal "none of the above" ballot line.
    "NON": ("None Of These Candidates", "OTH"),
    "WRI": ("Write-In", "WRI"),
    "OTH": ("Other", "OTH"),
}

# One person, two VEST codes: states that print the surname as "De La Fuente"
# yield DEL, states that print "Fuente" yield FUE.  Collapsing them keeps Rocky
# De La Fuente a single candidate nationally instead of two half-candidates.
# No state uses both codes, so no state's votes are affected by the merge.
CANDIDATE_ALIASES = {"FUE": "DEL"}

# 2020 congressional maps: one district for the whole state, and DC's non-voting
# delegate, which the Census encodes as district 98.
AT_LARGE_STATES = {"AK", "DC", "DE", "MT", "ND", "SD", "VT", "WY"}

# Coordinate grid, in degrees, that vertices are snapped to (~1.1 m).  See the
# note in import_to_sqlite.py: snapping beats simplify() because neighbouring
# precincts snap to the same grid points, so shared borders stay coincident
# instead of developing slivers and gaps.
COORD_GRID = 1e-5

# Authoritative Census cartographic boundaries, 2020 vintage.  Using the 2020
# files rather than the 2023 ones the 2024 importer reads is not cosmetic:
# Connecticut replaced its eight counties with nine planning regions in 2022, so
# the 2023 county file cannot be joined to a 2020 county FIPS at all.
#   https://www2.census.gov/geo/tiger/GENZ2020/shp/
STATE_OUTLINES = INPUT_DIR / "cb_2020_us_state_500k.zip"
COUNTY_OUTLINES = INPUT_DIR / "cb_2020_us_county_500k.zip"
# The 116th Congress sat for the 2020 election; the 118th districts the 2024
# importer uses did not exist yet.
CD_OUTLINES = INPUT_DIR / "cb_2020_us_cd116_500k.zip"

STATE_SCHEMA = """
CREATE TABLE counties (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL);
CREATE TABLE congressional_districts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL);
CREATE TABLE precincts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, boundary BLOB, center_lat REAL, center_lon REAL);
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
    return sorted(path for path in workdir.rglob("*")
                  if path.suffix.lower() in {".shp", ".geojson", ".json"})


PRESIDENT_COLUMN = re.compile(r"^G20PRE([A-Z])([A-Z0-9]{3,})$")


def president_columns(frame: gpd.GeoDataFrame) -> list[tuple[str, str]]:
    """Return [(source column, candidate code)] for 2020 president.

    Several columns can map to the same code — Arkansas prints "Fuente" where
    Alaska prints "De La Fuente" — so this is a list, not a dict; the caller
    sums them instead of letting the last column win.
    """
    result: list[tuple[str, str]] = []
    for original in frame.columns:
        match = PRESIDENT_COLUMN.fullmatch(str(original).upper())
        if not match:
            continue
        code = CANDIDATE_ALIASES.get(match.group(2)[:3], match.group(2)[:3])
        register_candidate(code, match.group(1))
        result.append((str(original), code))
    return result


# Every spelling of the congressional-district field seen across the 2020
# archives.  CDDIST is California's (from the Statewide Database) and CONGRESS
# is New Jersey's; no other state carries the district on the precinct layer.
# Note that AK, GA, IA and MA all have a field literally named DISTRICT which is
# *not* congressional — it is a state house district or a precinct code — so
# that name is deliberately absent from this list.
DISTRICT_FIELDS = ["CONG_DIST", "CONGDIST", "CONGRESS", "CONGRESSIONAL_DISTRICT",
                   "CD", "CDDIST", "USCD", "US_CD", "CD116"]

COUNTY_FIPS_FIELDS = ["COUNTYFP", "COUNTYFP20", "COUNTYFP10", "COUNTY_FIP",
                      "COUNTY_FIPS", "COUNTYFIPS", "CNTY_FIPS", "FIPS_CODE", "FIPS2"]
COUNTY_NAME_FIELDS = ["COUNTY_NAME", "COUNTYNAME", "COUNTY_NAM", "CNTY_NAME",
                      "CONAME", "LOCALITY", "COUNTY", "CNTY"]

# Precinct label, most human-readable first.  A descriptive name is what the
# inspector panel shows, so "Fitchburg City Ward 2 Precinct A" beats the same
# precinct's GEOID; the numeric identifiers at the end are the last resort for
# the states that publish nothing else.
PRECINCT_FIELDS = ["PRECINCT_N", "PRECINCTNA", "PRECINCT_L", "WP_NAME", "PCTNAME",
                   "ENR_DESC", "NAMELSAD", "NAME20", "NAME", "SRPREC", "MUNINAME",
                   "PRECINCT", "PCT_CEB", "PCT_STD", "LABEL", "PCTNUM", "VTDST20",
                   "VTDST", "PRECINCTID", "SRPREC_KEY", "PCTKEY", "GEOID20",
                   "GEOID", "WARDID", "PRECINCT_I", "NUMBER", "PCODE"]

_census_layers: dict[Path, gpd.GeoDataFrame] = {}


def census_layer(path: Path) -> gpd.GeoDataFrame:
    if path not in _census_layers:
        if not path.exists():
            raise SystemExit(
                f"missing Census layer {path}.\nDownload it with:\n"
                f"  curl -o {path} https://www2.census.gov/geo/tiger/GENZ2020/shp/{path.name}")
        _census_layers[path] = gpd.read_file(f"/vsizip/{path}").to_crs("EPSG:4326")
    return _census_layers[path]


def state_fips(code: str) -> str:
    counties = census_layer(COUNTY_OUTLINES)
    match = counties[counties["STUSPS"] == code]
    if match.empty:
        raise ValueError(f"{code} is not in the Census county layer")
    return str(match["STATEFP"].iloc[0])


def normalize_district(value: object) -> str | None:
    if value is None or pd.isna(value) or str(value).strip() in {"", "0", "00", "nan"}:
        return None
    try:
        return str(int(float(value)))
    except (TypeError, ValueError):
        return str(value).strip()


def district_label(value: object) -> str | None:
    """Census encodes an at-large seat as '00' — and DC's delegate as '98' —
    both of which normalize_district would either discard or turn into a
    nonsensical "District 98"."""
    if str(value).strip() in {"00", "98"}:
        return "At-large"
    return normalize_district(value)


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


NAME_SUFFIX = re.compile(
    r"\s+(COUNTY|PARISH|BOROUGH|CENSUS AREA|CITY AND BOROUGH|MUNICIPALITY|CITY)\s*$")


def name_key(value: object) -> str:
    text = NAME_SUFFIX.sub("", str(value).upper().strip())
    return re.sub(r"[^A-Z0-9]", "", text)


def county_tables(statefp: str) -> tuple[dict[str, str], dict[str, str]]:
    """({county FIPS: display name}, {normalised name: display name}) for a state.

    The display name is the Census NAME, except where a state uses one name
    twice — Maryland's Baltimore County and Baltimore city, Virginia's several
    county/city pairs, Missouri's St. Louis — in which case the full NAMELSAD
    keeps them apart.  Without this the two dissolve into a single county with a
    boundary spanning both.
    """
    counties = census_layer(COUNTY_OUTLINES)
    counties = counties[counties["STATEFP"] == statefp]
    repeated = set(counties["NAME"][counties["NAME"].duplicated(keep=False)])
    display = {str(row["COUNTYFP"]): str(row["NAMELSAD"] if row["NAME"] in repeated
                                         else row["NAME"])
               for _, row in counties.iterrows()}
    by_name: dict[str, str] = {}
    for _, row in counties.iterrows():
        by_name.setdefault(name_key(row["NAMELSAD"]), display[str(row["COUNTYFP"])])
    for _, row in counties.iterrows():
        if row["NAME"] not in repeated:
            by_name.setdefault(name_key(row["NAME"]), display[str(row["COUNTYFP"])])
    return display, by_name


def locate(frame: gpd.GeoDataFrame, layer: gpd.GeoDataFrame, field: str,
           code: str, label: str) -> pd.Series:
    """Assign each row the `field` of the polygon it sits in.

    A precinct whose interior point lands outside every polygon — coastal
    precincts reach into water that the cartographic boundary files clip away —
    is resolved against the nearest polygon instead of being dropped.  The layer
    is always restricted to the precinct's own state beforehand, so "nearest"
    cannot stray outside the set of answers that were possible anyway.
    """
    points = gpd.GeoDataFrame(geometry=frame.geometry.representative_point(), crs=frame.crs)
    joined = gpd.sjoin(points, layer[[field, "geometry"]], how="left", predicate="within")
    joined = joined[~joined.index.duplicated(keep="first")]
    values = joined[field]
    missing = values.isna()
    if missing.any():
        # sjoin_nearest measures in the CRS it is given, and ranking distances
        # in degrees is meaningless at high latitudes; a metric projection makes
        # the comparison honest (and silences GeoPandas' warning about it).
        metric = "EPSG:3857"
        nearest = gpd.sjoin_nearest(points[missing.values].to_crs(metric),
                                    layer[[field, "geometry"]].to_crs(metric), how="left")
        nearest = nearest[~nearest.index.duplicated(keep="first")]
        values = values.fillna(nearest[field])
        print(f"[{code}] {int(missing.sum())} precincts fell outside every {label} "
              f"polygon; resolved to the nearest one", flush=True)
    return values


def resolve_counties(gdf: gpd.GeoDataFrame, code: str, statefp: str) -> list[str]:
    """Name the county of every precinct, preferring the state's own field.

    VEST publishes the county either as a FIPS code (most states), as a name
    (California, Iowa, New Jersey, ...) or not at all (Alaska, Delaware,
    Massachusetts).  FIPS is tried first even where a name field also exists so
    that every state ends up with the Census spelling; a state-specific code the
    Census does not know — Arizona's two-letter CDE_COUNTY, Maryland's JURSCODE
    — falls through to locating the precinct in the county polygons.
    """
    by_fips, by_name = county_tables(statefp)
    counties = census_layer(COUNTY_OUTLINES)
    counties = counties[counties["STATEFP"] == statefp]

    def from_fips(value: object) -> str | None:
        digits = re.sub(r"\D", "", str(value))
        return by_fips.get(digits[-3:].zfill(3)) if digits else None

    def from_name(value: object) -> str | None:
        key = name_key(value)
        return by_name.get(key) if key else None

    for field in COUNTY_FIPS_FIELDS + COUNTY_NAME_FIELDS:
        column = first_column(gdf, [field])
        if column is None:
            continue
        for reader, how in ((from_fips, "FIPS"), (from_name, "name")):
            names = [reader(value) for value in gdf[column]]
            found = sum(1 for name in names if name)
            if found < len(gdf) * 0.9:
                continue
            if found < len(gdf):
                print(f"[{code}] {len(gdf) - found} precincts have no usable "
                      f"{column}; locating them in the county polygons", flush=True)
                blank = [index for index, name in enumerate(names) if not name]
                located = locate(gdf.iloc[blank], counties, "COUNTYFP", code, "county")
                for index, value in zip(blank, located):
                    names[index] = by_fips.get(str(value), "Unknown")
            print(f"[{code}] county from {column} ({how})", flush=True)
            return [str(name) for name in names]

    print(f"[{code}] no usable county field; locating {len(gdf)} precincts in the "
          f"Census county polygons", flush=True)
    return [by_fips.get(str(value), "Unknown")
            for value in locate(gdf, counties, "COUNTYFP", code, "county")]


def resolve_districts(gdf: gpd.GeoDataFrame, code: str, statefp: str) -> list[str | None]:
    """Assign each precinct its 116th-Congress district.

    Only California and New Jersey carry the district on the precinct layer; for
    everyone else it comes from locating the precinct in the Census district
    polygons.  A precinct that straddles two districts is therefore recorded in
    exactly one of them — the 2020 VEST release ships a single layer with no
    split-precinct rows, so unlike 2024 there is nothing finer to model.
    """
    column = first_column(gdf, DISTRICT_FIELDS)
    if column is not None:
        labels = [normalize_district(value) for value in gdf[column]]
        if sum(1 for label in labels if label) >= len(gdf) * 0.9:
            print(f"[{code}] district from {column}", flush=True)
            return labels

    if code in AT_LARGE_STATES:
        print(f"[{code}] single at-large district", flush=True)
        return ["At-large"] * len(gdf)

    districts = census_layer(CD_OUTLINES)
    districts = districts[districts["STATEFP"] == statefp]
    if districts.empty:
        return [None] * len(gdf)
    print(f"[{code}] no district field; locating {len(gdf)} precincts in the "
          f"{len(districts)} Census district polygons", flush=True)
    return [district_label(value)
            for value in locate(gdf, districts, "CD116FP", code, "district")]


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

    with tempfile.TemporaryDirectory(prefix=f"gerrymander20-{code}-") as temp:
        paths = vector_paths(archive, Path(temp))
        if not paths:
            raise ValueError("archive contains no Shapefile or GeoJSON")
        base_path = paths[0]
        print(f"[{code}] reading {base_path.relative_to(temp)}", flush=True)
        gdf = gpd.read_file(base_path)
        if gdf.empty:
            raise ValueError("precinct layer is empty")
        if gdf.crs is None:
            raise ValueError("precinct layer has no CRS")
        gdf = gdf.to_crs("EPSG:4326")
        # A third of the 2020 shapefiles are "Polygon Z".  The elevation is
        # meaningless here and only inflates every stored boundary by 50%.
        gdf["geometry"] = shapely.force_2d(gdf.geometry.values)
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
            raise ValueError("no recognizable 2020 presidential-result columns")

        statefp = state_fips(code)
        precinct_field = first_column(gdf, PRECINCT_FIELDS)
        gdf["__county"] = resolve_counties(gdf, code, statefp)
        gdf["__precinct"] = ([as_text(value, f"Precinct_{index + 1}")
                              for index, value in enumerate(gdf[precinct_field])]
                             if precinct_field else
                             [f"Precinct_{index + 1}" for index in range(len(gdf))])
        gdf["__district"] = resolve_districts(gdf, code, statefp)
        blank = gdf["__district"].isna().sum()
        if blank:
            print(f"[{code}] {blank} precincts have no congressional district", flush=True)

        # Dissolving is where geometry really blows up: unioning thousands of
        # precincts keeps a node for every near-duplicate vertex along shared
        # borders, which is how a single county ends up with 1.6 M vertices.
        # Snapping the result collapses those back onto the grid.
        state_geom = snap_geometry(gdf.geometry.union_all(), code)
        county_geoms = snap_to_grid(gdf.dissolve(by="__county").geometry, code)
        placed = gdf[gdf["__district"].notna()]
        district_geoms = (snap_to_grid(placed.dissolve(by="__district").geometry, code)
                          if not placed.empty else gpd.GeoSeries([], dtype=object))
        if district_geoms.empty and code in AT_LARGE_STATES:
            district_geoms = gpd.GeoSeries([state_geom], index=["At-large"], crs=gdf.crs)
            gdf["__district"] = "At-large"
        if len(district_geoms) == 1:
            # A state with a single district has every precinct in it by
            # definition; no geometry needs to place them.
            gdf["__district"] = district_geoms.index[0]
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
            lat, lon = center(row.geometry)
            db.execute("INSERT INTO precincts(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)", (precinct_id, row["__precinct"], wkb(row.geometry), lat, lon))
            db.execute("INSERT INTO county_precincts(precinct_id,county_id) VALUES (?,?)", (precinct_id, county_ids[row["__county"]]))
            if row["__district"] in district_ids:
                db.execute("INSERT INTO congressional_district_precincts(precinct_id,congressional_district_id) VALUES (?,?)", (precinct_id, district_ids[row["__district"]]))
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
    return {"code": code, "state": state_name, "precincts": len(gdf),
            "counties": len(county_ids), "districts": len(district_ids),
            "votes": sum(candidate_totals.values())}


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
    stems = ["National"] + sorted(path.stem for path in OUTPUT_DIR.glob("*.db")
                                  if path.stem != "National")
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
          f"({len(payload[0]['candidates'])} candidates, "
          f"{len(payload[0]['parties'])} parties, {len(stems)} dbs)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--overwrite", action="store_true", help="rebuild an already existing state database")
    parser.add_argument("--states", nargs="*", help="two-letter state codes to import (default: every ZIP in data/2020-raw-data)")
    parser.add_argument("--manifest-only", action="store_true", help="only rewrite data/2020-output/dbs.json")
    parser.add_argument("--outlines-only", action="store_true", help="only refresh National.db state boundaries")
    args = parser.parse_args()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if args.manifest_only:
        update_manifest()
        return
    if args.outlines_only:
        national = sqlite3.connect(NATIONAL_DB)
        apply_state_outlines(national)
        national.close()
        return

    # xx_2020.zip only: the bundle also ships ky_2020_vtd_estimates.zip and
    # nj_2020_vtd_estimates.zip, which are alternative disaggregations of the
    # same returns onto Census VTDs rather than the states' own precincts.
    archives = [path for path in sorted(ARCHIVE_DIR.glob("*_2020.zip"))
                if path.stem[:2].lower() in STATE_NAMES and len(path.stem) == 7]
    wanted = {item.upper() for item in args.states or []}
    if wanted:
        archives = [path for path in archives if path.name[:2].upper() in wanted]
    if not archives:
        raise SystemExit(f"no state archives found under {ARCHIVE_DIR}")

    national = sqlite3.connect(NATIONAL_DB)
    ensure_national_schema(national)
    failures = []
    for archive in archives:
        try:
            print(import_state(archive, national, args.overwrite), flush=True)
        except Exception as error:
            national.rollback()
            failures.append((archive.name, str(error)))
            print(f"FAILED {archive.name}: {error}", flush=True)

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
