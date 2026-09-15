#!/usr/bin/env python3
"""Measure how well MEDSL US House precinct rows match a VEST layer, per state.

    .venv/bin/python diag_medsl_match.py --year 2018 [--states NH VT]

Reads the layer attributes only (no geometry), so a state whose county can
only be found geometrically is matched against a statewide index.  Prints one
line per state: share of House votes matched, and unmatched samples.
"""
from __future__ import annotations

import argparse
import collections
import re
import sys

import geopandas as gpd
import pandas as pd

import build_year_state_dbs as b


def county_from_fields(frame: pd.DataFrame, counties) -> list[str]:
    by_fips, by_name = b.county_names(counties)
    for field in b.i20.COUNTY_FIPS_FIELDS + b.i20.COUNTY_NAME_FIELDS:
        column = b.i20.first_column(frame, [field])
        if column is None:
            continue
        for reader in (lambda v: by_fips.get(re.sub(r"\D", "", str(v))[-3:].zfill(3)) if re.sub(r"\D", "", str(v)) else None,
                       lambda v: by_name.get(b.i20.name_key(v)) if b.i20.name_key(v) else None):
            names = [reader(v) for v in frame[column]]
            if sum(1 for n in names if n) >= len(frame) * 0.9:
                return [n or "?" for n in names]
    return ["?"] * len(frame)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--states", nargs="*")
    args = parser.parse_args()
    year = args.year
    wanted = {s.upper() for s in args.states or []}
    archives = b.vest_archives(year)
    legend = b.read_legend(year)
    for code, archive in archives.items():
        if wanted and code not in wanted:
            continue
        if code in b.at_large_states(year):
            continue
        try:
            frame = b.b24.read_vest_attributes(archive)
            counties = b.state_counties(year, code)
            county_of = county_from_fields(frame, counties)
            rows = b.medsl_rows_2016(code) if year == 2016 else b.medsl_rows_2018(code)
            precinct_ids = list(range(1, len(frame) + 1))
            contests = b.vest_contests(frame, code, year, precinct_ids, legend.get(code, {}))
            have = {cand.district for c in contests if c.office == "US House" for cand in c.candidates.values()}
            log: list[str] = []
            contest = b.supplement_house(rows, frame, precinct_ids, county_of, counties, code, year, have, log)
            total = sum(int(float(r["votes"])) for r in rows if r["votes"] not in ("", None) and not b.MEDSL_JUNK.search(r["candidate"]))
            placed = contest.total() if contest else 0
            sample = collections.Counter(r["precinct"] for r in rows).most_common(3)
            fields = [c for c in frame.columns if not re.match(r"^[GSRPC]\d\d", str(c).upper()) and c != "geometry"][:8]
            print(f"{code}: VEST House districts={sorted(have, key=lambda d: (len(d), d))} MEDSL rows={len(rows):,} "
                  f"votes={total:,} placed={placed:,} ({(placed / total if total else 0):.1%}) county={'fields' if county_of[0] != '?' else 'none'}",
                  flush=True)
            print(f"    layer fields: {fields}; sample: {frame[fields].iloc[0].tolist()}", flush=True)
            print(f"    medsl precincts: {sample}", flush=True)
            for line in log:
                print(f"    {line}", flush=True)
        except Exception as error:
            print(f"{code}: ERROR {error}", flush=True)


if __name__ == "__main__":
    main()
