#!/usr/bin/env python3
"""Compare each state's US House total in new_data/<year> with the MEDSL file's own total.

    .venv/bin/python diag_house_totals.py 2016 2018

A MEDSL precinct that reports a TOTAL mode is counted once; otherwise its
modes are summed.  States below 98% are listed as RERUN candidates.
"""
import collections
import sqlite3
import sys
from pathlib import Path

import build_year_state_dbs as b


def medsl_total(rows: list[dict]) -> int:
    per: dict[tuple, dict[str, int]] = collections.defaultdict(dict)
    for r in rows:
        n = r["candidate"].strip()
        if not n or b.MEDSL_JUNK.search(n):
            continue
        try:
            v = int(float(r["votes"]))
        except (TypeError, ValueError):
            continue
        if v <= 0:
            continue
        slot = per[(r["county_fips"], r["precinct"], r["district"], n)]
        slot[r["mode"]] = slot.get(r["mode"], 0) + v
    return sum(m["TOTAL"] if "TOTAL" in m else sum(m.values()) for m in per.values())


def main() -> None:
    for year in [int(y) for y in sys.argv[1:]]:
        reader = b.medsl_rows_2016 if year == 2016 else b.medsl_rows_2018
        rerun = []
        for path in sorted(Path(f"new_data/{year}").glob(f"[A-Z][A-Z]-{year}.db")):
            code = path.name[:2]
            if code in b.at_large_states(year):
                continue
            expected = medsl_total(reader(code))
            db = sqlite3.connect(path)
            row = db.execute("select total_votes from elections where office='US House' and special=0").fetchone()
            house = row[0] if row else 0
            level = dict(db.execute("select key, value from meta")).get("level")
            db.close()
            flag = "" if expected and house >= 0.98 * expected else "  <-- RERUN"
            if flag:
                rerun.append(code)
            print(f"{year} {code} ({level}): medsl={expected:,} db={house:,}{flag}", flush=True)
        print(f"{year} RERUN: {' '.join(rerun)}")


if __name__ == "__main__":
    main()
