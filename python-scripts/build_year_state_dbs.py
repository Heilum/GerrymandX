#!/usr/bin/env python3
"""Build new_data/<year>/ for the 2000–2023 elections, in the 2024 layout.

Every year gets one SQLite file per state (new_data/<year>/<CODE>-<year>.db),
a National-<year>.db, a manifest.json and a BUILD_REPORT.md, exactly like
build_2024_state_dbs.py writes for 2024, and new_elections.json gains a
"<year>" key.  The database schema is the 2024 one (schema 2): geometry
tables + elections / parties / candidates / precinct_results / meta.

Where the returns come from depends on the year — see YEAR_PLAN below:

  precinct level (VEST shapefiles from the Harvard Dataverse)
      2012 (FL, KS only), 2016, 2017 (AL, NJ, VA), 2018, 2020 (geometry reused
      from data/2020-output), 2021 (NJ, VA).  US House races the VEST layer
      lacks are filled in from MEDSL precinct returns where the precinct names
      can be matched (2016, 2018).
  county level
      2000–2015 and 2019: Algara & Amlani county returns (President, US Senate,
      Governor — Democratic and Republican nominees plus "Other").
      2022: MEDSL precinct returns aggregated to county × congressional
      district pieces, so US House races map exactly.
      2023: OpenElections (KY, MS) and the Louisiana SOS (LA) governor races.

A county-level database still has every table the app reads: each county is
also its own "precinct".  meta.level says which kind a database is.

Run from this directory:
    .venv/bin/python build_year_state_dbs.py --years 2016 2018 [--states TX KS]
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import re
import shutil
import sqlite3
import sys
import traceback
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import geopandas as gpd
import pandas as pd
import shapely
from shapely.ops import unary_union

import build_2024_state_dbs as b24
import import_2020_to_sqlite as i20

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
CENSUS = DATA / "census"
OUT_ROOT = ROOT / "new_data"
CDN_BASE = "https://files.xp-oncology.cn/gerrymander"
NEW_ELECTIONS = OUT_ROOT / "new_elections.json"
STATE_OUTLINES = DATA / "2020-raw-data" / "cb_2020_us_state_500k.zip"

ID_NAMESPACE = b24.ID_NAMESPACE
OFFICES = b24.OFFICES
OFFICE_SLUG = b24.OFFICE_SLUG
STATE_NAMES = i20.STATE_NAMES
CODE_BY_NAME = {name: code.upper() for code, name in STATE_NAMES.items()}
STATE_FIPS = {
    "AL": "01", "AK": "02", "AZ": "04", "AR": "05", "CA": "06", "CO": "08", "CT": "09", "DE": "10",
    "DC": "11", "FL": "12", "GA": "13", "HI": "15", "ID": "16", "IL": "17", "IN": "18", "IA": "19",
    "KS": "20", "KY": "21", "LA": "22", "ME": "23", "MD": "24", "MA": "25", "MI": "26", "MN": "27",
    "MS": "28", "MO": "29", "MT": "30", "NE": "31", "NV": "32", "NH": "33", "NJ": "34", "NM": "35",
    "NY": "36", "NC": "37", "ND": "38", "OH": "39", "OK": "40", "OR": "41", "PA": "42", "RI": "44",
    "SC": "45", "SD": "46", "TN": "47", "TX": "48", "UT": "49", "VT": "50", "VA": "51", "WA": "53",
    "WV": "54", "WI": "55", "WY": "56",
}

VEST_DIRS = {
    2012: DATA / "2012-raw-data", 2016: DATA / "2016-raw-data", 2017: DATA / "2017-raw-data",
    2018: DATA / "2018-raw-data", 2020: DATA / "2020-raw-data" / "dataverse_files (1)",
    2021: DATA / "2021-raw-data",
}
OLD_2020_DIR = DATA / "2020-output" / "2020-National-President"
COUNTY_RAW = DATA / "county-raw-data"
DGUMFI = {"President": COUNTY_RAW / "f_5028532", "US Senate": COUNTY_RAW / "f_5028534",
          "Governor": COUNTY_RAW / "f_5028535"}
MEDSL_2022 = DATA / "2022-raw-data" / "medsl"
MEDSL_2018 = DATA / "2018-raw-data" / "medsl"
MEDSL_2016_HOUSE = DATA / "2016-raw-data" / "medsl" / "2016-precinct-house.csv"
OE_2023 = DATA / "2023-raw-data"

# Single-district states, by election year.  Montana regained a second seat
# in 2022; DC's delegate seat is treated as at-large.
AT_LARGE = {"AK", "DC", "DE", "MT", "ND", "SD", "VT", "WY"}
AT_LARGE_2022 = {"AK", "DC", "DE", "ND", "SD", "VT", "WY"}
# Years (or the states VEST does not cover in them) that are built from county returns.
COUNTY_YEARS = set(range(2000, 2016)) | {2018, 2019, 2023}


def at_large_states(year: int) -> set[str]:
    return AT_LARGE_2022 if year >= 2022 else AT_LARGE


def county_layer_path(year: int) -> Path:
    """Census county boundaries of the vintage closest to the election."""
    if year <= 2001:
        return CENSUS / "co99_d00_shp.zip"
    if year <= 2013:
        return CENSUS / "gz_2010_us_050_00_500k.zip"
    if year <= 2015:
        return CENSUS / "cb_2014_us_county_500k.zip"
    if year <= 2017:
        return CENSUS / "cb_2016_us_county_500k.zip"
    if year <= 2019:
        return CENSUS / "cb_2018_us_county_500k.zip"
    if year <= 2021:
        return DATA / "2020-raw-data" / "cb_2020_us_county_500k.zip"
    # Connecticut's planning regions replaced its counties in the 2022 file;
    # the 2022/2023 returns are still reported by the old counties.
    return CENSUS / "cb_2021_us_county_500k.zip"


def cd_layer(year: int) -> tuple[Path, str] | None:
    """(Census congressional-district file, district field) for a House election year."""
    if year in (2016, 2017):
        return CENSUS / "cb_2016_us_cd115_500k.zip", "CD115FP"
    if year in (2018, 2019):
        return CENSUS / "cb_2018_us_cd116_500k.zip", "CD116FP"
    if year in (2020, 2021):
        return DATA / "2020-raw-data" / "cb_2020_us_cd116_500k.zip", "CD116FP"
    if year in (2022, 2023):
        return CENSUS / "cb_2022_us_cd118_500k.zip", "CD118FP"
    return None


# --------------------------------------------------------------------------- parties

PARTY_INFO = dict(b24.PARTY_INFO)
PARTY_INFO.update({
    "REF": ("Reform", 0xFF8D6E63), "SOC": ("Socialist", 0xFFD32F2F), "JUS": ("Justice", 0xFF5C6BC0),
    "OBJ": ("Objectivist", 0xFF78909C), "PSL": ("Socialism and Liberation", 0xFFC62828),
    "ASP": ("American Solidarity", 0xFF6D4C41), "LLP": ("Life and Liberty", 0xFF8D6E63),
    "LMN": ("Legal Marijuana Now", 0xFF7CB342), "GRP": ("Grassroots", 0xFF7CB342),
    "IDP": ("Independence", 0xFF9E9E9E), "WEP": ("Women's Equality", 0xFF8E24AA),
    "UUP": ("United Utah", 0xFF5C6BC0), "VET": ("Veterans", 0xFF546E7A), "PRO": ("Prohibition", 0xFF6D4C41),
    "ADP": ("American Delta", 0xFF00897B), "AVP": ("Approval Voting", 0xFF00ACC1),
    "LUP": ("Liberty Union", 0xFF7E57C2), "MOD": ("Moderate", 0xFF78909C), "SWP": ("Socialist Workers", 0xFFD32F2F),
    "WWP": ("Workers World", 0xFFD32F2F), "PRG": ("Progressive", 0xFF7E57C2), "DFL": ("Democrat", 0xFF2166AC),
    "AME": ("American Shopping", 0xFF9E9E9E), "TEA": ("Tea Party", 0xFFEF6C00), "SEP": ("Socialist Equality", 0xFFD32F2F),
    "NEW": ("New Alliance", 0xFF9E9E9E), "IAM": ("Independent American", 0xFF8D6E63),
    "BLU": ("Blue Enigma", 0xFF9E9E9E), "TRP": ("Transhumanist", 0xFF9E9E9E), "BOS": ("Boston Tea", 0xFFEF6C00),
    "NUP": ("Nutrition", 0xFF9E9E9E), "NAT": ("National", 0xFF9E9E9E), "GOP": ("Republican", 0xFFB2182B),
    "GRT": ("Green-Rainbow", 0xFF4CAF50), "PRP": ("Peace and Prosperity", 0xFF00897B), "DCS": ("DC Statehood Green", 0xFF4CAF50),
    "UNI": ("Unity", 0xFF9E9E9E), "SCP": ("Socialist USA", 0xFFD32F2F), "LDR": ("Leadership", 0xFF9E9E9E),
    "AMC": ("American Constitution", 0xFF8D6E63), "IPD": ("Independence-Alliance", 0xFF9E9E9E),
})
# Party phrase -> code; checked in order against the lower-cased legend text.
PARTY_PHRASES = [
    ("write-in", "WRI"), ("write in", "WRI"), ("writein", "WRI"), ("scattering", "WRI"),
    ("democratic-farmer-labor", "DEM"), ("democratic-npl", "DEM"), ("democrat", "DEM"), ("dfl", "DEM"),
    ("republican", "REP"), ("gop", "REP"), ("libertarian", "LIB"),
    ("green-rainbow", "GRN"), ("dc statehood green", "GRN"), ("pacific green", "GRN"), ("green", "GRN"),
    ("american constitution", "CST"), ("constitution", "CST"), ("us taxpayers", "UST"), ("u.s. taxpayers", "UST"),
    ("working families", "WFP"), ("working class", "WCP"), ("conservative", "CON"),
    ("alaskan independence", "AKI"), ("independence-alliance", "ALP"), ("new alliance", "NEW"),
    ("alliance", "ALP"), ("independence", "IDP"),
    ("women's equality", "WEP"), ("legal marijuana now", "LMN"), ("grassroots", "GRP"),
    ("socialism and liberation", "PSL"), ("socialist workers", "SWP"), ("socialist equality", "SEP"),
    ("socialist usa", "SOC"), ("workers world", "WWP"), ("socialist", "SOC"),
    ("american solidarity", "ASP"), ("life and liberty", "LLP"), ("peace and freedom", "PFP"),
    ("peace and justice", "PAJ"), ("peace and prosperity", "PRP"), ("natural law", "NLP"), ("mountain", "MTN"),
    ("reform", "REF"), ("justice", "JUS"), ("objectivist", "OBJ"), ("america's", "AMR"), ("american party", "AMR"),
    ("american independent", "AIP"), ("independent american", "IAP"), ("american delta", "ADP"),
    ("approval voting", "AVP"), ("united utah", "UUP"), ("veterans", "VET"), ("prohibition", "PRO"),
    ("liberty union", "LUP"), ("moderate", "MOD"), ("progressive", "PRG"), ("tea party", "TEA"),
    ("transhumanist", "TRP"), ("boston tea", "BOS"), ("nutrition", "NUP"),
    ("unity", "UNI"), ("forward", "FWD"),
    ("nonpartisan", "NON"), ("non-partisan", "NON"), ("no party affiliation", "NPA"), ("no party", "NPA"),
    ("unaffiliated", "NPA"), ("unenrolled", "UNE"), ("nopty", "NPA"), ("npa", "NPA"),
    ("independent", "IND"), ("other", "OTH"),
]
PARTY_LETTERS = {"D": "DEM", "R": "REP", "L": "LIB", "G": "GRN", "I": "IND", "W": "WRI", "O": "OTH",
                 "C": "CST", "N": "NPA", "U": "NPA"}


def party_from_text(text: str | None) -> str | None:
    if not text:
        return None
    lowered = text.lower().strip()
    for phrase, code in PARTY_PHRASES:
        if phrase in lowered:
            return code
    return None


def register_party(text: str) -> str:
    """Code for a party the tables do not know: three letters from its name."""
    words = [w for w in re.findall(r"[A-Za-z]+", text) if w.lower() not in ("party", "the", "of", "and")]
    if not words:
        return "OTH"
    code = ("".join(w[0] for w in words)[:3] if len(words) >= 3 else words[0][:3]).upper()
    if code in PARTY_INFO and PARTY_INFO[code][0].lower() != text.lower():
        code = (words[0][:2] + words[-1][:1]).upper()
    PARTY_INFO.setdefault(code, (text.strip(), 0xFF616161))
    return code


def party_code(text: str | None, letter: str | None) -> str:
    code = party_from_text(text)
    if code:
        return code
    if text and text.strip():
        return register_party(re.sub(r"\s*party\s*$", "", text.strip(), flags=re.I))
    return PARTY_LETTERS.get(letter or "O", "OTH")


# --------------------------------------------------------------------------- ids


def party_uuid(code: str, year: int, slug: str, party: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{code}-{year}/{slug}/party/{party}"))


def candidate_uuid(code: str, year: int, slug: str, candidate: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{code}-{year}/{slug}/candidate/{candidate}"))


Contest = b24.Contest
Candidate = b24.Candidate


def contest_map() -> tuple[dict[str, Contest], callable]:
    contests: dict[str, Contest] = {}

    def get(office: str, special: bool = False) -> Contest:
        key = b24.election_slug(office, special)
        if key not in contests:
            contests[key] = Contest(office, special)
        return contests[key]
    return contests, get


def clean_name(name: str) -> str:
    name = re.sub(r"\s+", " ", name).strip(" -:")
    if name and name == name.upper() and len(name) > 3:
        return b24.title_case(name)
    words = []
    for word in name.split(" "):
        core = re.sub(r"[^A-Za-z]", "", word)
        if len(core) >= 3 and core == core.upper() and core not in b24.NAME_SUFFIXES:
            word = b24.title_case(word)
        words.append(word)
    return " ".join(words)


def last_first(name: str) -> str:
    """'Edwards, John Bel' -> 'John Bel Edwards' (Algara & Amlani style)."""
    if "," in name:
        last, first = name.split(",", 1)
        suffix = ""
        for token in ("Jr.", "Jr", "Sr.", "Sr", "III", "II", "IV"):
            if first.strip().endswith(" " + token):
                first = first.strip()[: -len(token) - 1]
                suffix = " " + token
        return f"{first.strip()} {last.strip()}{suffix}".strip()
    return name.strip()


# --------------------------------------------------------------------------- Census layers

_layers: dict[Path, gpd.GeoDataFrame] = {}
LSAD_WORDS = {"06": "County", "15": "Parish", "04": "Borough", "05": "Census Area", "12": "Municipality",
              "13": "City and Borough", "25": "city", "03": "City and Borough", "00": ""}


def read_zip_layer(path: Path, prefer: str | None = None) -> gpd.GeoDataFrame:
    with zipfile.ZipFile(path) as bundle:
        shps = [n for n in bundle.namelist() if n.lower().endswith(".shp")]
    if prefer:
        shps = [s for s in shps if prefer in s] or shps
    frame = gpd.read_file(f"/vsizip/{path}/{shps[0]}", engine="pyogrio")
    if frame.crs is None:
        frame = frame.set_crs("EPSG:4269")
    return frame.to_crs("EPSG:4326")


def county_layer(year: int) -> gpd.GeoDataFrame:
    """Counties of the vintage for `year`, normalised to STATEFP / COUNTYFP / GEOID / NAME / NAMELSAD."""
    path = county_layer_path(year)
    if path in _layers:
        return _layers[path]
    if not path.exists():
        raise SystemExit(f"missing Census county layer {path}")
    frame = read_zip_layer(path)
    if "STATEFP" not in frame.columns:
        frame = frame.rename(columns={"STATE": "STATEFP", "COUNTY": "COUNTYFP"})
    frame["STATEFP"] = frame["STATEFP"].astype(str).str.zfill(2)
    frame["COUNTYFP"] = frame["COUNTYFP"].astype(str).str.zfill(3)
    frame["GEOID"] = frame["STATEFP"] + frame["COUNTYFP"]
    if "NAMELSAD" not in frame.columns:
        if "LSAD_TRANS" in frame.columns:
            lsad = frame["LSAD_TRANS"].fillna("").astype(str)
        else:
            lsad = frame["LSAD"].fillna("").astype(str).map(lambda v: LSAD_WORDS.get(v, v))
        frame["NAMELSAD"] = (frame["NAME"].astype(str) + " " + lsad).str.strip()
    if frame["GEOID"].duplicated().any():  # co99_d00 stores one row per polygon part
        frame["geometry"] = shapely.force_2d(frame.geometry.values)
        frame = frame.dissolve(by="GEOID", aggfunc="first").reset_index()
    frame["geometry"] = shapely.force_2d(frame.geometry.values)
    frame["geometry"] = i20.repair(frame.geometry, "US", "county")
    frame["geometry"] = i20.snap_to_grid(frame.geometry, "US")
    frame["geometry"] = i20.repair(frame.geometry, "US", "snapped county")
    _layers[path] = frame
    return frame


def district_layer(year: int) -> tuple[gpd.GeoDataFrame, str] | None:
    spec = cd_layer(year)
    if spec is None:
        return None
    path, field = spec
    if path not in _layers:
        if not path.exists():
            raise SystemExit(f"missing Census district layer {path}")
        frame = read_zip_layer(path)
        frame["geometry"] = shapely.force_2d(frame.geometry.values)
        frame["geometry"] = i20.repair(frame.geometry, "US", "district")
        frame["geometry"] = i20.snap_to_grid(frame.geometry, "US")
        frame["geometry"] = i20.repair(frame.geometry, "US", "snapped district")
        _layers[path] = frame
    return _layers[path], field


def state_counties(year: int, code: str) -> gpd.GeoDataFrame:
    layer = county_layer(year)
    return layer[layer["STATEFP"] == STATE_FIPS[code]].copy()


def county_names(counties: gpd.GeoDataFrame) -> tuple[dict[str, str], dict[str, str]]:
    """({COUNTYFP: display}, {name key: display}); duplicates keep their LSAD."""
    repeated = set(counties["NAME"][counties["NAME"].duplicated(keep=False)])
    display = {row["COUNTYFP"]: str(row["NAMELSAD"] if row["NAME"] in repeated else row["NAME"])
               for _, row in counties.iterrows()}
    by_name: dict[str, str] = {}
    for _, row in counties.iterrows():
        by_name.setdefault(i20.name_key(row["NAMELSAD"]), display[row["COUNTYFP"]])
    for _, row in counties.iterrows():
        if row["NAME"] not in repeated:
            by_name.setdefault(i20.name_key(row["NAME"]), display[row["COUNTYFP"]])
    return display, by_name


def resolve_counties(gdf: gpd.GeoDataFrame, code: str, counties: gpd.GeoDataFrame, log: list[str]) -> list[str]:
    """Name every precinct's county — the layer's FIPS or name field, else geometry."""
    by_fips, by_name = county_names(counties)

    def from_fips(value: object) -> str | None:
        digits = re.sub(r"\D", "", str(value))
        return by_fips.get(digits[-3:].zfill(3)) if digits else None

    def from_name(value: object) -> str | None:
        key = i20.name_key(value)
        return by_name.get(key) if key else None

    for field in i20.COUNTY_FIPS_FIELDS + i20.COUNTY_NAME_FIELDS:
        column = i20.first_column(gdf, [field])
        if column is None:
            continue
        for reader, how in ((from_fips, "FIPS"), (from_name, "name")):
            names = [reader(value) for value in gdf[column]]
            found = sum(1 for name in names if name)
            if found < len(gdf) * 0.9:
                continue
            if found < len(gdf):
                blank = [index for index, name in enumerate(names) if not name]
                located = i20.locate(gdf.iloc[blank], counties, "COUNTYFP", code, "county")
                for index, value in zip(blank, located):
                    names[index] = by_fips.get(str(value), "Unknown")
                log.append(f"{len(blank)} precincts without a usable {column} were located in the county polygons")
            return [str(name) for name in names]
    log.append(f"no usable county field; {len(gdf)} precincts located in the Census county polygons")
    return [by_fips.get(str(value), "Unknown") for value in i20.locate(gdf, counties, "COUNTYFP", code, "county")]


def resolve_districts(gdf: gpd.GeoDataFrame, code: str, year: int, log: list[str]) -> list[str | None]:
    if code in at_large_states(year):
        return ["At-large"] * len(gdf)
    column = i20.first_column(gdf, i20.DISTRICT_FIELDS)
    if column is not None:
        labels = [i20.normalize_district(value) for value in gdf[column]]
        if sum(1 for label in labels if label) >= len(gdf) * 0.9:
            log.append(f"congressional district from the layer's {column} field")
            return labels
    spec = district_layer(year)
    if spec is None:
        return [None] * len(gdf)
    layer, field = spec
    districts = layer[layer["STATEFP"] == STATE_FIPS[code]]
    if districts.empty:
        return [None] * len(gdf)
    log.append(f"congressional district located in the {len(districts)} Census {field[:5]} polygons")
    return [i20.district_label(value) for value in i20.locate(gdf, districts, field, code, "district")]


# --------------------------------------------------------------------------- geometry bundle


class Geometry:
    """Everything write_state_db needs to fill the geometry tables."""

    def __init__(self) -> None:
        self.precincts: list[tuple[str, object]] = []   # (name, geometry), id = index + 1
        self.precinct_county: list[str] = []
        self.precinct_district: list[str | None] = []
        self.counties: dict[str, object] = {}
        self.districts: dict[str, object] = {}
        self.state_geom = None
        self.template: Path | None = None   # copy an existing database instead
        self.log: list[str] = []


def geometry_from_frame(gdf: gpd.GeoDataFrame, code: str, year: int, names: list[str],
                        counties: list[str], districts: list[str | None], log: list[str]) -> Geometry:
    geometry = Geometry()
    geometry.log = log
    geometry.precincts = list(zip(names, gdf.geometry.values))
    geometry.precinct_county = counties
    geometry.precinct_district = districts
    work = gdf[["geometry"]].copy()
    work["__county"] = counties
    work["__district"] = districts
    geometry.state_geom = i20.snap_geometry(gdf.geometry.union_all(), code)
    county_geoms = i20.snap_to_grid(work.dissolve(by="__county").geometry, code)
    geometry.counties = {str(k): v for k, v in county_geoms.items()}
    placed = work[work["__district"].notna()]
    if not placed.empty:
        district_geoms = i20.snap_to_grid(placed.dissolve(by="__district").geometry, code)
        geometry.districts = {str(k): v for k, v in district_geoms.items()}
    if len(geometry.districts) == 1:
        only = next(iter(geometry.districts))
        geometry.precinct_district = [only] * len(names)
    return geometry


def load_vest_frame(archive: Path, code: str) -> gpd.GeoDataFrame:
    with zipfile.ZipFile(archive) as bundle:
        members = [n for n in bundle.namelist() if n.lower().endswith(".shp")]
    ranked = sorted(members, key=lambda n: ("cong" in Path(n).stem.lower(), "sld" in Path(n).stem.lower(),
                                            len(Path(n).parts), n))
    if not ranked:
        raise ValueError("archive contains no shapefile")
    gdf = gpd.read_file(f"/vsizip/{archive}/{ranked[0]}", engine="pyogrio")
    if gdf.empty:
        raise ValueError("precinct layer is empty")
    if gdf.crs is None:
        raise ValueError("precinct layer has no CRS")
    gdf = gdf.to_crs("EPSG:4326")
    gdf["geometry"] = shapely.force_2d(gdf.geometry.values)
    gdf["geometry"] = i20.repair(gdf.geometry, code, "precinct")
    gdf["geometry"] = i20.snap_to_grid(gdf.geometry, code)
    dropped = gdf.geometry.isna() | gdf.geometry.is_empty
    if dropped.any():
        print(f"[{code}] dropping {int(dropped.sum())} precincts that collapsed when snapped", flush=True)
        gdf = gdf[~dropped].reset_index(drop=True)
    gdf["geometry"] = i20.repair(gdf.geometry, code, "snapped precinct")
    return gdf


def precinct_names(gdf: pd.DataFrame) -> list[str]:
    field = i20.first_column(gdf, i20.PRECINCT_FIELDS)
    if field is None:
        return [f"Precinct_{i + 1}" for i in range(len(gdf))]
    return [i20.as_text(v, f"Precinct_{i + 1}") for i, v in enumerate(gdf[field])]


def vest_geometry(gdf: gpd.GeoDataFrame, code: str, year: int) -> Geometry:
    log: list[str] = []
    counties = state_counties(year, code)
    names = precinct_names(gdf)
    county_of = resolve_counties(gdf, code, counties, log)
    district_of = resolve_districts(gdf, code, year, log)
    return geometry_from_frame(gdf, code, year, names, county_of, district_of, log)


def county_geometry(year: int, code: str) -> Geometry:
    """One precinct per county, in the vintage's Census boundaries."""
    counties = state_counties(year, code)
    if counties.empty:
        raise ValueError("no counties in the Census layer")
    display, _ = county_names(counties)
    counties = counties.sort_values("COUNTYFP").reset_index(drop=True)
    names = [display[fp] for fp in counties["COUNTYFP"]]
    geometry = geometry_from_frame(counties, code, year, names, names, [None] * len(names), [])
    geometry.precinct_district = [None] * len(names)
    geometry.districts = {}
    geometry.geoid_index = {geoid: i + 1 for i, geoid in enumerate(counties["GEOID"])}  # type: ignore[attr-defined]
    return geometry


# --------------------------------------------------------------------------- VEST returns

# Vote columns the VEST documentation leaves out: {state: {column: (name, party text)}}.
NAME_OVERRIDES = {
    "NE": {"G20USSLSIA": ("Gene Siadek", "Libertarian Party")},
    "OH": {"G20PREGHAW": ("Howie Hawkins", "Green Party")},
}

VEST_COLUMN = re.compile(r"^([GS])(\d\d)(PRE|USS|GOV|DEL|H(\d\d|AL))([A-Z])([A-Z0-9]{2,})$")


def read_legend(year: int) -> dict[str, dict[str, tuple[str, str | None]]]:
    """{state code: {COLUMN: (candidate name, party text)}} from documentation.txt."""
    path = VEST_DIRS[year] / "documentation.txt"
    legend: dict[str, dict[str, tuple[str, str | None]]] = {}
    if not path.exists():
        print(f"  ! {path} missing; candidate names fall back to the column codes", flush=True)
        return legend
    state = None
    lines = path.read_text(encoding="utf8", errors="ignore").splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped in CODE_BY_NAME and index + 1 < len(lines) and set(lines[index + 1].strip()) == {"-"}:
            state = CODE_BY_NAME[stripped]
            continue
        if state is None:
            continue
        match = re.match(r"^([GSRPC]\d\d[A-Za-z0-9]{4,})\s+-\s+(.+)$", stripped)
        if not match:
            continue
        description = match.group(2).strip()
        party = None
        pmatch = re.search(r"\(([^()]*)\)\s*$", description)
        if pmatch:
            party = pmatch.group(1).strip()
            description = description[: pmatch.start()].strip()
        legend.setdefault(state, {}).setdefault(match.group(1).upper(), (description, party))
    return legend


def vest_contests(frame: pd.DataFrame, code: str, year: int, precinct_ids: list[int | None],
                  legend: dict[str, tuple[str, str | None]]) -> list[Contest]:
    contests, get = contest_map()
    yy = f"{year % 100:02d}"
    for column in frame.columns:
        upper = str(column).upper()
        match = VEST_COLUMN.match(upper)
        if not match or match.group(2) != yy:
            continue
        prefix, _, office_code, district_raw, letter, rest = match.groups()
        if office_code == "DEL":
            if code != "DC":
                continue
            office, district = "US House", "At-large"
        elif office_code.startswith("H"):
            if code == "DC":
                continue   # the shadow representative, not the delegate
            office, district = "US House", ("At-large" if district_raw == "AL" else str(int(district_raw)))
        else:
            office = {"PRE": "President", "USS": "US Senate", "GOV": "Governor"}[office_code]
            district = None
            if code == "DC" and office != "President":
                continue   # DC's "senators" are shadow offices, not US Senate seats
        special = prefix == "S"
        name, party_text = legend.get(upper, (None, None))
        if name is None and upper in NAME_OVERRIDES.get(code, {}):
            name, party_text = NAME_OVERRIDES[code][upper]
        if name is None:
            name = {"WRI": "Write-in", "WR2": "Write-in", "OTH": "Other", "TH": "Other"}.get(rest, rest.capitalize())
        if re.match(r"^write-?\s?ins?( votes)?$", name, re.I):
            name, party_text = "Write-in", "Write-in"
        elif re.match(r"^other( candidates)?$", name, re.I):
            name, party_text = "Other", "Other"
        party = party_code(party_text, letter)
        if party == "WRI" and letter not in ("W", "O"):
            party = PARTY_LETTERS.get(letter, "OTH")
        target = get(office, special)
        if party == "WRI":
            letter, rest = "O", "WRI"
        ccode = f"{district}-{letter}{rest}" if district else f"{letter}{rest}"
        if ccode in target.candidates:
            target.candidates[ccode].columns.append(column)
        else:
            cand = Candidate(ccode, clean_name(name), party, district)
            cand.columns.append(column)
            target.candidates[ccode] = cand
    for target in contests.values():
        for cand in target.candidates.values():
            for column in cand.columns:
                values = frame[column].tolist()
                for row_index, value in enumerate(values):
                    pid = precinct_ids[row_index]
                    if pid is not None:
                        target.add(pid, cand.code, i20.as_int(value))
    return [c for c in contests.values() if c.total() > 0]


# --------------------------------------------------------------------------- MEDSL precinct returns (House supplement)


def norm_key(value: object) -> str:
    return re.sub(r"[^A-Z0-9]", "", str(value).upper())


PLACE_PREFIX = re.compile(r"^(TOWN|CITY|VILLAGE|TOWNSHIP|TWP|BOROUGH|BORO|PLANTATION|TOWN OF THE)\s+OF\s+", re.I)


def key_variants(value: object, _depth: int = 0) -> set[str]:
    """Normalised spellings a precinct label might be matched under."""
    text = str(value).strip().upper()
    if not text or text in ("NAN", "NONE"):
        return set()
    text = text.replace("&", " AND ")
    forms = {text}
    stripped = PLACE_PREFIX.sub("", text)
    forms.add(stripped)
    abbrev = re.sub(r"\b(PRECINCT|PCT|PREC|PRCT)\b", "P", stripped)
    abbrev = re.sub(r"\bWARD\b", "W", abbrev)
    abbrev = re.sub(r"\b(DISTRICT|DIST)\b", "D", abbrev)
    forms.add(abbrev)
    out: set[str] = set()
    for form in forms:
        out.add(norm_key(form))
        out.add(norm_key(re.sub(r"(?<![0-9])0+([0-9])", r"\1", form)))
        digits = re.sub(r"\D", "", form)
        if digits:
            out.add(digits.lstrip("0") or "0")
    if _depth == 0:
        for part in re.split(r"[|/,:;]| - ", text):
            part = part.strip()
            if part and part != text:
                out |= key_variants(part, 1)
    try:
        out.add(str(int(float(text))))
    except ValueError:
        pass
    return {k for k in out if k}


def medsl_rows_2016(code: str) -> list[dict]:
    rows = []
    if not MEDSL_2016_HOUSE.exists():
        return rows
    with MEDSL_2016_HOUSE.open(encoding="utf8", errors="ignore", newline="") as handle:
        for row in csv.DictReader(handle):
            if row["state_postal"] != code or row["stage"] != "gen" or row["office"] != "US House":
                continue
            if row["special"] == "True":
                continue
            fips = re.sub(r"\D", "", row["county_fips"].split(".")[0]).zfill(5) if row["county_fips"] else ""
            raw_district = row["district"].split(".")[0].strip()
            rows.append({"county_fips": fips, "county_name": row["county_name"], "precinct": row["precinct"],
                         "jurisdiction": row.get("jurisdiction", ""),
                         "candidate": row["candidate"], "party": row["party"], "party_detailed": row["party"],
                         "district": raw_district, "writein": row["writein"] == "True",
                         "mode": row["mode"].upper(), "votes": row["votes"]})
    return fill_blank_house_districts(rows, code, 2016)


MEDSL_2020_HOUSE = DATA / "2020-raw-data" / "medsl" / "HOUSE_precinct_general.csv"
_medsl_2020_cache: dict[str, list[dict]] | None = None


def medsl_rows_2020(code: str) -> list[dict]:
    """MEDSL's nationwide 2020 House file (guestbook-gated on the Dataverse; drop it in place if obtained)."""
    global _medsl_2020_cache
    if _medsl_2020_cache is None:
        _medsl_2020_cache = collections.defaultdict(list)
        if MEDSL_2020_HOUSE.exists():
            with MEDSL_2020_HOUSE.open(encoding="utf8", errors="ignore", newline="") as handle:
                for row in csv.DictReader(handle):
                    _medsl_2020_cache[row["state_po"]].append(row)
    return medsl_rows_2018(code, _medsl_2020_cache.get(code, []))


def medsl_rows_2018(code: str, prepared: list[dict] | None = None) -> list[dict]:
    path = MEDSL_2018 / f"2018-{code.lower()}-precinct-general.zip"
    rows = []
    if prepared is None:
        if not path.exists():
            return rows
        with zipfile.ZipFile(path) as bundle:
            names = [n for n in bundle.namelist() if n.lower().endswith(".csv")]
            with bundle.open(names[0]) as raw:
                text = raw.read().decode("utf8", "ignore")
        prepared = list(csv.DictReader(text.splitlines()))
    for row in prepared:
        if b24.medsl_office_name(row["office"]) != "US House" or row.get("stage", "GEN").upper() != "GEN" \
                or row.get("special", "FALSE").upper() == "TRUE":
            continue
        rows.append({"county_fips": re.sub(r"\D", "", str(row.get("county_fips", "")).split(".")[0]).zfill(5),
                     "county_name": row.get("county_name") or row.get("county") or row.get("jurisdiction_name") or "",
                     "precinct": row.get("precinct", ""), "jurisdiction": row.get("jurisdiction_name") or row.get("jurisdiction") or "",
                     "candidate": row.get("candidate", ""), "party": row.get("party_simplified", row.get("party", "")),
                     "party_detailed": row.get("party_detailed", row.get("party", "")),
                     "district": row.get("district", ""), "writein": str(row.get("writein", "")).upper() == "TRUE",
                     "mode": str(row.get("mode", "TOTAL")).upper(), "votes": row.get("votes", "0")})
    return fill_blank_house_districts(rows, code, 2018 if prepared is None else 2020)


MEDSL_JUNK = re.compile(r"OVER ?VOTES?|UNDER ?VOTES?|BLANK|VOID|SPOILED|TOTAL|REJECTED|UNRESOLVED|NOT ASSIGNED|EXHAUSTED|SCATTER", re.I)


def medsl_party(row: dict) -> str:
    if row["writein"]:
        return "WRI"
    return b24.medsl_party_code(row.get("party_detailed", ""), row.get("party", ""))


WRITE_IN_NAME = re.compile(r"^WRITE[- ]?INS?$|^WRITEINS?$", re.I)


def fill_blank_house_districts(rows: list[dict], code: str, year: int) -> list[dict]:
    """Give US House rows with a blank district the district they belong to.

    MEDSL leaves the district empty on scattered rows (Santa Cruz AZ and
    Snohomish WA 2022, Hancock IN 2018).  normalize_medsl_district reads a blank
    as at-large, which is right only in an at-large state: elsewhere it invents
    an extra seat.  A row takes its candidate's district from the candidate's
    other rows, or — for write-ins and other lines that name no one — the
    district its precinct's candidates ran in.  Rows still unplaced are dropped.
    """
    if code in at_large_states(year):
        return rows

    def is_house(row: dict) -> bool:
        return row.get("__office", "US House") == "US House"

    def blank(row: dict) -> bool:
        return is_house(row) and not str(row["district"]).strip()

    def named(row: dict) -> str | None:
        name = row["candidate"].strip().upper()
        if not name or WRITE_IN_NAME.search(name) or MEDSL_JUNK.search(name):
            return None
        return name

    def precinct_key(row: dict) -> tuple[str, str]:
        return (row.get("county_fips") or row.get("county_name", ""), row["precinct"])

    by_candidate: dict[str, set[str]] = collections.defaultdict(set)
    for row in rows:
        if is_house(row) and not blank(row) and (name := named(row)):
            by_candidate[name].add(str(row["district"]).strip())

    filled = []
    for row in rows:
        if blank(row) and (name := named(row)) and len(by_candidate.get(name, ())) == 1:
            row = row | {"district": next(iter(by_candidate[name]))}
        filled.append(row)

    by_precinct: dict[tuple[str, str], collections.Counter] = collections.defaultdict(collections.Counter)
    for row in filled:
        if is_house(row) and not blank(row):
            by_precinct[precinct_key(row)][str(row["district"]).strip()] += 1

    result, dropped = [], 0
    for row in filled:
        if blank(row):
            counter = by_precinct.get(precinct_key(row))
            if not counter:
                dropped += 1
                continue
            row = row | {"district": counter.most_common(1)[0][0]}
        result.append(row)
    if dropped:
        print(f"  [{code}] {year}: {dropped} US House rows with no district and no way to place them dropped", flush=True)
    return result


def normalize_medsl_district(raw: str) -> str | None:
    raw = raw.strip().upper()
    if raw in {"AT-LARGE", "AL", "STATEWIDE", "AT LARGE", "0", "00", "000", ""}:
        return "At-large"
    return i20.normalize_district(raw) or raw


def supplement_house(rows: list[dict], frame: pd.DataFrame, precinct_ids: list[int | None],
                     county_of: list[str], counties: gpd.GeoDataFrame, code: str, year: int,
                     have: set[str], log: list[str], district_of: list[str | None] | None = None,
                     weights: dict[int, int] | None = None) -> Contest | None:
    """Match MEDSL US House rows onto the VEST layer by precinct name and add the districts VEST lacks."""
    if not rows:
        return None
    by_fips, by_name = county_names(counties)
    # keys from every non-vote attribute of the layer, per county
    vote_like = re.compile(r"^[GSRPC]\d\d[A-Z]{3}")
    wanted_column = re.compile(r"PREC|VTD|NAME|GEOID|WARD|LABEL|PCT|KEY|NUMBER|CODE|ID$|^ID|DESC|UNIQUE|MUNI|TOWN|MCD", re.I)
    unwanted_column = re.compile(r"COUNTY|CNTY|FIPS|STATE|^CD|CONG|SLD|DISTRICT$|POP|PERSONS|LSAD|AREA|LEN|COLOR", re.I)
    attr_columns = [c for c in frame.columns if c != "geometry" and not vote_like.match(str(c).upper())
                    and wanted_column.search(str(c)) and not unwanted_column.search(str(c))]
    index: dict[tuple[str, str], set[int]] = collections.defaultdict(set)
    statewide: dict[str, set[int]] = collections.defaultdict(set)
    columns_values = {column: frame[column].tolist() for column in attr_columns}
    for row_index, pid in enumerate(precinct_ids):
        if pid is None:
            continue
        county = county_of[row_index]
        for column in attr_columns:
            for key in key_variants(columns_values[column][row_index]):
                index[(county, key)].add(pid)
                statewide[key].add(pid)
    county_of_pid = {pid: county_of[i] for i, pid in enumerate(precinct_ids) if pid is not None}

    def combined(row: dict) -> str:
        jurisdiction = str(row.get("jurisdiction", "") or "").strip()
        return f"{jurisdiction} {row['precinct']}".strip() if jurisdiction and jurisdiction.upper() not in row["precinct"].upper() else row["precinct"]

    def county_lookup(row: dict) -> str | None:
        fips = MEDSL_COUNTY_ALIASES.get(code, {}).get(row["county_fips"], row["county_fips"])
        found = by_fips.get(fips[-3:]) or by_name.get(i20.name_key(row["county_name"]))
        if found:
            return found
        for value in (combined(row), row.get("jurisdiction", ""), row["precinct"]):
            for key in key_variants(value):
                hit = statewide.get(key)
                if hit and len(key) >= 4 and len({county_of_pid[p] for p in hit}) == 1:
                    return county_of_pid[next(iter(hit))]
        return by_name.get(i20.name_key(row.get("jurisdiction", "")))

    contest = Contest("US House")
    totals: dict[tuple[int, str, str], dict[str, int]] = collections.defaultdict(dict)
    matched = unmatched = 0
    unmatched_rows: list[dict] = []
    skipped_districts = set()
    for row in rows:
        district = normalize_medsl_district(row["district"])
        if district is None or district in have:
            skipped_districts.add(district)
            continue
        name = row["candidate"].strip()
        if not name or MEDSL_JUNK.search(name):
            continue
        try:
            count = int(float(row["votes"]))
        except (TypeError, ValueError):
            continue
        if count < 0:
            continue
        county = county_lookup(row)
        candidates_pids: set[int] = set()
        for value in (row["precinct"], combined(row)):
            for key in key_variants(value):
                hit = index.get((county, key))
                if hit and len(hit) == 1:
                    candidates_pids = hit
                    break
            if candidates_pids:
                break
        if not candidates_pids:
            # try the precinct with the county name stripped
            stripped = re.sub(r"^" + re.escape(str(county or "").upper()) + r"\s*", "", row["precinct"].upper())
            for key in key_variants(stripped):
                hit = index.get((county, key))
                if hit and len(hit) == 1:
                    candidates_pids = hit
                    break
        if not candidates_pids:
            for key in key_variants(combined(row)) | key_variants(row["precinct"]):
                hit = statewide.get(key)
                if hit and len(hit) == 1 and len(key) >= 4:
                    candidates_pids = hit
                    break
        if not candidates_pids:
            unmatched += count
            unmatched_rows.append(row)
            continue
        pid = next(iter(candidates_pids))
        party = medsl_party(row)
        if row["writein"] or re.match(r"^\[?write-?ins?\]?$", name, re.I):
            ccode, cname, party = f"{district}-OWRI", "Write-in", "WRI"
        else:
            tokens = b24.surname_tokens(name)
            ccode = f"{district}-{party[0]}{(tokens[-1] if tokens else name)[:3].upper()}"
            cname = clean_name(name)
        if ccode not in contest.candidates:
            contest.candidates[ccode] = Candidate(ccode, cname, party, district)
        slot = totals[(pid, ccode, row["precinct"])]
        slot[row["mode"]] = slot.get(row["mode"], 0) + count
        matched += count
    for (pid, ccode, _), modes in totals.items():
        total = modes["TOTAL"] if "TOTAL" in modes else sum(modes.values())
        contest.add(pid, ccode, total)
    share = matched / (matched + unmatched) if matched + unmatched else 0
    if share < 0.9:
        log.append(f"MEDSL US House precinct names matched only {share:.1%} of {matched + unmatched:,} votes; "
                   f"county totals are distributed to precincts instead")
        return disaggregate_house(rows, precinct_ids, county_of, district_of, weights, by_fips, by_name, have, log,
                                  county_lookup)
    added = sorted({c.district for c in contest.candidates.values()}, key=lambda d: (len(d), d))
    log.append(f"US House districts {added} added from MEDSL precinct returns ({share:.1%} of votes matched by precinct name"
               + (f"; the other {unmatched:,} votes were distributed from county totals)" if unmatched else ")"))
    if unmatched_rows:
        rest = disaggregate_house(unmatched_rows, precinct_ids, county_of, district_of, weights, by_fips, by_name, have,
                                  [], county_lookup)
        if rest is not None:
            merge_contest(contest, rest)
    return contest


def disaggregate_house(rows: list[dict], precinct_ids: list[int | None], county_of: list[str],
                       district_of: list[str | None] | None, weights: dict[int, int] | None,
                       by_fips: dict[str, str], by_name: dict[str, str], have: set[str],
                       log: list[str], county_lookup=None) -> Contest | None:
    """US House votes by county (and district) spread over the county's precincts of that district,
    in proportion to each precinct's vote in the other contests.  District totals stay exact."""
    if district_of is None or weights is None:
        return None
    # (county, district) -> candidate -> MEDSL precinct -> {mode: votes}; a "TOTAL" mode row
    # replaces that precinct's component modes, and precincts are then summed.
    totals: dict[tuple[str, str], dict[str, dict[str, dict[str, int]]]] = collections.defaultdict(
        lambda: collections.defaultdict(lambda: collections.defaultdict(dict)))
    contest = Contest("US House")
    unplaced = 0
    for row in rows:
        district = normalize_medsl_district(row["district"])
        if district is None or district in have:
            continue
        name = row["candidate"].strip()
        if not name or MEDSL_JUNK.search(name):
            continue
        try:
            count = int(float(row["votes"]))
        except (TypeError, ValueError):
            continue
        if count <= 0:
            continue
        county = county_lookup(row) if county_lookup else (
            by_fips.get(row["county_fips"][-3:]) or by_name.get(i20.name_key(row["county_name"])))
        if county is None:
            unplaced += count
            continue
        party = medsl_party(row)
        if row["writein"] or re.match(r"^\[?write-?ins?\]?$", name, re.I):
            ccode, cname, party = f"{district}-OWRI", "Write-in", "WRI"
        else:
            tokens = b24.surname_tokens(name)
            ccode = f"{district}-{party[0]}{(tokens[-1] if tokens else name)[:3].upper()}"
            cname = clean_name(name)
        if ccode not in contest.candidates:
            contest.candidates[ccode] = Candidate(ccode, cname, party, district)
        slot = totals[(county, district)][ccode][row["precinct"]]
        slot[row["mode"]] = slot.get(row["mode"], 0) + count
    if not totals:
        return None
    members: dict[str, list[int]] = collections.defaultdict(list)
    members_in: dict[tuple[str, str], list[int]] = collections.defaultdict(list)
    for row_index, pid in enumerate(precinct_ids):
        if pid is None:
            continue
        members[county_of[row_index]].append(pid)
        members_in[(county_of[row_index], district_of[row_index])].append(pid)
    for (county, district), by_cand in totals.items():
        pids = members_in.get((county, district)) or members.get(county) or []
        if not pids:
            unplaced += sum(sum(m["TOTAL"] if "TOTAL" in m else sum(m.values()) for m in bp.values()) for bp in by_cand.values())
            continue
        raw = [weights.get(pid, 0) for pid in pids]
        if sum(raw) == 0:
            raw = [1] * len(pids)
        total_weight = sum(raw)
        for ccode, by_precinct in by_cand.items():
            total = sum(modes["TOTAL"] if "TOTAL" in modes else sum(modes.values()) for modes in by_precinct.values())
            shares = [total * w / total_weight for w in raw]
            floors = [int(x) for x in shares]
            remainder = total - sum(floors)
            order = sorted(range(len(pids)), key=lambda i: shares[i] - floors[i], reverse=True)
            for i in order[:remainder]:
                floors[i] += 1
            for pid, votes in zip(pids, floors):
                if votes:
                    contest.add(pid, ccode, votes)
    added = sorted({c.district for c in contest.candidates.values()}, key=lambda d: (len(d), d))
    contest.notes.append(f"US House districts {added}: MEDSL county totals distributed to the county's precincts "
                         f"of each district in proportion to their vote in the statewide contests"
                         + (f"; {unplaced:,} votes could not be placed" if unplaced else ""))
    log.append(contest.notes[-1])
    return contest if contest.total() > 0 else None


# --------------------------------------------------------------------------- county-level returns (2000–2019)

_dgumfi: dict[str, pd.DataFrame] = {}


def dgumfi(office: str) -> pd.DataFrame:
    if office not in _dgumfi:
        import pyreadr
        result = pyreadr.read_r(DGUMFI[office])
        frame = next(v for k, v in result.items() if not k.startswith("."))
        frame = frame[frame["election_year"] >= 2000].copy()
        frame["fips"] = frame["fips"].astype(str).str.zfill(5)
        _dgumfi[office] = frame
    return _dgumfi[office]


def dgumfi_contests(year: int, code: str) -> list[Contest]:
    """Contests keyed by county GEOID (results use the GEOID as the precinct key for now)."""
    contests: list[Contest] = []
    for office in ("President", "US Senate", "Governor"):
        frame = dgumfi(office)
        rows = frame[(frame["election_year"] == year) & (frame["state"] == code)]
        if rows.empty:
            continue
        group_field = "election_id" if "election_id" in rows.columns else "election_year"
        for _, race in rows.groupby(group_field):
            special = str(race["election_type"].iloc[0]).upper() == "S" if "election_type" in race.columns else False
            contest = Contest(office, special)
            dem = next((n for n in race["dem_nominee"].dropna().astype(str) if n.strip() and n != "None"), None)
            rep = next((n for n in race["rep_nominee"].dropna().astype(str) if n.strip() and n != "None"), None)
            if dem:
                contest.candidates["DEM"] = Candidate("DEM", last_first(dem), "DEM", None)
            if rep:
                contest.candidates["REP"] = Candidate("REP", last_first(rep), "REP", None)
            contest.candidates["OTH"] = Candidate("OTH", "Other", "OTH", None)
            for _, row in race.iterrows():
                total = row["raw_county_vote_totals"]
                d = int(row["democratic_raw_votes"]) if pd.notna(row["democratic_raw_votes"]) else 0
                r = int(row["republican_raw_votes"]) if pd.notna(row["republican_raw_votes"]) else 0
                total = int(total) if pd.notna(total) else d + r
                other = max(0, total - d - r)
                fips = row["fips"]
                if dem and d:
                    contest.add(fips, "DEM", d)
                if rep and r:
                    contest.add(fips, "REP", r)
                if other:
                    contest.add(fips, "OTH", other)
            if contest.total() > 0:
                seat = race["seat_class"].iloc[0] if "seat_class" in race.columns else ""
                contest.notes.append(f"Algara & Amlani county returns{f' ({seat})' if isinstance(seat, str) and seat else ''}: "
                                     f"Democratic and Republican nominees; every other candidate is pooled as Other")
                contests.append(contest)
    return contests


# --------------------------------------------------------------------------- 2022 (MEDSL, county x district)


def medsl_2022_rows(code: str, year: int = 2022) -> list[dict]:
    path = (MEDSL_2022 / f"2022-{code.lower()}-local-precinct-general.zip" if year == 2022
            else MEDSL_2018 / f"2018-{code.lower()}-precinct-general.zip")
    if not path.exists():
        return []
    with zipfile.ZipFile(path) as bundle:
        names = [n for n in bundle.namelist() if n.lower().endswith(".csv")]
        with bundle.open(names[0]) as raw:
            text = raw.read().decode("utf8", "ignore")
    rows = []
    for row in csv.DictReader(text.splitlines()):
        office = b24.medsl_office_name(row["office"])
        if office is None or str(row.get("stage", "GEN")).upper() != "GEN":
            continue
        row = {k: ("" if v is None else v) for k, v in row.items()}
        row.setdefault("county_fips", ""); row.setdefault("county_name", row.get("county", ""))
        row.setdefault("jurisdiction_name", row.get("jurisdiction", "")); row.setdefault("party_detailed", row.get("party", ""))
        row.setdefault("party_simplified", row.get("party", "")); row.setdefault("special", "FALSE"); row.setdefault("writein", "FALSE")
        row["special"] = str(row["special"]).upper(); row["writein"] = str(row["writein"]).upper()
        row["mode"] = str(row.get("mode", "TOTAL")).upper()
        rows.append(row | {"__office": office})
    return fill_blank_house_districts(rows, code, year)


# Reporting units MEDSL keeps outside any county.  Kansas City, Missouri (its own
# election board, "county" 36000) lies mostly in Jackson County and is counted there.
MEDSL_COUNTY_ALIASES = {"MO": {"36000": "29095", "29380": "29095"}}


def build_2022_state(code: str, state_name: str, year: int = 2022) -> dict:
    rows = medsl_2022_rows(code, year)
    if not rows:
        raise ValueError(f"no MEDSL {year} file")
    if code == "AK":
        # Alaska reports by state house district, not borough: use the 2022 districts as the units.
        counties = read_zip_layer(CENSUS / "cb_2022_02_sldl_500k.zip")
        counties["geometry"] = shapely.force_2d(counties.geometry.values)
        counties["geometry"] = i20.snap_to_grid(i20.repair(counties.geometry, code, "district"), code)
        counties["COUNTYFP"] = counties["SLDLST"].astype(str).str.zfill(3)
        counties["NAME"] = ["House District " + str(int(v)) for v in counties["SLDLST"]]
        counties["NAMELSAD"] = counties["NAME"]
        counties["GEOID"] = STATE_FIPS[code] + counties["COUNTYFP"]
        counties["STATEFP"] = STATE_FIPS[code]
    else:
        counties = state_counties(year, code)
    counties = counties.sort_values("COUNTYFP").reset_index(drop=True)
    by_fips, by_name = county_names(counties)
    fips_of_name = {v: k for k, v in by_fips.items()}
    at_large = code in at_large_states(year)

    def county_key(row: dict) -> str | None:
        if code == "AK":
            digits = re.sub(r"\D", "", row["jurisdiction_name"])
            return digits.zfill(3) if digits and digits.zfill(3) in by_fips else None
        fips = str(row["county_fips"]).strip()
        fips = re.sub(r"\D", "", fips.split(".")[0]).zfill(5) if fips else ""
        fips = MEDSL_COUNTY_ALIASES.get(code, {}).get(fips, fips)
        if fips[-3:] in by_fips:
            return fips[-3:]
        name = by_name.get(i20.name_key(row["county_name"]))
        return fips_of_name.get(name) if name else None

    # district of every precinct, from its House rows
    house_votes: dict[tuple[str, str], collections.Counter] = collections.defaultdict(collections.Counter)
    for row in rows:
        if row["__office"] != "US House":
            continue
        district = normalize_medsl_district(row["district"])
        cfp = county_key(row)
        if cfp is None or district is None:
            continue
        try:
            house_votes[(cfp, row["precinct"])][district] += int(float(row["votes"]))
        except (TypeError, ValueError):
            pass
    county_district_votes: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    precinct_district: dict[tuple[str, str], str] = {}
    for (cfp, precinct), counter in house_votes.items():
        if not counter:
            continue
        district = counter.most_common(1)[0][0]
        precinct_district[(cfp, precinct)] = district
        county_district_votes[cfp][district] += sum(counter.values())
    if at_large:
        precinct_district = {k: "At-large" for k in precinct_district}
        county_district_votes = {cfp: collections.Counter({"At-large": 1}) for cfp in by_fips}
    default_district: dict[str, str] = {}
    spec = district_layer(year)
    if spec is not None and not at_large:
        layer, field = spec
        cd_polys = layer[layer["STATEFP"] == STATE_FIPS[code]]
        located = i20.locate(counties, cd_polys, field, code, "district")
        default_district = {cfp: i20.district_label(v) for cfp, v in zip(counties["COUNTYFP"], located)}
    for cfp in by_fips:
        if cfp not in county_district_votes and cfp in default_district:
            county_district_votes[cfp] = collections.Counter({default_district[cfp]: 1})

    # contests, keyed by (county fp, district) piece
    contests, get = contest_map()
    totals: dict[tuple[str, tuple[str, str], str], dict[str, int]] = collections.defaultdict(dict)
    unplaced = 0
    for row in rows:
        office = row["__office"]
        name = row["candidate"].strip().upper()
        if not name or b24.imp.MEDSL_ACCOUNTING.search(name) or b24.MEDSL_EXTRA_ACCOUNTING.search(name) or MEDSL_JUNK.search(name):
            continue
        try:
            count = int(float(row["votes"]))
        except (TypeError, ValueError):
            continue
        cfp = county_key(row)
        if cfp is None:
            unplaced += count
            continue
        special = row.get("special") == "TRUE"
        if office == "US House":
            district = normalize_medsl_district(row["district"]) or "At-large"
            if at_large:
                district = "At-large"
            piece_district = district
        else:
            district = None
            piece_district = precinct_district.get((cfp, row["precinct"]))
            if piece_district is None:
                counter = county_district_votes.get(cfp)
                piece_district = counter.most_common(1)[0][0] if counter else default_district.get(cfp, "At-large")
        party = b24.medsl_party_code(row["party_detailed"], row["party_simplified"])
        if row["writein"] == "TRUE" or party == "WRI":
            ccode, cname, party = f"{district or ''}-WRI", "Write-in", "WRI"
        else:
            ccode, cname = f"{district or ''}-{re.sub(r'[^A-Z0-9]', '', name)}", b24.title_case(name)
        target = get(office, special)
        if ccode not in target.candidates:
            target.candidates[ccode] = Candidate(ccode, cname, party, district)
        slot = totals[(target.slug, (cfp, piece_district), ccode)]
        slot[row["mode"]] = slot.get(row["mode"], 0) + count

    # pieces: county x district polygons
    pieces: dict[tuple[str, str], object] = {}
    cds = None
    if spec is not None and not at_large:
        cds = layer[layer["STATEFP"] == STATE_FIPS[code]][[field, "geometry"]].rename(columns={field: "__cd"})
        cds["__cd"] = [i20.district_label(v) for v in cds["__cd"]]
    wanted: set[tuple[str, str]] = {key for (_, key, _) in totals}
    for _, county in counties.iterrows():
        cfp = county["COUNTYFP"]
        districts_here = {d for (c, d) in wanted if c == cfp}
        if at_large or cds is None or len(districts_here) <= 1:
            label = next(iter(districts_here)) if districts_here else (
                "At-large" if at_large else (county_district_votes[cfp].most_common(1)[0][0]
                                             if county_district_votes.get(cfp) else default_district.get(cfp)))
            pieces[(cfp, label)] = county.geometry
            continue
        parts = {}
        for _, cd in cds.iterrows():
            inter = county.geometry.intersection(cd.geometry)
            inter = i20.polygonal(inter)
            if inter is not None and not inter.is_empty and inter.area > county.geometry.area * 1e-4:
                parts[cd["__cd"]] = inter
        keep = {d: g for d, g in parts.items() if d in districts_here}
        if not keep:
            pieces[(cfp, sorted(districts_here)[0])] = county.geometry
            continue
        leftovers = [g for d, g in parts.items() if d not in keep]
        covered = unary_union(list(keep.values()) + leftovers)
        gap = county.geometry.difference(covered)
        biggest = max(keep, key=lambda d: keep[d].area)
        extra = leftovers + ([gap] if gap is not None and not gap.is_empty else [])
        if extra:
            keep[biggest] = unary_union([keep[biggest]] + extra)
        for d, g in keep.items():
            pieces[(cfp, d)] = i20.snap_geometry(g, code)
    # merge votes of (county, district) combos that got no piece into the county's biggest piece
    piece_index: dict[tuple[str, str], int] = {}
    geometry = Geometry()
    names, county_of, district_of, geoms = [], [], [], []
    for pid, ((cfp, district), geom) in enumerate(sorted(pieces.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))), 1):
        piece_index[(cfp, district)] = pid
        # The app reads a piece's district off congressional_district_precincts,
        # so the name stays the plain county name even when the county is split.
        names.append(by_fips[cfp])
        county_of.append(by_fips[cfp])
        district_of.append(district)
        geoms.append(geom)
    for (slug, (cfp, district), ccode), modes in totals.items():
        total = modes["TOTAL"] if "TOTAL" in modes else sum(modes.values())
        pid = piece_index.get((cfp, district))
        if pid is None:
            same = [p for (c, _), p in piece_index.items() if c == cfp]
            pid = same[0] if same else None
        if pid is None:
            unplaced += total
            continue
        contests[slug].add(pid, ccode, total)
    frame = gpd.GeoDataFrame({"geometry": geoms}, crs="EPSG:4326")
    geometry = geometry_from_frame(frame, code, year, names, county_of, district_of, [])
    geometry.log.append("Alaska state house districts (Census cb_2022 SLDL) stand in for counties"
                        if code == "AK" else
                        f"county × congressional-district pieces built from the Census county and {cd_layer(year)[1][:5]} boundaries")
    if unplaced:
        geometry.log.append(f"{unplaced:,} votes could not be placed in a county")
    built = [c for c in contests.values() if c.total() > 0]
    for contest in built:
        contest.notes.append(f"MEDSL {year} precinct returns aggregated by county and congressional district")
        if code == "MO":
            contest.notes.append("Kansas City (its own election board) is counted in Jackson County")
    return write_state_db(year, code, state_name, geometry, built, "MEDSL", "county")


# --------------------------------------------------------------------------- 2023 (OpenElections / LA SOS)

COUNTY_ALIASES = {"jeff davis": "Jefferson Davis", "lasalle": "La Salle", "st johns": "St. John the Baptist",
                  "dewitt": "De Witt", "desoto": "De Soto", "e. baton rouge": "East Baton Rouge",
                  "w. baton rouge": "West Baton Rouge", "jefferson davis": "Jefferson Davis"}


def contests_2023(code: str, counties: gpd.GeoDataFrame) -> list[Contest]:
    by_fips, by_name = county_names(counties)
    fips_of_name = {v: k for k, v in by_fips.items()}
    contest = Contest("Governor")

    def add(county_name: str, cname: str, party: str, votes: int, ccode: str | None = None) -> None:
        display = by_name.get(i20.name_key(COUNTY_ALIASES.get(county_name.strip().lower(), county_name)))
        if display is None:
            raise ValueError(f"unknown county {county_name!r}")
        fips = STATE_FIPS[code] + fips_of_name[display]
        ccode = ccode or f"{party[0]}{re.sub(r'[^A-Z]', '', cname.upper())[:12]}"
        if ccode not in contest.candidates:
            contest.candidates[ccode] = Candidate(ccode, cname, party, None)
        contest.add(fips, ccode, votes)

    if code == "KY":
        for path in sorted((OE_2023 / "ky").glob("*.csv")):
            with path.open(encoding="utf8", errors="ignore", newline="") as handle:
                for row in csv.DictReader(handle):
                    if row["office"] != "Governor":
                        continue
                    name = row["candidate"].strip()
                    party = row["party"].strip().upper()
                    votes = i20.as_int(row["votes"])
                    if name == "Write-In Totals":
                        add(row["county"], "Write-in", "WRI", votes, "OWRI")
                    elif party in ("REP", "DEM"):
                        add(row["county"], clean_name(name.split(" / ")[0]), party, votes)
        contest.notes.append("OpenElections precinct returns (Kentucky State Board of Elections) summed by county")
    elif code == "MS":
        path = OE_2023 / "ms" / "20231107__ms__general__county.csv"
        with path.open(encoding="utf8", errors="ignore", newline="") as handle:
            for row in csv.DictReader(handle):
                if row["office"] != "Governor":
                    continue
                party = {"DEM": "DEM", "REP": "REP", "IND": "IND"}.get(row["party"].strip().upper()[:3], "OTH")
                add(row["county"], clean_name(row["candidate"]), party, i20.as_int(row["votes"]))
        contest.notes.append("OpenElections county returns (Mississippi Secretary of State)")
    elif code == "LA":
        races = json.loads((OE_2023 / "la" / "RacesCandidates_Multiparish.json").read_text())
        race = next(r for r in races["Races"]["Race"] if r["GeneralTitle"] == "Governor")
        choices = {c["ID"]: c["Desc"] for c in race["Choice"]}
        parishes = sorted(counties["COUNTYFP"])   # Louisiana numbers its parishes alphabetically, like FIPS
        for number, cfp in enumerate(parishes, 1):
            data = json.loads((OE_2023 / "la" / "parish" / f"Votes_{number:02d}.json").read_text())
            votes_race = next((r for r in data["Races"]["Race"] if r["ID"] == race["ID"]), None)
            if votes_race is None:
                continue
            for choice in votes_race["Choice"]:
                desc = choices[choice["ID"]]
                pmatch = re.search(r"\(([A-Z]+)\)\s*$", desc)
                party = {"DEM": "DEM", "REP": "REP", "IND": "IND", "LIB": "LIB", "GRN": "GRN", "NOPTY": "NPA"}.get(
                    pmatch.group(1) if pmatch else "", "OTH")
                name = desc[: pmatch.start()].strip() if pmatch else desc
                add(by_fips[cfp], name, party, i20.as_int(choice["VoteTotal"]), f"{party[0]}{choice['ID']}")
        contest.notes.append("Louisiana Secretary of State parish returns for the 14 October 2023 open primary, "
                             "which decided the race outright")
    else:
        return []
    return [contest] if contest.total() > 0 else []


# --------------------------------------------------------------------------- output

FULL_SCHEMA = i20.STATE_SCHEMA.replace(
    "CREATE TABLE precinct_results (id INTEGER PRIMARY KEY AUTOINCREMENT, precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE, candidate_id TEXT NOT NULL, votes INTEGER NOT NULL DEFAULT 0, UNIQUE(precinct_id, candidate_id));\n", ""
).replace("CREATE INDEX idx_precinct_results_precinct ON precinct_results(precinct_id);\n", "") + b24.NEW_SCHEMA


assert FULL_SCHEMA.count("CREATE TABLE precinct_results") == 1 and FULL_SCHEMA.count("idx_precinct_results_precinct") == 1


def out_dir(year: int) -> Path:
    return OUT_ROOT / str(year)


def write_state_db(year: int, code: str, state_name: str, geometry: Geometry, contests: list[Contest],
                   source: str, level: str) -> dict:
    if not contests:
        raise ValueError("no contests with votes")
    target_dir = out_dir(year)
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{code}-{year}.db"
    temp = target.with_suffix(".db.tmp")
    temp.unlink(missing_ok=True)
    if geometry.template is not None:
        shutil.copyfile(geometry.template, temp)
        db = sqlite3.connect(temp)
        db.execute("PRAGMA foreign_keys=OFF")
        db.executescript("DROP TABLE IF EXISTS precinct_results; DROP INDEX IF EXISTS idx_precinct_results_precinct;")
        db.executescript(b24.NEW_SCHEMA)
        # The template predates dropping precinct population; don't carry it over.
        if "population" in {row[1] for row in db.execute("PRAGMA table_info(precincts)")}:
            db.execute("ALTER TABLE precincts DROP COLUMN population")
    else:
        db = sqlite3.connect(temp)
        db.execute("PRAGMA foreign_keys=OFF")
        db.executescript(FULL_SCHEMA)
        county_ids: dict[str, int] = {}
        for county_id, (name, geom) in enumerate(sorted(geometry.counties.items()), 1):
            lat, lon = i20.center(geom)
            db.execute("INSERT INTO counties(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)",
                       (county_id, name, i20.wkb(geom), lat, lon))
            county_ids[name] = county_id
        district_ids: dict[str, int] = {}
        for district_id, (label, geom) in enumerate(sorted(geometry.districts.items(), key=lambda kv: (len(kv[0]), kv[0])), 1):
            lat, lon = i20.center(geom)
            db.execute("INSERT INTO congressional_districts(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)",
                       (district_id, f"District {label}", i20.wkb(geom), lat, lon))
            district_ids[label] = district_id
        for pid, ((name, geom), county, district) in enumerate(
                zip(geometry.precincts, geometry.precinct_county, geometry.precinct_district), 1):
            lat, lon = i20.center(geom)
            db.execute("INSERT INTO precincts(id,name,boundary,center_lat,center_lon) VALUES (?,?,?,?,?)",
                       (pid, name, i20.wkb(geom), lat, lon))
            db.execute("INSERT INTO county_precincts(precinct_id,county_id) VALUES (?,?)", (pid, county_ids[county]))
            if district in district_ids:
                db.execute("INSERT INTO congressional_district_precincts(precinct_id,congressional_district_id) VALUES (?,?)",
                           (pid, district_ids[district]))
        i20.write_state_regions(db, county_ids.values(), district_ids.values())
    district_of_name = {name: did for did, name in db.execute("SELECT id, name FROM congressional_districts")}

    order = {"President": 0, "US Senate": 1, "US House": 2, "Governor": 3}
    contests = sorted(contests, key=lambda c: (order[c.office], c.special))
    summary = []
    for election_id, contest in enumerate(contests, 1):
        label = f"{year} {state_name} {contest.office}" + (" (Special)" if contest.special else "")
        db.execute("INSERT INTO elections(id, office, name, year, special, source, total_votes) VALUES (?,?,?,?,?,?,?)",
                   (election_id, contest.office, label, year, int(contest.special), source, contest.total()))
        parties: dict[str, str] = {}
        for cand in contest.candidates.values():
            if cand.votes and cand.party not in parties:
                pid = party_uuid(code, year, contest.slug, cand.party)
                pname, color = PARTY_INFO.get(cand.party, (cand.party, 0xFF616161))
                db.execute("INSERT INTO parties(id, election_id, code, name, color) VALUES (?,?,?,?,?)",
                           (pid, election_id, cand.party, pname, color))
                parties[cand.party] = pid
        ids: dict[str, str] = {}
        for cand in sorted(contest.candidates.values(), key=lambda c: (-c.votes, c.code)):
            if cand.votes == 0:
                continue
            cid = candidate_uuid(code, year, contest.slug, cand.code)
            ids[cand.code] = cid
            cd_id = district_of_name.get(f"District {cand.district}") if cand.district else None
            db.execute("INSERT INTO candidates(id, election_id, party_id, code, name, district, congressional_district_id, votes) "
                       "VALUES (?,?,?,?,?,?,?,?)",
                       (cid, election_id, parties[cand.party], cand.code, cand.name, cand.district, cd_id, cand.votes))
        rows = [(pid, election_id, ids[ccode], votes)
                for pid, by_cand in contest.results.items()
                for ccode, votes in by_cand.items() if votes and ccode in ids]
        db.executemany("INSERT INTO precinct_results(precinct_id, election_id, candidate_id, votes) VALUES (?,?,?,?)", rows)
        summary.append({
            "id": election_id, "office": contest.office, "special": contest.special, "name": label,
            "total_votes": contest.total(), "candidates": len(ids),
            "parties": [{"id": pid, "code": pcode, "name": PARTY_INFO.get(pcode, (pcode, 0))[0]}
                        for pcode, pid in parties.items()],
            "leaders": [{"name": c.name, "party": c.party, "district": c.district, "votes": c.votes}
                        for c in sorted(contest.candidates.values(), key=lambda c: -c.votes)[:6]],
            "notes": contest.notes,
        })
    meta = {"state_code": code, "state_name": state_name, "year": str(year), "source": source, "level": level,
            "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "schema": "2",
            "notes": " | ".join(geometry.log)}
    if geometry.template is not None:
        meta["geometry_from"] = str(geometry.template.relative_to(ROOT))
    db.executemany("INSERT INTO meta(key, value) VALUES (?,?)", list(meta.items()))
    db.commit()
    db.execute("VACUUM")
    db.close()
    shutil.move(temp, target)
    print(f"[{code}] {year} {level}: " + ", ".join(
        f"{c.office}{' special' if c.special else ''}={c.total():,}" for c in contests), flush=True)
    for note in geometry.log:
        print(f"    {note}", flush=True)
    return {"code": code, "name": state_name, "db": target.name, "source": source, "level": level,
            "size": target.stat().st_size, "sha256": b24.sha256(target), "elections": summary,
            "notes": geometry.log}


_state_outlines: dict[str, object] | None = None


def state_outline(name: str):
    global _state_outlines
    if _state_outlines is None:
        outlines = read_zip_layer(STATE_OUTLINES)
        outlines["geometry"] = i20.snap_to_grid(outlines.geometry, "US")
        _state_outlines = {str(row["NAME"]).strip(): row.geometry for _, row in outlines.iterrows()}
    return _state_outlines.get(name)


def write_national(year: int, reports: list[dict]) -> None:
    target = out_dir(year) / f"National-{year}.db"
    target.unlink(missing_ok=True)
    db = sqlite3.connect(target)
    db.executescript("""
        CREATE TABLE states (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            boundary BLOB,
            center_lat REAL,
            center_lon REAL,
            db_name TEXT
        , vote_summary TEXT);
        CREATE TABLE state_elections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            state_id INTEGER NOT NULL REFERENCES states(id) ON DELETE CASCADE,
            election_id INTEGER NOT NULL,
            office TEXT NOT NULL,
            special INTEGER NOT NULL DEFAULT 0,
            name TEXT NOT NULL,
            total_votes INTEGER NOT NULL DEFAULT 0,
            summary TEXT NOT NULL
        );
        CREATE INDEX idx_state_elections_state ON state_elections(state_id);
    """)
    headline_order = {"President": 0, "Governor": 1, "US Senate": 2, "US House": 3}
    for report in sorted(reports, key=lambda r: r["name"]):
        geom = state_outline(report["name"])
        lat, lon = i20.center(geom) if geom is not None else (None, None)
        cursor = db.execute("INSERT INTO states(name, boundary, center_lat, center_lon, db_name) VALUES (?,?,?,?,?)",
                            (report["name"], i20.wkb(geom) if geom is not None else None, lat, lon, report["db"]))
        sid = cursor.lastrowid
        state_db = sqlite3.connect(out_dir(year) / report["db"])
        headline = house = None
        for election in sorted(report["elections"], key=lambda e: (headline_order[e["office"]], e["special"])):
            rows = state_db.execute(
                "SELECT c.id, c.code, c.name, p.code, c.votes FROM candidates c JOIN parties p ON p.id=c.party_id "
                "WHERE c.election_id=? ORDER BY c.votes DESC", (election["id"],)).fetchall()
            summary = [{"candidate_id": r[0], "code": r[1], "name": r[2], "party": r[3], "votes": r[4]} for r in rows]
            db.execute("INSERT INTO state_elections(state_id, election_id, office, special, name, total_votes, summary) "
                       "VALUES (?,?,?,?,?,?,?)",
                       (sid, election["id"], election["office"], int(election["special"]), election["name"],
                        election["total_votes"], json.dumps(summary, separators=(",", ":"))))
            if headline is None and election["office"] != "US House":
                headline = summary
            if house is None and election["office"] == "US House":
                house = summary
        if headline is None:
            headline = house   # a state that only held House races that year
        if headline is not None:
            db.execute("UPDATE states SET vote_summary=? WHERE id=?", (json.dumps(headline, separators=(",", ":")), sid))
        state_db.close()
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"wrote {target.relative_to(ROOT)}", flush=True)


def write_manifest(year: int, reports: list[dict]) -> None:
    target_dir = out_dir(year)
    national = target_dir / f"National-{year}.db"
    payload = {
        "year": year,
        "schema": 2,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "cdn_base": f"{CDN_BASE}/{year}",
        "national": {"db": national.name, "url": f"{CDN_BASE}/{year}/{national.name}",
                     "size": national.stat().st_size if national.exists() else None,
                     "sha256": b24.sha256(national) if national.exists() else None},
        "states": [{
            "code": r["code"], "name": r["name"], "db": r["db"], "url": f"{CDN_BASE}/{year}/{r['db']}",
            "size": r["size"], "sha256": r["sha256"], "source": r["source"], "level": r["level"],
            "elections": [{k: e[k] for k in ("id", "office", "special", "name", "total_votes", "candidates", "parties")}
                          for e in r["elections"]],
        } for r in sorted(reports, key=lambda r: r["code"])],
    }
    (target_dir / "manifest.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")

    lines = [f"# {year} state databases — build report", "",
             f"Generated {payload['generated_at']} by build_year_state_dbs.py.", "",
             "| State | Source | Level | President | US Senate | US House | Governor | Size |",
             "|---|---|---|---|---|---|---|---|"]
    for r in sorted(reports, key=lambda r: r["code"]):
        cells: dict[str, list[str]] = {}
        for e in r["elections"]:
            cells.setdefault(e["office"], []).append(f"{e['total_votes']:,}" + (" (special)" if e["special"] else ""))
        row = [r["code"], r["source"], r["level"]] + [" / ".join(cells.get(o, ["—"])) for o in OFFICES] + [f"{r['size'] / 1048576:.1f} MB"]
        lines.append("| " + " | ".join(row) + " |")
    lines += ["", "## Per-state detail", ""]
    for r in sorted(reports, key=lambda r: r["code"]):
        lines.append(f"### {r['code']} — {r['name']} ({r['source']}, {r['level']} level)")
        for note in r.get("notes", []):
            lines.append(f"- note: {note}")
        for e in r["elections"]:
            lines.append(f"- **{e['name']}** — {e['total_votes']:,} votes, {e['candidates']} candidates, "
                         f"parties: {', '.join(p['code'] for p in e['parties'])}")
            for leader in e["leaders"]:
                district = f" (District {leader['district']})" if leader["district"] else ""
                lines.append(f"    - {leader['name']} [{leader['party']}]{district}: {leader['votes']:,}")
            for note in e["notes"]:
                lines.append(f"    - note: {note}")
        lines.append("")
    (target_dir / "BUILD_REPORT.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {target_dir / 'manifest.json'} and BUILD_REPORT.md", flush=True)


def write_new_elections(year: int, reports: list[dict]) -> None:
    payload = {}
    if NEW_ELECTIONS.exists():
        try:
            payload = json.loads(NEW_ELECTIONS.read_text())
        except json.JSONDecodeError:
            payload = {}
    entries = [{"stateName": r["name"], "db": f"{CDN_BASE}/{year}/{r['db']}"}
               for r in sorted(reports, key=lambda r: r["name"])]
    payload[str(year)] = entries
    payload = dict(sorted(payload.items(), key=lambda kv: kv[0]))
    NEW_ELECTIONS.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {NEW_ELECTIONS.relative_to(ROOT)} ({len(entries)} entries for {year})", flush=True)
    # version + per-database size/sha256, which the app's update check reads
    import manifest_version
    manifest_version.stamp(NEW_ELECTIONS)


def report_from_db(path: Path) -> dict:
    db = sqlite3.connect(path)
    meta = dict(db.execute("SELECT key, value FROM meta"))
    elections = []
    for eid, office, name, special, total in db.execute("SELECT id, office, name, special, total_votes FROM elections ORDER BY id"):
        parties = [{"id": pid, "code": pcode, "name": pname} for pid, pcode, pname in
                   db.execute("SELECT id, code, name FROM parties WHERE election_id=?", (eid,))]
        leaders = [{"name": n, "party": p, "district": d, "votes": v} for n, p, d, v in db.execute(
            "SELECT c.name, p.code, c.district, c.votes FROM candidates c JOIN parties p ON p.id=c.party_id "
            "WHERE c.election_id=? ORDER BY c.votes DESC LIMIT 6", (eid,))]
        count = db.execute("SELECT count(*) FROM candidates WHERE election_id=?", (eid,)).fetchone()[0]
        elections.append({"id": eid, "office": office, "special": bool(special), "name": name,
                          "total_votes": total, "candidates": count, "parties": parties,
                          "leaders": leaders, "notes": []})
    db.close()
    return {"code": meta["state_code"], "name": meta["state_name"], "db": path.name, "source": meta.get("source", ""),
            "level": meta.get("level", ""), "size": path.stat().st_size, "sha256": b24.sha256(path),
            "elections": elections, "notes": [n for n in meta.get("notes", "").split(" | ") if n]}


# --------------------------------------------------------------------------- drivers


def build_vest_state(year: int, archive: Path, code: str, legend: dict, medsl_rows: list[dict] | None) -> dict:
    state_name = STATE_NAMES[code.lower()]
    gdf = load_vest_frame(archive, code)
    precinct_ids: list[int | None] = list(range(1, len(gdf) + 1))
    contests = vest_contests(gdf, code, year, precinct_ids, legend.get(code, {}))
    if not contests:
        raise ValueError(f"no {year} vote columns in the layer")
    geometry = vest_geometry(gdf, code, year)
    have = {cand.district for c in contests if c.office == "US House" for cand in c.candidates.values()}
    if medsl_rows is not None and code not in at_large_states(year):
        # Each precinct's largest contest total is the share it takes of House votes MEDSL reports only by county.
        weights = {i + 1: 0 for i in range(len(gdf))}
        for contest in contests:
            for pid, by_cand in contest.results.items():
                weights[pid] = max(weights[pid], sum(by_cand.values()))
        extra = supplement_house(medsl_rows, gdf, precinct_ids, geometry.precinct_county,
                                 state_counties(year, code), code, year, have, geometry.log,
                                 geometry.precinct_district, weights)
        if extra is not None:
            existing = next((c for c in contests if c.office == "US House" and not c.special), None)
            if existing is None:
                contests.append(extra)
            else:
                merge_contest(existing, extra)
    return write_state_db(year, code, state_name, geometry, contests, "VEST", "precinct")


def merge_contest(into: Contest, extra: Contest) -> None:
    """Add the candidates and precinct results of `extra` (already totalled) to `into`."""
    for ccode, cand in extra.candidates.items():
        if ccode not in into.candidates:
            into.candidates[ccode] = cand
        else:
            into.candidates[ccode].votes += cand.votes
    for pid, by_cand in extra.results.items():
        slot = into.results[pid]
        for ccode, votes in by_cand.items():
            slot[ccode] = slot.get(ccode, 0) + votes


def build_2020_state(archive: Path, code: str, legend: dict) -> dict:
    """2020 reuses the geometry already imported into data/2020-output."""
    year = 2020
    state_name = STATE_NAMES[code.lower()]
    template = OLD_2020_DIR / f"{code}.db"
    if not template.exists():
        raise ValueError(f"no 2020 geometry database {template}")
    old = sqlite3.connect(template)
    db_rows = old.execute("SELECT id, name FROM precincts ORDER BY id").fetchall()
    old.close()
    frame = b24.read_vest_attributes(archive)
    raw_names = precinct_names(frame)
    precinct_ids = b24.align_vest_rows(raw_names, db_rows)
    contests = vest_contests(frame, code, year, precinct_ids, legend.get(code, {}))
    geometry = Geometry()
    geometry.template = template
    geometry.log.append(f"geometry reused from {template.relative_to(ROOT)}")
    return write_state_db(year, code, state_name, geometry, contests, "VEST", "precinct")


def build_county_state(year: int, code: str) -> dict:
    state_name = STATE_NAMES[code.lower()]
    if year == 2023:
        counties = state_counties(year, code)
        contests = contests_2023(code, counties)
        source = "OpenElections" if code in ("KY", "MS") else "LA SOS"
    else:
        contests = dgumfi_contests(year, code)
        source = "Algara-Amlani"
    if not contests:
        raise ValueError("no county-level returns")
    geometry = county_geometry(year, code)
    geoid_index = geometry.geoid_index  # type: ignore[attr-defined]
    dropped = 0
    for contest in contests:
        remapped: dict[int, dict[str, int]] = collections.defaultdict(dict)
        for fips, by_cand in contest.results.items():
            pid = geoid_index.get(fips)
            if pid is None:
                dropped += sum(by_cand.values())
                for ccode, votes in by_cand.items():
                    contest.candidates[ccode].votes -= votes
                continue
            for ccode, votes in by_cand.items():
                remapped[pid][ccode] = remapped[pid].get(ccode, 0) + votes
        contest.results = remapped
    geometry.log.append(f"one precinct per county; boundaries from {county_layer_path(year).name}")
    if dropped:
        geometry.log.append(f"{dropped:,} votes in county FIPS codes absent from the Census layer were dropped")
    return write_state_db(year, code, state_name, geometry, [c for c in contests if c.total() > 0], source, "county")


def vest_archives(year: int) -> dict[str, Path]:
    folder = VEST_DIRS.get(year)
    if folder is None or not folder.exists():
        return {}
    out = {}
    for path in sorted(folder.glob("*.zip")):
        stem = path.stem.lower()
        code = stem[:2].upper()
        if code.lower() not in STATE_NAMES:
            continue
        if year == 2020 and len(stem) != 7:
            continue   # ky_2020_vtd_estimates.zip etc.
        if re.search(r"_(ushouse|statehouse|statesenate|demcaucus|pres_primary|special)", stem):
            continue
        out.setdefault(code, path)
    return out


def county_states(year: int) -> list[str]:
    if year == 2023:
        return [c for c in ("KY", "MS", "LA") if (OE_2023 / c.lower()).exists()]
    codes: set[str] = set()
    for office in ("President", "US Senate", "Governor"):
        frame = dgumfi(office)
        codes.update(frame[frame["election_year"] == year]["state"].astype(str).unique())
    return sorted(c for c in codes if c.lower() in STATE_NAMES)


def build_year(year: int, wanted: set[str], skip_national: bool) -> list[tuple[str, str]]:
    reports: list[dict] = []
    failures: list[tuple[str, str]] = []
    built: set[str] = set()

    def attempt(code: str, fn, *args) -> None:
        if wanted and code not in wanted:
            return
        try:
            reports.append(fn(*args))
            built.add(code)
        except Exception as error:
            failures.append((code, str(error)))
            print(f"FAILED {code} {year}: {error}", flush=True)
            traceback.print_exc()

    archives = vest_archives(year)
    if archives:
        legend = read_legend(year)
        for code, archive in archives.items():
            if year == 2020:
                attempt(code, build_2020_state, archive, code, legend)
            else:
                medsl = None
                if year == 2016:
                    medsl = medsl_rows_2016(code)
                elif year == 2018:
                    medsl = medsl_rows_2018(code)
                attempt(code, build_vest_state, year, archive, code, legend, medsl)
    if year == 2022:
        for code in sorted(STATE_NAMES):
            code = code.upper()
            if code == "DC":
                continue
            attempt(code, build_2022_state, code, STATE_NAMES[code.lower()])
    elif year in COUNTY_YEARS:
        if year == 2018:
            for code in sorted(STATE_NAMES):
                code = code.upper()
                if code in built or code in archives or code == "DC" or not (MEDSL_2018 / f"2018-{code.lower()}-precinct-general.zip").exists():
                    continue
                attempt(code, build_2022_state, code, STATE_NAMES[code.lower()], year)
        for code in county_states(year):
            if code in built or code in archives:
                continue
            attempt(code, build_county_state, year, code)
    # states built earlier keep their place in the manifest
    for path in sorted(out_dir(year).glob(f"*-{year}.db")) if out_dir(year).exists() else []:
        code = path.name[:2]
        if code not in built and code != "Na":
            reports.append(report_from_db(path))
    if reports and not skip_national:
        write_national(year, reports)
    if reports:
        write_manifest(year, reports)
        write_new_elections(year, reports)
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--years", nargs="+", type=int, required=True)
    parser.add_argument("--states", nargs="*", help="two-letter codes (default: every state with data)")
    parser.add_argument("--skip-national", action="store_true")
    parser.add_argument("--manifest-only", action="store_true",
                        help="only rewrite manifest.json, BUILD_REPORT.md, National and new_elections.json from the existing dbs")
    args = parser.parse_args()
    wanted = {s.upper() for s in args.states or []}
    all_failures = []
    for year in args.years:
        print(f"===== {year} =====", flush=True)
        if args.manifest_only:
            reports = [report_from_db(p) for p in sorted(out_dir(year).glob(f"*-{year}.db")) if p.name[:2] != "Na"]
            if reports:
                if not args.skip_national:
                    write_national(year, reports)
                write_manifest(year, reports)
                write_new_elections(year, reports)
            continue
        for code, error in build_year(year, wanted, args.skip_national):
            all_failures.append((year, code, error))
    if all_failures:
        print("\nFailures:")
        for year, code, error in all_failures:
            print(f"- {year} {code}: {error}")
        sys.exit(1)


if __name__ == "__main__":
    main()
