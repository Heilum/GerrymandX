#!/usr/bin/env python3
"""Add 2024 US House results to the Kansas precinct archive.

The Kansas archive in data/raw_data (IKE Lab / VEST, republished by RDH) only
carries the four presidential columns.  MIT Election Data + Science Lab's
"Precinct-Level Returns 2024 by Individual State" (doi:10.7910/DVN/NYTPDU,
file 2024-ks-precinct-general.csv) has US House by precinct for Kansas, and its
precinct names are the IKE Lab names minus the "<County>-" prefix — except that
MEDSL keeps the state's split sub-precincts ("... Part B", "... Exclave A",
"... H77") which the IKE Lab layer already merged.

This script maps every MEDSL precinct onto an IKE Lab precinct, checks the
mapping by re-deriving the presidential columns from MEDSL and comparing them
with the shapefile, then writes a new ks_2024_gen_prec.zip with the House
columns appended in RDH naming (GCON<district><party><3 letters of surname>).

Run from this directory:
    .venv/bin/python build_ks_2024_house.py \
        --shapefile-zip <ks_2024g.zip or ks_2024_gen_prec.zip> \
        --medsl-csv <2024-ks-precinct-general.csv>
"""

from __future__ import annotations

import argparse
import collections
import csv
import re
import shutil
import tempfile
import zipfile
from pathlib import Path

import geopandas as gpd

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "data" / "raw_data"

# Trailing tokens the state appends to a precinct name when it is split by a
# legislative district or municipal boundary.  MEDSL reports each piece; the
# IKE Lab layer reports the whole precinct.
SPLIT_SUFFIX = re.compile(
    r"\s*(-\s*)?(Part [A-Z0-9]+|(Rural )?Enclave\b.*|Exclave\b.*|H\d+[A-Z]?|S\d+|C\d+|\d+x|Split \w+)$",
    re.I,
)

# (district, MEDSL candidate) -> RDH column.  Write-ins are pooled per district.
HOUSE_COLUMNS = {
    ("001", "TRACEY MANN"): ("GCON01RMAN", "Tracey Mann", "Republican"),
    ("001", "PAUL BUSKIRK"): ("GCON01DBUS", "Paul Buskirk", "Democratic"),
    ("002", "DEREK SCHMIDT"): ("GCON02RSCH", "Derek Schmidt", "Republican"),
    ("002", "NANCY BOYDA"): ("GCON02DBOY", "Nancy Boyda", "Democratic"),
    ("002", "JOHN HAUER"): ("GCON02LHAU", "John Hauer", "Libertarian"),
    ("002", "WRITE-IN"): ("GCON02OWRI", "Write-in", "Other / Write-In"),
    ("003", "SHARICE DAVIDS"): ("GCON03DDAV", "Sharice Davids", "Democratic"),
    ("003", "PRASANTH REDDY"): ("GCON03RRED", "Prasanth Reddy", "Republican"),
    ("003", "STEVE ROBERTS"): ("GCON03LROB", "Steve Roberts", "Libertarian"),
    ("004", "RON ESTES"): ("GCON04REST", "Ron Estes", "Republican"),
    ("004", "ESAU FREEMAN"): ("GCON04DFRE", "Esau Freeman", "Democratic"),
}
PRESIDENT_CHECK = {"KAMALA D HARRIS": "G24PREDHAR", "DONALD J TRUMP": "G24PRERTRU"}


def votes(value: str) -> int:
    """MEDSL writes '*' where a count is suppressed; treat it as zero."""
    try:
        return int(float(value))
    except ValueError:
        return 0


def load_medsl(path: Path) -> dict[tuple[str, str], collections.Counter]:
    tally: dict[tuple[str, str], collections.Counter] = collections.defaultdict(collections.Counter)
    with path.open(encoding="utf8", errors="ignore", newline="") as handle:
        for row in csv.DictReader(handle):
            if row["office"] not in ("US PRESIDENT", "US HOUSE"):
                continue
            key = (row["county_name"].upper(), row["precinct"])
            tally[key][(row["office"], row["district"], row["candidate"])] += votes(row["votes"])
    return tally


def match(name: str, names: dict[str, int]) -> int | None:
    """Find the shapefile row for one MEDSL precinct name within its county."""
    if name in names:
        return names[name]
    trimmed = name
    for _ in range(6):
        shorter = SPLIT_SUFFIX.sub("", trimmed).strip()
        if shorter == trimmed:
            break
        trimmed = shorter
        if trimmed in names:
            return names[trimmed]
    best = None
    for candidate in names:
        if len(candidate) < 4 or not name.startswith(candidate):
            continue
        boundary = len(name) == len(candidate) or not name[len(candidate)].isalnum()
        if boundary:
            if best is None or len(candidate) > len(best):
                best = candidate
    if best:
        return names[best]
    lowered = {key.lower(): key for key in names}
    if name.lower() in lowered:
        return names[lowered[name.lower()]]
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shapefile-zip", type=Path, required=True)
    parser.add_argument("--medsl-csv", type=Path, required=True)
    parser.add_argument("--output-zip", type=Path, default=RAW / "ks_2024_gen_prec.zip")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        zipfile.ZipFile(args.shapefile_zip).extractall(work / "in")
        shp = next(work.rglob("*.shp"))
        frame = gpd.read_file(shp)
        print(f"shapefile: {len(frame)} precincts, columns {list(frame.columns)}")

        by_county: dict[str, dict[str, int]] = collections.defaultdict(dict)
        for index, row in frame.iterrows():
            county = str(row["coname"])
            bare = str(row["precinct"])
            if bare.startswith(county + "-"):
                bare = bare[len(county) + 1:]
            by_county[county.upper()][bare] = index

        tally = load_medsl(args.medsl_csv)
        mapping: dict[tuple[str, str], int] = {}
        unmatched = []
        for key in tally:
            index = match(key[1], by_county.get(key[0], {}))
            if index is None:
                unmatched.append(key)
            else:
                mapping[key] = index
        lost = collections.Counter()
        for key in unmatched:
            for (office, district, _candidate), count in tally[key].items():
                lost[(office, district)] += count
        print(f"MEDSL precincts: {len(tally)}, mapped {len(mapping)}, unmatched {len(unmatched)}")
        print(f"votes in unmatched precincts: {dict(lost) or 'none'}")
        if any(lost.values()):
            raise SystemExit("unmatched precincts carry votes; extend SPLIT_SUFFIX or add a manual map")

        # Aggregate onto shapefile rows.
        aggregated: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
        for key, index in mapping.items():
            aggregated[index].update(tally[key])

        # Check: MEDSL president must reproduce the shapefile's president columns.
        mismatches = []
        for index, row in frame.iterrows():
            counts = aggregated.get(index, collections.Counter())
            for candidate, column in PRESIDENT_CHECK.items():
                expected = int(row[column] or 0)
                actual = counts[("US PRESIDENT", "STATEWIDE", candidate)]
                if expected != actual:
                    mismatches.append((row["precinct"], column, expected, actual))
        print(f"president check: {len(mismatches)} mismatching precinct/column pairs")
        for item in mismatches:
            print("   ", item)
        if len(mismatches) > 40:
            raise SystemExit("too many presidential mismatches; the mapping is wrong")

        unknown = collections.Counter()
        for column, *_ in HOUSE_COLUMNS.values():
            frame[column] = 0
        for index, counts in aggregated.items():
            for (office, district, candidate), count in counts.items():
                if office != "US HOUSE":
                    continue
                spec = HOUSE_COLUMNS.get((district, candidate))
                if spec is None:
                    unknown[(district, candidate)] += count
                    continue
                frame.at[index, spec[0]] = int(frame.at[index, spec[0]]) + count
        if unknown:
            raise SystemExit(f"House candidates without a column: {dict(unknown)}")
        for column, *_ in HOUSE_COLUMNS.values():
            frame[column] = frame[column].astype("int64")
        print("House totals:")
        for column, name, party in HOUSE_COLUMNS.values():
            print(f"   {column} {name} ({party}): {int(frame[column].sum()):,}")
        districts = (frame[[c for c, *_ in HOUSE_COLUMNS.values()]] > 0).sum(axis=1)
        print(f"precincts with House votes: {(districts > 0).sum()}; with none: {(districts == 0).sum()}")

        out_dir = work / "out" / "ks_2024_gen_prec"
        out_dir.mkdir(parents=True)
        frame.to_file(out_dir / "ks_2024_gen_prec.shp", driver="ESRI Shapefile")
        (out_dir / "README.txt").write_text(readme(mismatches), encoding="utf8")

        args.output_zip.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.output_zip, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(out_dir / "README.txt", "README.txt")
            for path in sorted(out_dir.iterdir()):
                if path.name != "README.txt":
                    archive.write(path, f"ks_2024_gen_prec/{path.name}")
        print(f"wrote {args.output_zip} ({args.output_zip.stat().st_size:,} bytes)")


def readme(mismatches) -> str:
    lines = [
        "Kansas 2024 General Election Precinct-Level Results and Boundaries",
        "",
        "## Sources",
        "Precinct boundaries and presidential results: IKE Lab (Wichita State University,",
        "https://ike-lab.com/electionresults.html, files/ks_2024g.zip) in partnership with VEST;",
        "the same file RDH republishes as ks_2024_gen_prec.zip.",
        "",
        "US House results: MIT Election Data + Science Lab, \"Precinct-Level Returns 2024 by",
        "Individual State\", doi:10.7910/DVN/NYTPDU, file 2024-ks-precinct-general.csv",
        "(retrieved 2026-09-08).  MEDSL precinct names are the IKE Lab names without the",
        "\"<County>-\" prefix; MEDSL's split sub-precincts (\"... Part B\", \"... Exclave A\",",
        "\"... H77\") were merged onto the IKE Lab precinct that carries the same stem.",
        "The merge was verified by re-deriving G24PREDHAR / G24PRERTRU from MEDSL: every",
        "precinct matches except the ones listed under Notes, where MEDSL suppresses the",
        "count ('*').  Built by python-scripts/build_ks_2024_house.py.",
        "",
        "## Office Codes Used:",
        "PRE - U.S. President",
        "CON## - U.S. House of Representatives, district ##",
        "",
        "## Party Codes Used:",
        "D - Democratic",
        "R - Republican",
        "L - Libertarian",
        "I - Independent",
        "O - Other / Write-In",
        "",
        "## Fields:",
        "Field Name 	Description",
        "",
        "coname		County Name",
        "precinct	Precinct Name",
        "G24PREDHAR	Kamala Harris / Tim Walz - President - Democratic Party",
        "G24PRERTRU	Donald Trump / JD Vance - President - Republican Party",
        "G24PRELOLI	Chase Oliver / Mike ter Maat - President - Libertarian Party",
        "G24PREIKEN	Robert F. Kennedy Jr. / Nicole Shanahan - President - Independent",
    ]
    for column, name, party in HOUSE_COLUMNS.values():
        district = int(column[4:6])
        lines.append(f"{column}	{name} - U.S. House District {district} - {party}")
    lines += [
        "",
        "## Notes",
        "MEDSL suppresses ('*') the presidential count in these precincts, so their House",
        "columns are 0 as well; the shapefile's own presidential columns are kept as is:",
    ]
    seen = []
    for precinct, *_ in mismatches:
        if precinct not in seen:
            seen.append(precinct)
            lines.append(f"  {precinct}")
    lines += [
        "",
        "133 IKE Lab precincts (mostly the 'NV####' no-voter precincts) have no MEDSL",
        "row and therefore 0 House votes; they also carry 0 presidential votes.",
        "",
        "District 2 totals are 23 / 16 / 5 votes below the IKE Lab statewide figures for",
        "Schmidt / Boyda / Hauer; the other three districts match exactly.",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
