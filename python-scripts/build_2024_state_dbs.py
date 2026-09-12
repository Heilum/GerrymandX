#!/usr/bin/env python3
"""Rebuild the 2024 state databases as one file per state and year.

Output: new_data/2024/<CODE>-2024.db, one per state, holding

  * the geometry tables copied verbatim from data/output/2024-National-President/<CODE>.db
    (counties, congressional_districts, precincts, county_precincts,
    congressional_district_precincts, state_regions) — precinct ids are unchanged;
  * an `elections` table with up to four contests the state held in 2024
    (President, US Senate, US House, Governor; a special US Senate election is a
    separate row with special=1);
  * `parties` and `candidates` that belong to one election each, so every
    election carries its own party list, ids and colours;
  * `precinct_results` keyed by (precinct, election, candidate).

Sources are the same archives import_to_sqlite.py reads: the VEST/RDH precinct
layers in data/raw_data for 36 states (all four contests come from vote columns
in the same layer) and the MEDSL by-state returns for the other 14.  Candidate
display names for VEST's three-letter codes come from MEDSL's nationwide 2024
Senate and House files, then from the archive README, then from the code.

Also written: new_data/2024/National-2024.db (states + per-election totals),
new_data/2024/manifest.json and new_data/2024/BUILD_REPORT.md.

Run from this directory:
    .venv/bin/python build_2024_state_dbs.py [--states TX KS ...]
"""

from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import json
import re
import shutil
import sqlite3
import sys
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import geopandas as gpd
import pandas as pd

import import_to_sqlite as imp

ROOT = Path(__file__).resolve().parent
INPUT_DIR = ROOT / "data" / "raw_data"
OLD_DIR = ROOT / "data" / "output" / "2024-National-President"
OUT_DIR = ROOT / "new_data" / "2024"
MEDSL_NATIONAL_DIR = INPUT_DIR / "medsl_2024"
MEDSL_NAME_CACHE = MEDSL_NATIONAL_DIR / "candidate_index_2024.json"
YEAR = 2024
CDN_BASE = "https://files.xp-oncology.cn/gerrymander"
NEW_ELECTIONS = ROOT / "new_data" / "new_elections.json"

ID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://gerrymanderx.app/elections/v2")

OFFICES = ("President", "US Senate", "US House", "Governor")
OFFICE_SLUG = {"President": "president", "US Senate": "us-senate",
               "US House": "us-house", "Governor": "governor"}
MEDSL_OFFICE = {"US PRESIDENT": "President", "US SENATE": "US Senate",
                "US HOUSE": "US House", "GOVERNOR": "Governor"}

# Party code -> (name, ARGB colour).  The first seven mirror import_to_sqlite.
PARTY_INFO = dict(imp.PARTIES)
PARTY_INFO.update({
    "CST": ("Constitution", 0xFF8D6E63),
    "NPA": ("No Party Affiliation", 0xFF9E9E9E),
    "WFP": ("Working Families", 0xFF7E57C2),
    "CON": ("Conservative", 0xFFEF6C00),
    "UST": ("US Taxpayers", 0xFFA1887F),
    "WCP": ("Working Class", 0xFF8E24AA),
    "NLP": ("Natural Law", 0xFF26A69A),
    "MTN": ("Mountain", 0xFF43A047),
    "PAJ": ("Peace and Justice", 0xFF00897B),
    "EPC": ("Epic", 0xFF5C6BC0),
    "BTR": ("Better Party", 0xFF00ACC1),
    "CGG": ("Cheaper Gas Groceries", 0xFFF4511E),
    "ALP": ("Alliance", 0xFF6D4C41),
    "UCP": ("United Citizens", 0xFF78909C),
    "IAP": ("Independent American", 0xFF8D6E63),
    "AIP": ("American Independent", 0xFF8D6E63),
    "PFP": ("Peace and Freedom", 0xFF00897B),
    "LAR": ("LaRouche", 0xFF6D4C41),
    "UNE": ("Unenrolled", 0xFF9E9E9E),
    "FWD": ("Forward", 0xFF29B6F6),
    "AMR": ("American", 0xFF8D6E63),
    "NON": ("Nonpartisan", 0xFF9E9E9E),
    "AKI": ("Alaskan Independence", 0xFF8D6E63),
})
# Words in a README party name -> party code.  Checked in order.
PARTY_NAME_WORDS = [
    ("write", "WRI"), ("democrat", "DEM"), ("dem/prog", "DEM"), ("republican", "REP"),
    ("gop", "REP"), ("libertarian", "LIB"), ("green", "GRN"), ("constitution", "CST"),
    ("working families", "WFP"), ("working class", "WCP"), ("taxpayer", "UST"),
    ("natural law", "NLP"), ("mountain", "MTN"), ("peace and justice", "PAJ"),
    ("peace & justice", "PAJ"), ("peace and freedom", "PFP"), ("epic", "EPC"),
    ("better", "BTR"), ("cheaper gas groceries", "CGG"), ("alliance", "ALP"),
    ("alaskan independence", "AKI"),
    ("united citizens", "UCP"), ("independent american", "IAP"),
    ("american independent", "AIP"), ("larouche", "LAR"), ("unenrolled", "UNE"),
    ("forward", "FWD"), ("conservative", "CON"), ("no party", "NPA"),
    ("npa", "NPA"), ("nonpartisan", "NON"), ("non-partisan", "NON"),
    ("independent", "IND"), ("american", "AMR"), ("other", "OTH"),
]
# Party abbreviations that appear inside README field descriptions.
PARTY_ABBREVIATIONS = {
    "DEM": "DEM", "D": "DEM", "REP": "REP", "R": "REP", "LIB": "LIB", "LBN": "LIB",
    "L": "LIB", "LPF": "LIB", "GRN": "GRN", "GRE": "GRN", "G": "GRN", "IND": "IND",
    "I": "IND", "NPA": "NPA", "NON": "NON", "CST": "CST", "CON": "CON", "WFP": "WFP",
    "WI": "WRI", "W": "WRI", "UST": "UST", "NLP": "NLP", "MTN": "MTN", "BTR": "BTR",
    "OTC": "OTH", "OTHER": "OTH", "O": "OTH", "U": "NPA",
}
MEDSL_PARTY = {"DEMOCRAT": "DEM", "REPUBLICAN": "REP", "LIBERTARIAN": "LIB",
               "GREEN": "GRN", "INDEPENDENT": "IND", "NONPARTISAN": "NON",
               "OTHER": "OTH", "": "OTH"}

# Hand-checked from the archive READMEs; these override every other source.
GOVERNOR_NAMES = {
    "DE": {"DMEY": "Matt Meyer", "RRAM": "Mike Ramone"},
    "MO": {"DQUA": "Crystal Quade", "GLEH": "Paul Lehmann", "LSLA": "Bill Slantz",
           "OBRO": "Theo (Ted) Brown Sr.", "RKEH": "Mike Kehoe"},
    "MT": {"DBUS": "Ryan Busse", "LLEI": "Kaiser Leib", "RGIA": "Greg Gianforte"},
    "NC": {"CSMI": "Vinny Smith", "DSTE": "Josh Stein", "GTUR": "Wayne Turner",
           "LROS": "Mike Ross", "RROB": "Mark Robinson"},
    "ND": {"DPIE": "Merrill Piepkorn", "ICOA": "Michael Coachman", "RARM": "Kelly Armstrong"},
    "NH": {"DCRA": "Joyce Craig", "LVIL": "Stephen Villee", "RAYO": "Kelly Ayotte"},
    "UT": {"RHEN": "Spencer J. Cox", "DCUM": "Brian Smith King", "NCLA": "Phil Lyman",
           "LSHO": "J. Robert Latham", "IWIL": "Tommy Williams", "NTAY": "Tom Tomeny",
           "NFIS": "Charlie Tautuaa"},
    "VT": {"DCHA": "Esther Charlestin", "IHOY": "Kevin Hoyt", "IMUT": "Eli \"Poa\" Mutino",
           "JGOO": "June Goodband", "RSCO": "Phil Scott"},
    "WA": {"DFER": "Bob Ferguson", "RREI": "Dave Reichert"},
    "WV": {"CWIL": "S. Marshall Wilson", "DWIL": "Steve Williams", "LKOL": "Erika Klie Kolenich",
           "MLIN": "Chase Linko-Looper", "RMOR": "Patrick Morrisey"},
}
# MEDSL rows whose party is blank on every ballot line (New Jersey reports
# some districts by slogan only); keyed by state then candidate key.
MEDSL_PARTY_OVERRIDES = {
    "NJ": {"3-HERBCONAWAY": "DEM", "3-RAJESHMOHAN": "REP"},
}
# VEST layers that leave out whole US House districts.  Texas's source (the
# Capitol Data Portal) drops every single-candidate race, so the five
# unopposed 2024 districts (1, 9, 11, 13, 20) have no vote columns although
# the votes were cast and counted.  MEDSL's nationwide House file has them by
# precinct; the function maps a MEDSL row onto the layer's precinct name.
# Texas: MEDSL precinct "190007" = SOS county number + 4-digit precinct, the
# layer's precinct is "<COUNTYFP>-<precinct>" ("037-0007").
def _tx_precinct_name(row: dict) -> list[str]:
    county = str(row["county_fips"]).zfill(5)[2:]
    precinct = str(row["precinct"]).strip()[-4:]
    names = [f"{county}-{precinct}"]
    if precinct and precinct[-1].isalpha():  # "004A" is a split of "0004"
        names.append(f"{county}-{precinct[:-1].zfill(4)}")
    return names


MEDSL_HOUSE_SUPPLEMENT = {"TX": _tx_precinct_name}

# Party letters used inconsistently by one archive: West Virginia's House
# columns all carry R although the README names the party of each candidate.
PARTY_LETTER_OVERRIDES: dict[str, dict[str, str]] = {}

VEST_STATEWIDE = re.compile(r"^([GS])24(USS|GOV)([A-Z])([A-Z0-9]{2,})$")
VEST_HOUSE = re.compile(r"^GCON(\d+|AL)([A-Z])([A-Z0-9]{2,})$")
NY_HOUSE = re.compile(r"^G24CON([DRO])$")
WI_COLUMN = re.compile(r"^(USS|USH)(DEM|REP|LIB|GRE|CON|IND\d?|NP\d?|SCT|WGR|TOT)24$")
WI_TOKEN_PARTY = {"DEM": "DEM", "REP": "REP", "LIB": "LIB", "GRE": "GRN", "CON": "CST",
                  "IND": "IND", "IND1": "IND", "IND2": "IND", "NP": "OTH", "NP1": "OTH",
                  "SCT": "WRI", "WGR": "WRI"}
GENERIC_CODES = {"WRI": "Write-in", "OTH": "Other"}
NAME_SUFFIXES = {"JR", "SR", "II", "III", "IV", "V"}


def party_uuid(code: str, election_slug: str, party_code: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{code}-{YEAR}/{election_slug}/party/{party_code}"))


def candidate_uuid(code: str, election_slug: str, candidate_code: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{code}-{YEAR}/{election_slug}/candidate/{candidate_code}"))


def election_slug(office: str, special: bool) -> str:
    return OFFICE_SLUG[office] + ("-special" if special else "")


def title_case(name: str) -> str:
    """MEDSL writes candidates in upper case; make them readable."""
    words = []
    for word in name.split():
        upper = word.upper().strip(".")
        if upper in ("JR", "SR"):
            words.append(upper.capitalize() + ".")
        elif upper in ("II", "III", "IV"):
            words.append(upper)
        else:
            out = "-".join(re.sub(r"[A-Za-z]", lambda m: m.group(0).upper(), part.lower(), count=1)
                           for part in word.split("-"))
            for prefix in ("Mc", "O'", "D'"):
                if out.startswith(prefix) and len(out) > len(prefix) + 1:
                    out = prefix + out[len(prefix):].capitalize()
            words.append(out)
    return " ".join(words)


def surname_tokens(name: str) -> list[str]:
    tokens = [re.sub(r"[^A-Z]", "", t.upper()) for t in name.replace("-", " ").split()]
    tokens = [t for t in tokens if t and t not in NAME_SUFFIXES]
    return tokens


SURNAME_PARTICLES = {"DE", "LA", "DEL", "DELA", "VAN", "VON", "DER", "DEN", "DI", "DA", "DU", "LE", "MC", "MAC",
                     "O", "ST", "SAN", "SANTA", "AL", "EL", "BIN", "TER", "TE", "DOS", "DAS", "LOS", "LAS"}


def matches_code(name: str, code: str) -> int:
    """0 = no match, 1 = some token starts with the code, 2 = the surname does.

    "DE LA CRUZ" is matched as DELACRUZ as well as CRUZ, but only particles are
    joined: BERNIE SANDERS must not become BERNIESANDERS and match "BER"."""
    tokens = surname_tokens(name)
    if not tokens:
        return 0
    if tokens[-1].startswith(code):
        return 2
    joined = tokens[-1]
    for token in reversed(tokens[:-1]):
        if token not in SURNAME_PARTICLES:
            break
        joined = token + joined
        if joined.startswith(code):
            return 2
    return 1 if any(t.startswith(code) for t in tokens[:-1]) else 0


# --------------------------------------------------------------------------- MEDSL


def medsl_office_name(raw: str) -> str | None:
    """MEDSL office label -> our office; special Senate seats are labelled
    "US SENATE PARTIAL" or "US SENATE - 2 YEAR TERM"."""
    text = raw.strip().upper()
    if text in MEDSL_OFFICE:
        return MEDSL_OFFICE[text]
    if text.startswith("US SENATE") and "SHADOW" not in text:
        return "US Senate"
    return None


def load_medsl_name_index() -> dict:
    """{state: {office: {district: [(candidate, party_simplified, votes)]}}}.

    Built from MEDSL's nationwide Senate and House files and cached as JSON;
    used only to give VEST's three-letter candidate codes a display name.
    """
    if MEDSL_NAME_CACHE.exists():
        return json.loads(MEDSL_NAME_CACHE.read_text())
    index: dict = {}
    totals: collections.Counter = collections.Counter()
    for name in ("SENATE_precinct_general.csv", "HOUSE_precinct_general.csv"):
        path = MEDSL_NATIONAL_DIR / name
        if not path.exists():
            print(f"  ! {path} missing; VEST candidate names will fall back to the README", flush=True)
            continue
        with path.open(encoding="utf8", errors="ignore", newline="") as handle:
            for row in csv.DictReader(handle):
                office = medsl_office_name(row["office"])
                if office is None or row.get("stage", "GEN") != "GEN" or row.get("writein") == "TRUE":
                    continue
                candidate = row["candidate"].strip().upper()
                if not candidate or imp.MEDSL_ACCOUNTING.search(candidate):
                    continue
                try:
                    count = int(float(row["votes"]))
                except (TypeError, ValueError):
                    count = 0
                if office == "US House":
                    raw = row["district"].strip().upper()
                    district = "At-large" if raw in {"AT-LARGE", "AL", "STATEWIDE", ""} else (imp.normalize_district(raw) or raw)
                else:
                    district = ""
                special = row.get("special") == "TRUE"
                key = (row["state_po"], office + (" special" if special else ""), district,
                       candidate, row["party_simplified"].strip().upper())
                totals[key] += count
    for (state, office, district, candidate, party), count in totals.items():
        index.setdefault(state, {}).setdefault(office, {}).setdefault(district, []).append(
            [candidate, party, count])
    MEDSL_NATIONAL_DIR.mkdir(parents=True, exist_ok=True)
    MEDSL_NAME_CACHE.write_text(json.dumps(index))
    return index


def medsl_lookup(index: dict, state: str, office: str, special: bool, district: str,
                 code3: str, party: str | None) -> tuple[str | None, str | None, int]:
    """Find the MEDSL candidate a VEST code refers to -> (name, party_simplified, match level)."""
    pool = index.get(state, {}).get(office + (" special" if special else ""), {}).get(district or "", [])
    if not pool and office != "US House":
        pool = index.get(state, {}).get(office + (" special" if special else ""), {}).get("", [])
    hits = [(matches_code(c, code3), c, p, v) for c, p, v in pool if not imp.MEDSL_ACCOUNTING.search(c)]
    best = [h for h in hits if h[0] == 2] or [h for h in hits if h[0] == 1]
    if not best:
        return None, None, 0
    if len({h[1] for h in best}) > 1 and party:
        wanted = {v: k for k, v in MEDSL_PARTY.items()}.get(party)
        same = [h for h in best if h[2] == wanted]
        if same:
            best = same
    if len({h[1] for h in best}) > 1:
        # Prefer the candidate with more votes only when the gap is decisive.
        best.sort(key=lambda h: -h[3])
        if best[1][3] and best[0][3] < 20 * best[1][3]:
            return None, None, 0
    return title_case(best[0][1]), best[0][2], best[0][0]


# --------------------------------------------------------------------------- README


def read_readme(archive: Path) -> tuple[dict[str, str], dict[str, str]]:
    """({field: description}, {party letter: party name}) from an archive README."""
    fields, letters = {}, {}
    with zipfile.ZipFile(archive) as bundle:
        names = [n for n in bundle.namelist() if n.lower().endswith("readme.txt")]
        if not names:
            return fields, letters
        text = bundle.open(names[0]).read().decode("utf8", "ignore")
    in_parties = False
    for line in text.splitlines():
        stripped = line.strip()
        if re.match(r"^#*\s*party codes", stripped, re.I):
            in_parties = True
            continue
        if in_parties:
            match = re.match(r"^([A-Z])\s*[-–:]\s*(.+)$", stripped)
            if match:
                letters[match.group(1)] = match.group(2).strip()
                continue
            if stripped and not match and letters:
                in_parties = False
        match = re.match(r"^([GSRP]\d\d[A-Z0-9]{3,}|GCON[A-Z0-9]+|GSL[A-Z0-9]+|GSU[A-Z0-9]+|US[SH][A-Z0-9]+24)\s+(.+)$", stripped)
        if match:
            fields.setdefault(match.group(1), match.group(2).strip())
    return fields, letters


OFFICE_WORDS = re.compile(
    r"\b(U\.?\s?S\.?\s*(SEN\w*|HOUSE|REP\w*|CONGRESS\w*)|UNITED STATES (SENAT\w*|HOUSE|REPRESENTATIVE\w*)|"
    r"SENATOR( IN CONGRESS)?|SENATE|SEN|GOVERNOR( (&|AND) L(IEU)?T\.? GOVERNOR)?|LT\.? GOVERNOR|"
    r"HOUSE OF REPRESENTATIVES|CONGRESSIONAL( DISTRICT)?|DISTRICT( \d+)?|\d+(ST|ND|RD|TH)|"
    r"PRESIDENT\w*|ELECTORS?( FOR)?|VICE PRESIDENT|VOTES?|GENERAL ELECTION|COUNTYWIDE|"
    r"STATE OF \w+|6 YEAR TERM|\(\d\) POSITION|FOR|TERM|YEAR|POSITION|NONE|NC|CANDIDATE)\b", re.I)
PARTY_WORDS = re.compile(
    r"\b(DEMOCRAT\w*|REPUBLICAN\w*|LIBERTARIAN\w*|GREEN|INDEPENDENT\w*|CONSTITUTION\w*|WRITE[- ]?INS?|"
    r"NONPARTISAN|NO PARTY( AFFILIATION)?|OTHER|PARTY|PREFERS|GOP|DEM|REP|LIB|LBN|GRN|GRE|IND|NPA|NON|CST|"
    r"WFP|UST|NLP|MTN|BTR|WI|CON|LPF|OTC|D|R|L|G|I|W|O|U|N|C|DEM/PROG|PEACE AND JUSTICE|EPIC|MOUNTAIN|"
    r"WORKING (CLASS|FAMILIES)( PARTY)?|US TAXPAYERS|NATURAL LAW( PARTY)?|CHEAPER GAS GROCERIES|"
    r"INDEPENDENT AMERICAN|ALLIANCE|UNITED CITIZENS|LAROUCHE|UNENROLLED|FORWARD|AMERICAN)\b", re.I)


PARTY_STOP_WORDS = {"party", "prefers", "the", "of", "line", "ticket"}


def readme_party(description: str) -> str | None:
    """Party code named inside a README field description, if any.

    A part of the description counts as a party only when nothing but the party
    phrase (plus filler such as "Party" or "Prefers") is left in it, so that a
    candidate called Green or Independence Township is not read as a party.
    """
    text = re.sub(r"<br\s*/?>", " ", description)
    for part in re.split(r"-:-|,|\t|\s-\s", text):
        part = part.strip().strip("()").strip()
        if not part:
            continue
        lowered = part.lower()
        if part.upper() in PARTY_ABBREVIATIONS and len(part) <= 5:
            return PARTY_ABBREVIATIONS[part.upper()]
        for word, code in PARTY_NAME_WORDS:
            pattern = r"\bwrite[- ]?ins?\b" if word == "write" else r"\b" + re.escape(word) + r"\w*"
            if re.search(pattern, lowered):
                rest = re.sub(pattern, " ", lowered)
                rest = [w for w in re.findall(r"[a-z]+", rest) if w not in PARTY_STOP_WORDS]
                if not rest:
                    return code
                break
    match = re.search(r"\(([A-Za-z]{1,5})\)", text)
    if match and match.group(1).upper() in PARTY_ABBREVIATIONS:
        return PARTY_ABBREVIATIONS[match.group(1).upper()]
    return None


def readme_name(description: str) -> str | None:
    """Best-effort person name from a README field description."""
    text = re.sub(r"<br\s*/?>", " ", description)
    text = re.sub(r"\s+Votes\s*\(.*?\)\s*$", "", text)
    text = re.sub(r"\(\s*write-?\s*(in)?\s*\)", "", text, flags=re.I)
    candidates = []
    for part in re.split(r"-:-|,|\t|\s-\s", text):
        part = re.sub(r"\((?:[A-Z]{1,5}|Write-in|write-in)\)", "", part).strip()
        part = re.sub(r"\s+", " ", part)
        if not part:
            continue
        # "United States Senator Debbie Mucarsel-Powell"
        cleaned = OFFICE_WORDS.sub(" ", part)
        cleaned = re.sub(r"\b(of|in|the|Representatives?|Congress|US|U\.S\.)\b", " ", cleaned, flags=re.I)
        cleaned = re.sub(r"\s+", " ", cleaned).strip(" .:-")
        cleaned = re.sub(r"(\s+\d+)+$", "", cleaned).strip()
        if not cleaned or PARTY_WORDS.fullmatch(cleaned) or re.search(r"\d", cleaned):
            continue
        if PARTY_WORDS.fullmatch(cleaned.replace(" Party", "")):
            continue
        if re.search(r"[a-z]", cleaned) is None and len(cleaned.split()) == 1 and len(cleaned) <= 4:
            continue
        if re.search(r"[A-Za-z]", cleaned) is None:
            continue
        candidates.append(cleaned)
    if not candidates:
        return None
    # Prefer a part that looks like "First Last".
    chosen = next((part for part in candidates if " " in part and not OFFICE_WORDS.search(part)), candidates[0])
    return title_case(chosen) if chosen == chosen.upper() else chosen


# --------------------------------------------------------------------------- contests


class Candidate:
    __slots__ = ("code", "name", "party", "district", "columns", "votes")

    def __init__(self, code: str, name: str, party: str, district: str | None):
        self.code, self.name, self.party, self.district = code, name, party, district
        self.columns: list[str] = []
        self.votes = 0


class Contest:
    def __init__(self, office: str, special: bool = False):
        self.office, self.special = office, special
        self.candidates: dict[str, Candidate] = {}
        # precinct_id -> {candidate code: votes}
        self.results: dict[int, dict[str, int]] = collections.defaultdict(dict)
        self.notes: list[str] = []

    @property
    def slug(self) -> str:
        return election_slug(self.office, self.special)

    def add(self, precinct_id: int, code: str, votes: int) -> None:
        if votes:
            slot = self.results[precinct_id]
            slot[code] = slot.get(code, 0) + votes
            self.candidates[code].votes += votes

    def total(self) -> int:
        return sum(c.votes for c in self.candidates.values())


def party_from_letter(letter: str, letters: dict[str, str]) -> str:
    """Party code for a VEST column letter, using the README's own legend.

    Only the first alternative of a legend such as "Independent / Independent
    Democrat" or "Democrat or Dem / Progressive" is read.
    """
    if letter == "O":
        return "OTH"
    name = letters.get(letter, "")
    primary = re.split(r"\s*/\s*|\s+or\s+", name.lower())[0]
    for word, code in PARTY_NAME_WORDS:
        pattern = r"\bwrite" if word == "write" else r"\b" + re.escape(word)
        if re.search(pattern, primary):
            return code
    if letter in imp.PARTY_LETTERS:
        return imp.PARTY_LETTERS[letter]
    return "OTH"


def resolve_name(code: str, office: str, special: bool, district: str | None, letter: str,
                 code3: str, party: str, description: str | None, index: dict) -> tuple[str, str, str]:
    """-> (display name, party code, source) for one VEST vote column.

    The party comes from the column letter, unless the README description
    spells out a different party (West Virginia letters every House column R)
    or, failing that, MEDSL knows the candidate as a Democrat or Republican.
    """
    if code3 in GENERIC_CODES and letter in ("O", "W", "N", "U"):
        return GENERIC_CODES[code3], ("WRI" if code3 == "WRI" else party), "generic"
    if office == "Governor" and (letter + code3) in GOVERNOR_NAMES.get(code, {}):
        return GOVERNOR_NAMES[code][letter + code3], party, "hand"
    readme_p = readme_party(description) if description else None
    if readme_p and readme_p != party:
        party = readme_p
    name, medsl_party, level = medsl_lookup(index, code, office, special, district, code3, party)
    guess = readme_name(description) if description else None
    if name and (level == 2 or not guess):
        medsl_code = MEDSL_PARTY.get(medsl_party or "")
        # MEDSL's party is only trusted where the column letter says nothing
        # (it lists Nebraska's independent Dan Osborn as a Democrat).
        if medsl_code in ("DEM", "REP") and party == "OTH" and readme_p is None:
            party = medsl_code
        return name, party, "medsl"
    if guess:
        return guess, party, "readme"
    return code3.capitalize(), party, "code"


def vest_contests(frame: pd.DataFrame, code: str, archive: Path, index: dict,
                  precinct_ids: list[int]) -> list[Contest]:
    """Parse every 2024 contest out of a VEST attribute table.

    `precinct_ids[i]` is the database precinct id for frame row i (None when
    the row was dropped by the original import).
    """
    descriptions, letters = read_readme(archive)
    contests: dict[str, Contest] = {}

    def contest(office: str, special: bool = False) -> Contest:
        key = election_slug(office, special)
        if key not in contests:
            contests[key] = Contest(office, special)
        return contests[key]

    # President — same column mapping as the original import.
    president = contest("President")
    for column, cand in imp.president_columns(frame):
        name, party = imp.CANDIDATES.get(cand, (cand, "OTH"))
        if cand not in president.candidates:
            president.candidates[cand] = Candidate(cand, name, party, None)
        president.candidates[cand].columns.append(column)

    house_district_field = imp.first_column(frame, imp.DISTRICT_FIELDS)
    per_row_house: list[tuple[str, str, str]] = []   # (column, party code, party letter)
    for column in frame.columns:
        upper = str(column).upper()
        match = VEST_STATEWIDE.match(upper)
        if match:
            prefix, office_code, letter, code3 = match.groups()
            office = "US Senate" if office_code == "USS" else "Governor"
            special = prefix == "S"
            party = party_from_letter(letter, letters)
            name, party, source = resolve_name(code, office, special, None, letter, code3, party,
                                               descriptions.get(upper), index)
            target = contest(office, special)
            ccode = f"{letter}{code3}"
            target.candidates[ccode] = Candidate(ccode, name, party, None)
            target.candidates[ccode].columns.append(column)
            target.notes.append(f"{upper}: {name} [{party}] via {source}")
            continue
        match = VEST_HOUSE.match(upper)
        if match:
            district_raw, letter, code3 = match.groups()
            district = "At-large" if district_raw == "AL" else str(int(district_raw))
            party = party_from_letter(letter, letters)
            override = PARTY_LETTER_OVERRIDES.get(code, {}).get(upper)
            if override:
                party = override
            name, party, source = resolve_name(code, "US House", False, district, letter, code3, party,
                                               descriptions.get(upper), index)
            target = contest("US House")
            ccode = f"{district}-{letter}{code3}"
            target.candidates[ccode] = Candidate(ccode, name, party, district)
            target.candidates[ccode].columns.append(column)
            target.notes.append(f"{upper}: {name} [{party}] via {source}")
            continue
        match = NY_HOUSE.match(upper)
        if match:
            per_row_house.append((column, {"D": "DEM", "R": "REP", "O": "OTH"}[match.group(1)], match.group(1)))
            continue
        match = WI_COLUMN.match(upper)
        if match and code == "WI":
            office_code, token = match.groups()
            if token == "TOT":
                continue
            party = WI_TOKEN_PARTY[token]
            if office_code == "USS":
                target = contest("US Senate")
                name = wi_party_candidate(index, code, "US Senate", "", party, token)
                target.candidates[token] = Candidate(token, name, party, None)
                target.candidates[token].columns.append(column)
                target.notes.append(f"{upper}: {name} [{party}] via medsl-party")
            else:
                per_row_house.append((column, party, token))
            continue

    # Party-aggregate House columns (NY, WI): the district comes from the row.
    if per_row_house:
        if house_district_field is None:
            raise ValueError(f"{code}: House party columns without a district field")
        target = contest("US House")
        districts = [imp.normalize_district(v) for v in frame[house_district_field]]
        for column, party, token in per_row_house:
            values = frame[column].tolist()
            for row_index, (district, value) in enumerate(zip(districts, values)):
                pid = precinct_ids[row_index]
                if pid is None or not district:
                    continue
                ccode = f"{district}-{token}"
                if ccode not in target.candidates:
                    name = wi_party_candidate(index, code, "US House", district, party, token)
                    target.candidates[ccode] = Candidate(ccode, name, party, district)
                target.add(pid, ccode, imp.as_int(value))

    # Column-based votes.
    for target in contests.values():
        for cand in target.candidates.values():
            for column in cand.columns:
                values = frame[column].tolist()
                for row_index, value in enumerate(values):
                    pid = precinct_ids[row_index]
                    if pid is not None:
                        target.add(pid, cand.code, imp.as_int(value))
    for target in contests.values():
        name_by_totals(target, index, code)
    if code in MEDSL_HOUSE_SUPPLEMENT and "us-house" in contests:
        supplement_house_from_medsl(code, contests["us-house"], index, precinct_ids, frame)
    return [c for c in contests.values() if c.total() > 0]


def supplement_house_from_medsl(code: str, contest: Contest, index: dict,
                                precinct_ids: list, frame: pd.DataFrame) -> None:
    """Add the House districts the VEST layer has no columns for, from MEDSL."""
    have = {c.district for c in contest.candidates.values()}
    missing = {d for d in index.get(code, {}).get("US House", {}) if d not in have}
    if not missing:
        return
    precinct_field = imp.first_column(frame, ["UNIQUE_ID", "GEOID", "VTD", "VTDST", "PRECINCT", "PRECINCTNA",
                                              "PRECINCT_NA", "WARDID", "LABEL"])
    id_by_name = {}
    for row_index, value in enumerate(frame[precinct_field]):
        pid = precinct_ids[row_index]
        if pid is not None:
            id_by_name.setdefault(imp.as_text(value, ""), pid)
    key_of = MEDSL_HOUSE_SUPPLEMENT[code]
    path = MEDSL_NATIONAL_DIR / "HOUSE_precinct_general.csv"
    votes: dict[tuple, dict[str, int]] = collections.defaultdict(dict)
    unmatched: collections.Counter = collections.Counter()
    with path.open(encoding="utf8", errors="ignore", newline="") as handle:
        for row in csv.DictReader(handle):
            if row["state_po"] != code or row.get("special") == "TRUE":
                continue
            raw = row["district"].strip().upper()
            district = "At-large" if raw in {"AT-LARGE", "AL"} else (imp.normalize_district(raw) or raw)
            if district not in missing:
                continue
            name = row["candidate"].strip().upper()
            if imp.MEDSL_ACCOUNTING.search(name) or MEDSL_EXTRA_ACCOUNTING.search(name):
                continue
            try:
                count = int(float(row["votes"]))
            except (TypeError, ValueError):
                continue
            pid = next((id_by_name[n] for n in key_of(row) if n in id_by_name), None)
            if pid is None:
                unmatched[district] += count
                continue
            party = medsl_party_code(row["party_detailed"], row["party_simplified"])
            if row["writein"] == "TRUE":
                ccode, cname = f"{district}-OWRI", "Write-in"
                party = "WRI"
            else:
                surname = surname_tokens(name)[-1][:3] if surname_tokens(name) else name[:3]
                ccode, cname = f"{district}-{party[0]}{surname}", title_case(name)
            if ccode not in contest.candidates:
                contest.candidates[ccode] = Candidate(ccode, cname, party, district)
            slot = votes[(pid, ccode)]
            slot[row["mode"]] = slot.get(row["mode"], 0) + count
    added: collections.Counter = collections.Counter()
    for (pid, ccode), modes in votes.items():
        total = modes["TOTAL"] if "TOTAL" in modes else sum(modes.values())
        contest.add(pid, ccode, total)
        added[contest.candidates[ccode].district] += total
    for district in sorted(missing, key=lambda d: (len(d), d)):
        contest.notes.append(
            f"District {district} has no VEST columns; {added[district]:,} votes added from MEDSL"
            + (f", {unmatched[district]:,} in precincts that could not be matched" if unmatched[district] else ""))


def name_by_totals(contest: Contest, index: dict, code: str) -> None:
    """Name party-aggregate candidates (NY, WI) after the MEDSL candidate whose
    statewide or district total is closest to the column total."""
    for cand in contest.candidates.values():
        if not cand.name.endswith(" candidate") or cand.votes == 0:
            continue
        pool = index.get(code, {}).get(contest.office + (" special" if contest.special else ""), {}).get(cand.district or "", [])
        wanted = {v: k for k, v in MEDSL_PARTY.items()}.get(cand.party)
        options = [p for p in pool if p[1] == wanted] if cand.party in ("DEM", "REP", "LIB", "GRN") \
            else [p for p in pool if p[1] in ("INDEPENDENT", "OTHER", "NONPARTISAN", "")]
        if not options:
            continue
        best = min(options, key=lambda p: abs(p[2] - cand.votes))
        if abs(best[2] - cand.votes) <= max(0.05 * cand.votes, 50):
            cand.name = title_case(best[0])


def wi_party_candidate(index: dict, code: str, office: str, district: str, party: str, token: str) -> str:
    """Name for a party-aggregate column: the MEDSL candidate of that party."""
    wanted = {v: k for k, v in MEDSL_PARTY.items()}.get(party)
    pool = index.get(code, {}).get(office, {}).get(district or "", [])
    same = sorted([p for p in pool if p[1] == wanted], key=lambda p: -p[2])
    label = PARTY_INFO.get(party, (party, 0))[0]
    if party in ("WRI", "OTH"):
        return {"SCT": "Scattering", "WGR": "Write-in", "NP": "Nonpartisan / write-in",
                "NP1": "Nonpartisan / write-in", "O": "Other"}.get(token, label)
    if token in ("IND1", "IND2") and len(same) >= 2:
        return title_case(same[int(token[-1]) - 1][0])
    if len(same) == 1 or (same and same[0][2] > 5 * (same[1][2] or 1)):
        return title_case(same[0][0])
    return f"{label} candidate"


# --------------------------------------------------------------------------- MEDSL states


def medsl_contests(rows: list[dict], code: str, precinct_index: dict[tuple[str, str], int]) -> list[Contest]:
    """Build every 2024 contest from a MEDSL by-state file.

    `precinct_index` maps (county fips, normalised precinct) -> db precinct id,
    established from the President tally exactly as the original import did.
    """
    contests: list[Contest] = []
    for medsl_office, office in MEDSL_OFFICE.items():
        for special in (False, True):
            tally, display, info = medsl_tally(rows, medsl_office, special, MEDSL_PARTY_OVERRIDES.get(code, {}))
            if not tally:
                continue
            contest = Contest(office, special)
            unplaced = 0
            for key in imp.drop_county_totals(tally, display, code):
                del tally[key]
            for ckey, (name, party, district) in info.items():
                contest.candidates[ckey] = Candidate(ckey, name, party, district)
            for key, votes in tally.items():
                pid = precinct_index.get(key)
                if pid is None:
                    unplaced += sum(votes.values())
                    continue
                for ckey, count in votes.items():
                    contest.add(pid, ckey, count)
            if unplaced:
                contest.notes.append(f"{unplaced:,} votes in precincts absent from the President tally were not placed")
            contests.append(contest)
    return contests


MEDSL_EXTRA_ACCOUNTING = re.compile(r"SPOILED|VOID|EXHAUSTED|REJECTED|NO VOTE|NOT ASSIGNED|UNRESOLVED")
MEDSL_DETAILED_WORDS = [
    ("DEMOCRAT", "DEM"), ("REPUBLICAN", "REP"), ("LIBERTARIAN", "LIB"), ("GREEN", "GRN"),
    ("INDEPENDENT AMERICAN", "IAP"), ("CONSTITUTION", "CST"), ("WORKING FAMILIES", "WFP"),
    ("PROGRESSIVE", "PRG"), ("INDEPENDENT", "IND"), ("NONPARTISAN", "NON"), ("NO PARTY", "NPA"),
    ("UNAFFILIATED", "NPA"), ("WRITE", "WRI"),
]
PARTY_INFO.setdefault("PRG", ("Progressive", 0xFF7E57C2))
KNOWN_PARTIES = {code for code in PARTY_INFO if code not in ("OTH", "NON", "NPA", "WRI")}


def medsl_party_code(detailed: str, simplified: str) -> str:
    """Party code for a MEDSL row, reading party_detailed before party_simplified.

    New Jersey and Oregon report fusion or slogan lines with a blank or OTHER
    party_simplified; party_detailed usually still names the party."""
    text = detailed.strip().upper()
    for word, code in MEDSL_DETAILED_WORDS:
        if word in text:
            return code
    return MEDSL_PARTY.get(simplified.strip().upper(), "OTH")


def medsl_tally(rows: list[dict], medsl_office: str, special: bool, overrides: dict[str, str] | None = None):
    """Replicates import_medsl_state's tally for any office.

    For the President the candidate keys, accounting filter and party come from
    import_to_sqlite so the result matches the existing databases exactly.  For
    the other offices a candidate is keyed by (district, name) so that the same
    person reported on several ballot lines is one candidate; the party is the
    best-known party among those lines; and named write-ins with a handful of
    votes are pooled into an "Other" candidate per district.
    """
    votes: dict[tuple, dict[str, int]] = collections.defaultdict(dict)
    display: dict[tuple[str, str], str] = {}
    info: dict[str, tuple[str, str, str | None]] = {}
    party_votes: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    overrides = overrides or {}
    president = medsl_office == "US PRESIDENT"
    for row in rows:
        if medsl_office_name(row["office"]) != MEDSL_OFFICE[medsl_office] or (row.get("special") == "TRUE") != special:
            continue
        name = row["candidate"].strip().upper()
        if imp.MEDSL_ACCOUNTING.search(name) or (not president and MEDSL_EXTRA_ACCOUNTING.search(name)):
            continue
        try:
            count = int(float(row["votes"]))
        except (TypeError, ValueError):
            continue
        district = None
        if medsl_office == "US HOUSE":
            raw = row["district"].strip().upper()
            district = "At-large" if raw in {"AT-LARGE", "AL", "STATEWIDE", ""} else (imp.normalize_district(raw) or raw)
        if president:
            if row["writein"] == "TRUE":
                ckey = "WRI"
            else:
                ckey = imp.MEDSL_CANDIDATES.get(name) or "OTH"
            cname, cparty = imp.CANDIDATES.get(ckey, (ckey, "OTH"))
            info.setdefault(ckey, (cname, cparty, None))
        else:
            party = medsl_party_code(row["party_detailed"], row["party_simplified"])
            if row["writein"] == "TRUE" or name in {"WRITE-IN", "WRITE-INS", "WRITEIN", "WRITE IN"} or party == "WRI":
                ckey = f"{district or ''}-WRI"
                info.setdefault(ckey, ("Write-in", "WRI", district))
            else:
                ckey = f"{district or ''}-{re.sub(r'[^A-Z0-9]', '', name)}"
                info.setdefault(ckey, (title_case(name), party, district))
                party_votes[ckey][party] += count
        fips = str(row["county_fips"]).zfill(5)
        raw_precinct = str(row["precinct"])
        pkey = (fips, imp.precinct_key(raw_precinct))
        display.setdefault(pkey, raw_precinct)
        if len(raw_precinct) < len(display[pkey]):
            display[pkey] = raw_precinct
        slot = votes[(fips, pkey[1], ckey)]
        slot[row["mode"]] = slot.get(row["mode"], 0) + count
    tally: dict[tuple[str, str], dict[str, int]] = collections.defaultdict(dict)
    totals: collections.Counter = collections.Counter()
    for (fips, precinct, ckey), modes in votes.items():
        total = modes["TOTAL"] if "TOTAL" in modes else sum(modes.values())
        if total:
            slot = tally[(fips, precinct)]
            slot[ckey] = slot.get(ckey, 0) + total
            totals[ckey] += total
    if president:
        return tally, display, info

    # Settle each candidate's party: the best-known party among their lines.
    for ckey, counter in party_votes.items():
        known = [(v, c) for c, v in counter.items() if c in KNOWN_PARTIES]
        chosen = max(known)[1] if known else counter.most_common(1)[0][0]
        chosen = overrides.get(ckey, chosen)
        info[ckey] = (info[ckey][0], chosen, info[ckey][2])

    # Pool named write-ins with a handful of votes into "Other".
    grand = sum(totals.values())
    pooled: dict[str, str] = {}
    for ckey, total in totals.items():
        name, party, district = info[ckey]
        if party in ("DEM", "REP") or ckey.endswith("-WRI") or total >= 100 or total >= 0.0005 * grand:
            continue
        other = f"{district or ''}-OTH"
        info.setdefault(other, ("Other", "OTH", district))
        pooled[ckey] = other
    if pooled:
        for slot in tally.values():
            for ckey in [k for k in slot if k in pooled]:
                slot[pooled[ckey]] = slot.get(pooled[ckey], 0) + slot.pop(ckey)
        for ckey in pooled:
            info.pop(ckey, None)
    return tally, display, info


# --------------------------------------------------------------------------- old db


def old_precincts(db: sqlite3.Connection) -> list[tuple[int, str]]:
    return db.execute("SELECT id, name FROM precincts ORDER BY id").fetchall()


def old_president_votes(db: sqlite3.Connection) -> dict[int, dict[str, int]]:
    """{precinct id: {candidate code: votes}} from the existing database."""
    by_uuid = {imp.candidate_uuid(code): code for code in imp.CANDIDATES}
    out: dict[int, dict[str, int]] = collections.defaultdict(dict)
    for pid, cid, votes in db.execute("SELECT precinct_id, candidate_id, votes FROM precinct_results"):
        out[pid][by_uuid.get(cid, cid)] = votes
    return out


def align_vest_rows(raw_names: list[str], db_rows: list[tuple[int, str]]) -> list[int | None]:
    """Map raw layer rows onto db precinct ids; rows the import dropped get None."""
    ids: list[int | None] = [None] * len(raw_names)
    j = 0
    for i, name in enumerate(raw_names):
        if j < len(db_rows) and db_rows[j][1] == name:
            ids[i] = db_rows[j][0]
            j += 1
    if j != len(db_rows):
        raise ValueError(f"could not align precincts: matched {j} of {len(db_rows)} db rows "
                         f"against {len(raw_names)} layer rows")
    return ids


def read_vest_attributes(archive: Path) -> pd.DataFrame:
    with zipfile.ZipFile(archive) as bundle:
        members = [n for n in bundle.namelist() if Path(n).suffix.lower() in {".shp", ".geojson", ".json"}]
    ranked = sorted(members, key=lambda n: (
        "_all_" not in Path(n).stem.lower() and "all_prec" not in Path(n).stem.lower(),
        "cong" in Path(n).stem.lower(), "sld" in Path(n).stem.lower(), len(Path(n).parts), n))
    if not ranked:
        raise ValueError("archive contains no Shapefile or GeoJSON")
    path = f"/vsizip/{archive}/{ranked[0]}"
    frame = gpd.read_file(path, engine="pyogrio", read_geometry=False)
    return pd.DataFrame(frame)


# --------------------------------------------------------------------------- output


NEW_SCHEMA = """
CREATE TABLE elections (
    id INTEGER PRIMARY KEY,
    office TEXT NOT NULL CHECK(office IN ('President','US Senate','US House','Governor')),
    name TEXT NOT NULL,
    year INTEGER NOT NULL,
    special INTEGER NOT NULL DEFAULT 0,
    source TEXT,
    total_votes INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE parties (
    id TEXT PRIMARY KEY,
    election_id INTEGER NOT NULL REFERENCES elections(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    color INTEGER NOT NULL,
    UNIQUE(election_id, code)
);
CREATE TABLE candidates (
    id TEXT PRIMARY KEY,
    election_id INTEGER NOT NULL REFERENCES elections(id) ON DELETE CASCADE,
    party_id TEXT REFERENCES parties(id) ON DELETE SET NULL,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    district TEXT,
    congressional_district_id INTEGER REFERENCES congressional_districts(id) ON DELETE SET NULL,
    votes INTEGER NOT NULL DEFAULT 0,
    UNIQUE(election_id, code)
);
CREATE TABLE precinct_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    precinct_id INTEGER NOT NULL REFERENCES precincts(id) ON DELETE CASCADE,
    election_id INTEGER NOT NULL REFERENCES elections(id) ON DELETE CASCADE,
    candidate_id TEXT NOT NULL REFERENCES candidates(id) ON DELETE CASCADE,
    votes INTEGER NOT NULL DEFAULT 0,
    UNIQUE(precinct_id, candidate_id)
);
CREATE INDEX idx_precinct_results_precinct ON precinct_results(precinct_id);
CREATE INDEX idx_precinct_results_election ON precinct_results(election_id);
CREATE INDEX idx_precinct_results_candidate ON precinct_results(candidate_id);
CREATE INDEX idx_candidates_election ON candidates(election_id);
CREATE INDEX idx_parties_election ON parties(election_id);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
"""


# Set by --stamp: state databases are then written as <CODE>-<YEAR>-<stamp>.db.
# A rebuilt state gets a new file name, so the CDN serves it immediately
# instead of a cached copy of the old one; older local copies of that state
# are removed and the manifest points at the newest.
STAMP: str | None = None
STATE_DB = re.compile(rf"^([A-Z]{{2}})-{YEAR}(?:-(\d+))?\.db$")


def latest_state_dbs() -> dict[str, Path]:
    """{state code: newest database file in OUT_DIR}."""
    newest: dict[str, tuple[str, Path]] = {}
    for path in OUT_DIR.glob(f"*-{YEAR}*.db"):
        match = STATE_DB.match(path.name)
        if not match:
            continue
        stamp = match.group(2) or ""
        if match.group(1) not in newest or stamp > newest[match.group(1)][0]:
            newest[match.group(1)] = (stamp, path)
    return {code: path for code, (_, path) in newest.items()}


def write_state_db(code: str, state_name: str, contests: list[Contest], source: str) -> dict:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    target = OUT_DIR / (f"{code}-{YEAR}-{STAMP}.db" if STAMP else f"{code}-{YEAR}.db")
    temp = target.with_suffix(".db.tmp")
    temp.unlink(missing_ok=True)
    shutil.copyfile(OLD_DIR / f"{code}.db", temp)
    db = sqlite3.connect(temp)
    db.execute("PRAGMA foreign_keys=OFF")
    db.executescript("""
        DROP TABLE IF EXISTS precinct_results;
        DROP INDEX IF EXISTS idx_precinct_results_precinct;
    """)
    db.executescript(NEW_SCHEMA)
    district_ids = {name: did for did, name in db.execute("SELECT id, name FROM congressional_districts")}

    order = {"President": 0, "US Senate": 1, "US House": 2, "Governor": 3}
    contests = sorted(contests, key=lambda c: (order[c.office], c.special))
    summary = []
    for election_id, contest in enumerate(contests, 1):
        label = f"{YEAR} {state_name} {contest.office}" + (" (Special)" if contest.special else "")
        db.execute("INSERT INTO elections(id, office, name, year, special, source, total_votes) VALUES (?,?,?,?,?,?,?)",
                   (election_id, contest.office, label, YEAR, int(contest.special), source, contest.total()))
        parties: dict[str, str] = {}
        for cand in contest.candidates.values():
            if cand.party not in parties:
                pid = party_uuid(code, contest.slug, cand.party)
                name, color = PARTY_INFO.get(cand.party, (cand.party, 0xFF616161))
                db.execute("INSERT INTO parties(id, election_id, code, name, color) VALUES (?,?,?,?,?)",
                           (pid, election_id, cand.party, name, color))
                parties[cand.party] = pid
        ids: dict[str, str] = {}
        for cand in sorted(contest.candidates.values(), key=lambda c: (-c.votes, c.code)):
            if cand.votes == 0:
                continue
            cid = candidate_uuid(code, contest.slug, cand.code)
            ids[cand.code] = cid
            cd_id = district_ids.get(f"District {cand.district}") if cand.district else None
            db.execute("INSERT INTO candidates(id, election_id, party_id, code, name, district, congressional_district_id, votes) VALUES (?,?,?,?,?,?,?,?)",
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
    meta = {"state_code": code, "state_name": state_name, "year": str(YEAR), "source": source,
            "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "schema": "2", "geometry_from": f"data/output/2024-National-President/{code}.db"}
    db.executemany("INSERT INTO meta(key, value) VALUES (?,?)", list(meta.items()))
    db.commit()
    db.execute("VACUUM")
    db.close()
    shutil.move(temp, target)
    for old in OUT_DIR.glob(f"{code}-{YEAR}*.db"):
        if old != target and STATE_DB.match(old.name):
            old.unlink()
    return {"code": code, "name": state_name, "db": target.name, "source": source,
            "size": target.stat().st_size, "sha256": sha256(target), "elections": summary}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_national(reports: list[dict]) -> None:
    source = OLD_DIR / "National.db"
    if not source.exists():
        print("  ! no National.db to copy", flush=True)
        return
    target = OUT_DIR / f"National-{YEAR}.db"
    shutil.copyfile(source, target)
    db = sqlite3.connect(target)
    db.executescript("""
        DROP TABLE IF EXISTS state_elections;
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
    by_name = {name: sid for sid, name in db.execute("SELECT id, name FROM states")}
    for report in reports:
        sid = by_name.get(report["name"])
        if sid is None:
            continue
        db.execute("UPDATE states SET db_name=? WHERE id=?", (report["db"], sid))
        president = next((e for e in report["elections"] if e["office"] == "President"), None)
        state_db = sqlite3.connect(OUT_DIR / report["db"])
        for election in report["elections"]:
            rows = state_db.execute(
                "SELECT c.id, c.code, c.name, p.code, c.votes FROM candidates c JOIN parties p ON p.id=c.party_id "
                "WHERE c.election_id=? ORDER BY c.votes DESC", (election["id"],)).fetchall()
            summary = [{"candidate_id": r[0], "code": r[1], "name": r[2], "party": r[3], "votes": r[4]} for r in rows]
            db.execute("INSERT INTO state_elections(state_id, election_id, office, special, name, total_votes, summary) VALUES (?,?,?,?,?,?,?)",
                       (sid, election["id"], election["office"], int(election["special"]), election["name"],
                        election["total_votes"], json.dumps(summary, separators=(",", ":"))))
            if election is president:
                db.execute("UPDATE states SET vote_summary=? WHERE id=?",
                           (json.dumps(summary, separators=(",", ":")), sid))
        state_db.close()
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"wrote {target.relative_to(ROOT)}", flush=True)


def write_manifest(reports: list[dict]) -> None:
    national = OUT_DIR / f"National-{YEAR}.db"
    payload = {
        "year": YEAR,
        "schema": 2,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "cdn_base": f"{CDN_BASE}/{YEAR}",
        "national": {"db": national.name, "url": f"{CDN_BASE}/{YEAR}/{national.name}",
                     "size": national.stat().st_size if national.exists() else None,
                     "sha256": sha256(national) if national.exists() else None},
        "states": [{
            "code": r["code"], "name": r["name"], "db": r["db"], "url": f"{CDN_BASE}/{YEAR}/{r['db']}",
            "size": r["size"], "sha256": r["sha256"], "source": r["source"],
            "elections": [{k: e[k] for k in ("id", "office", "special", "name", "total_votes", "candidates", "parties")}
                          for e in r["elections"]],
        } for r in sorted(reports, key=lambda r: r["code"])],
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")

    lines = [f"# {YEAR} state databases — build report", "",
             f"Generated {payload['generated_at']} by build_2024_state_dbs.py.", "",
             "| State | Source | President | US Senate | US House | Governor | Size |", "|---|---|---|---|---|---|---|"]
    for r in sorted(reports, key=lambda r: r["code"]):
        cells = {}
        for e in r["elections"]:
            key = e["office"] + (" (special)" if e["special"] else "")
            cells.setdefault(e["office"], []).append(f"{e['total_votes']:,}" + (" (special)" if e["special"] else ""))
        row = [r["code"], r["source"]] + [" / ".join(cells.get(o, ["—"])) for o in OFFICES] + [f"{r['size'] / 1048576:.1f} MB"]
        lines.append("| " + " | ".join(row) + " |")
    lines += ["", "## Per-state detail", ""]
    for r in sorted(reports, key=lambda r: r["code"]):
        lines.append(f"### {r['code']} — {r['name']} ({r['source']})")
        for e in r["elections"]:
            lines.append(f"- **{e['name']}** — {e['total_votes']:,} votes, {e['candidates']} candidates, "
                         f"parties: {', '.join(p['code'] for p in e['parties'])}")
            for leader in e["leaders"]:
                district = f" (District {leader['district']})" if leader["district"] else ""
                lines.append(f"    - {leader['name']} [{leader['party']}]{district}: {leader['votes']:,}")
            for note in e["notes"]:
                if not note.startswith(("G", "S", "U")) or "via readme" in note or "via code" in note or "not placed" in note:
                    lines.append(f"    - note: {note}")
        lines.append("")
    (OUT_DIR / "BUILD_REPORT.md").write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT_DIR / 'manifest.json'} and BUILD_REPORT.md", flush=True)


def write_new_elections(reports: list[dict]) -> None:
    """new_data/new_elections.json: {"2024": [{"stateName", "db"}, ...]}.

    Other years already in the file are kept.  Only the state databases are
    listed; National-<year>.db is referenced from manifest.json instead.
    """
    payload = {}
    if NEW_ELECTIONS.exists():
        try:
            payload = json.loads(NEW_ELECTIONS.read_text())
        except json.JSONDecodeError:
            payload = {}
    entries = [{"stateName": r["name"], "db": f"{CDN_BASE}/{YEAR}/{r['db']}"}
               for r in sorted(reports, key=lambda r: r["name"])]
    payload[str(YEAR)] = entries
    NEW_ELECTIONS.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {NEW_ELECTIONS.relative_to(ROOT)} ({len(entries)} entries for {YEAR})", flush=True)


# --------------------------------------------------------------------------- drivers


def build_vest_state(archive: Path, index: dict) -> dict:
    code = archive.name[:2].upper()
    state_name = imp.STATE_NAMES[code.lower()]
    old = sqlite3.connect(OLD_DIR / f"{code}.db")
    db_rows = old_precincts(old)
    frame = read_vest_attributes(archive)
    precinct_field = imp.first_column(frame, ["UNIQUE_ID", "GEOID", "VTD", "VTDST", "PRECINCT", "PRECINCTNA",
                                              "PRECINCT_NA", "WARDID", "LABEL"])
    raw_names = ([imp.as_text(v, f"Precinct_{i + 1}") for i, v in enumerate(frame[precinct_field])]
                 if precinct_field else [f"Precinct_{i + 1}" for i in range(len(frame))])
    precinct_ids = align_vest_rows(raw_names, db_rows)
    dropped = sum(1 for p in precinct_ids if p is None)
    contests = vest_contests(frame, code, archive, index, precinct_ids)

    # The President contest must reproduce the existing database exactly.
    president = next(c for c in contests if c.office == "President")
    expected = old_president_votes(old)
    old.close()
    mismatched = 0
    for pid, _ in db_rows:
        have = {k: v for k, v in president.results.get(pid, {}).items() if v}
        want = {k: v for k, v in expected.get(pid, {}).items() if v}
        if have != want:
            mismatched += 1
            if mismatched <= 3:
                print(f"  ! {code} precinct {pid}: rebuilt {have} != stored {want}", flush=True)
    if mismatched:
        raise ValueError(f"{code}: President votes differ from the existing database in {mismatched} precincts")
    print(f"[{code}] {len(db_rows):,} precincts aligned ({dropped} layer rows dropped by the original import); "
          + ", ".join(f"{c.office}{' special' if c.special else ''}={c.total():,}" for c in contests), flush=True)
    for contest in contests:
        for note in contest.notes:
            if "via readme" in note or "via code" in note:
                print(f"    {note}", flush=True)
    return write_state_db(code, state_name, contests, "VEST")


def build_medsl_state(code: str) -> dict:
    state_name = imp.STATE_NAMES[code.lower()]
    rows = imp.medsl_rows(code)
    old = sqlite3.connect(OLD_DIR / f"{code}.db")
    db_rows = old_precincts(old)
    expected = old_president_votes(old)
    old.close()

    # Rebuild the President tally the way import_medsl_state did, to recover
    # the (fips, precinct key) -> precinct id order.
    tally, display, _ = medsl_tally(rows, "US PRESIDENT", False)
    for key in imp.drop_county_totals(tally, display, code):
        del tally[key]
    keys = sorted(tally)
    if len(keys) != len(db_rows):
        raise ValueError(f"{code}: rebuilt {len(keys)} precincts but the database has {len(db_rows)}")
    precinct_index: dict[tuple[str, str], int] = {}
    mismatched = 0
    for key, (pid, name) in zip(keys, db_rows):
        precinct_index[key] = pid
        if display.get(key, key[1]) != name or {k: v for k, v in tally[key].items() if v} != {k: v for k, v in expected.get(pid, {}).items() if v}:
            mismatched += 1
            if mismatched <= 3:
                print(f"  ! {code} precinct {pid} {name!r}: rebuilt {display.get(key)!r} {tally[key]} != stored {expected.get(pid)}", flush=True)
    if mismatched:
        raise ValueError(f"{code}: President tally differs from the existing database in {mismatched} precincts")
    contests = medsl_contests(rows, code, precinct_index)
    print(f"[{code}] {len(db_rows):,} precincts matched; "
          + ", ".join(f"{c.office}{' special' if c.special else ''}={c.total():,}" for c in contests), flush=True)
    for contest in contests:
        for note in contest.notes:
            print(f"    {note}", flush=True)
    return write_state_db(code, state_name, contests, "MEDSL")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--states", nargs="*", help="two-letter codes (default: every state with an existing db)")
    parser.add_argument("--skip-national", action="store_true")
    parser.add_argument("--manifest-only", action="store_true",
                        help="only rewrite manifest.json, BUILD_REPORT.md and new_elections.json from the existing dbs")
    parser.add_argument("--stamp", nargs="?", const=datetime.now().strftime("%Y%m%d%H%M"),
                        help="write <CODE>-2024-<stamp>.db (default stamp: now, YYYYMMDDHHMM) so the CDN "
                             "need not be purged; older copies of the rebuilt states are removed locally")
    args = parser.parse_args()
    global STAMP
    STAMP = args.stamp
    wanted = {s.upper() for s in args.states or []}
    if args.manifest_only:
        reports = [report_from_db(p) for _, p in sorted(latest_state_dbs().items())]
        write_manifest(reports)
        write_new_elections(reports)
        return

    index = load_medsl_name_index()
    archives = {p.name[:2].upper(): p for p in sorted(INPUT_DIR.glob("*_2024_gen_*.zip")) if " (" not in p.name}
    existing = sorted(p.stem for p in OLD_DIR.glob("*.db") if p.stem != "National")
    reports, failures = [], []
    for code in existing:
        if wanted and code not in wanted:
            continue
        try:
            if code in archives:
                reports.append(build_vest_state(archives[code], index))
            elif (imp.MEDSL_DIR / f"{code.lower()}24.zip").exists():
                reports.append(build_medsl_state(code))
            else:
                raise ValueError("no VEST archive and no MEDSL file")
        except Exception as error:  # keep going; report at the end
            failures.append((code, str(error)))
            print(f"FAILED {code}: {error}", flush=True)
    # Reports for states built in an earlier run, so the manifest stays complete.
    built = {r["code"] for r in reports}
    for code, path in sorted(latest_state_dbs().items()):
        if code not in built:
            reports.append(report_from_db(path))
    if reports and not args.skip_national:
        write_national(reports)
    if reports:
        write_manifest(reports)
        write_new_elections(reports)
    if failures:
        print("\nFailures:")
        for code, error in failures:
            print(f"- {code}: {error}")
        sys.exit(1)


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
            "size": path.stat().st_size, "sha256": sha256(path), "elections": elections}


if __name__ == "__main__":
    main()
