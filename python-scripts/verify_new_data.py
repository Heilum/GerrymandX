#!/usr/bin/env python3
"""Consistency check over new_data/: every year folder, manifest, National db and new_elections.json.

    .venv/bin/python verify_new_data.py
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NEW = ROOT / "new_data"


def main() -> None:
    elections = json.loads((NEW / "new_elections.json").read_text())
    problems: list[str] = []
    print(f"{'year':4} {'states':>6} {'json':>5} {'natl':>5} {'prec':>10} {'results':>11} {'PRE':>4} {'USS':>4} {'USH':>4} {'GOV':>4}  levels")
    for folder in sorted(p for p in NEW.iterdir() if p.is_dir()):
        year = folder.name
        manifest_path = folder / "manifest.json"
        if not manifest_path.exists():
            problems.append(f"{year}: no manifest.json")
            continue
        manifest = json.loads(manifest_path.read_text())
        dbs = sorted(p for p in folder.glob(f"[A-Z][A-Z]-{year}*.db"))
        codes = {p.name[:2] for p in dbs}
        manifest_codes = {s["code"] for s in manifest["states"]}
        if codes != manifest_codes:
            problems.append(f"{year}: db files {sorted(codes - manifest_codes)} not in manifest, manifest lists {sorted(manifest_codes - codes)} without file")
        listed = {e["db"].rsplit("/", 1)[-1] for e in elections.get(year, [])}
        if listed != {s["db"] for s in manifest["states"]}:
            problems.append(f"{year}: new_elections.json lists {len(listed)} dbs, manifest {len(manifest['states'])}")
        for state in manifest["states"]:
            path = folder / state["db"]
            if not path.exists() or path.stat().st_size != state["size"]:
                problems.append(f"{year} {state['code']}: size in manifest differs from file")
        national = folder / f"National-{year}.db"
        natl = 0
        if national.exists():
            db = sqlite3.connect(national)
            natl = db.execute("select count(*) from states").fetchone()[0]
            missing_geom = db.execute("select count(*) from states where boundary is null").fetchone()[0]
            no_summary = db.execute("select count(*) from states where vote_summary is null").fetchone()[0]
            if missing_geom or no_summary:
                problems.append(f"{year}: National.db has {missing_geom} states without boundary, {no_summary} without vote_summary")
            db_names = {r[0] for r in db.execute("select db_name from states")}
            if db_names != {s["db"] for s in manifest["states"]}:
                problems.append(f"{year}: National.db db_names differ from manifest")
            db.close()
        else:
            problems.append(f"{year}: no National db")
        precincts = results = 0
        offices = {"President": 0, "US Senate": 0, "US House": 0, "Governor": 0}
        levels: dict[str, int] = {}
        for path in dbs:
            db = sqlite3.connect(path)
            n_el = db.execute("select count(*) from elections").fetchone()[0]
            n_pr = db.execute("select count(*) from precincts").fetchone()[0]
            n_res = db.execute("select count(*) from precinct_results").fetchone()[0]
            if not n_el or not n_pr or not n_res:
                problems.append(f"{year} {path.name}: elections={n_el} precincts={n_pr} results={n_res}")
            bad = db.execute("select count(*) from precincts where boundary is null").fetchone()[0]
            if bad:
                problems.append(f"{year} {path.name}: {bad} precincts without boundary")
            orphan = db.execute("select count(*) from precincts p where not exists (select 1 from county_precincts c where c.precinct_id=p.id)").fetchone()[0]
            if orphan:
                problems.append(f"{year} {path.name}: {orphan} precincts in no county")
            for office, total in db.execute("select office, sum(total_votes) from elections group by office"):
                offices[office] += total
            # candidate totals must equal precinct results
            diff = db.execute("""select count(*) from candidates c where c.votes != coalesce((select sum(votes) from precinct_results r where r.candidate_id=c.id),0)""").fetchone()[0]
            if diff:
                problems.append(f"{year} {path.name}: {diff} candidates whose votes differ from their precinct results")
            meta = dict(db.execute("select key, value from meta"))
            levels[meta.get("level", "?")] = levels.get(meta.get("level", "?"), 0) + 1
            precincts += n_pr
            results += n_res
            db.close()
        print(f"{year:4} {len(dbs):6} {len(elections.get(year, [])):5} {natl:5} {precincts:10,} {results:11,} "
              f"{'x' if offices['President'] else '-':>4} {'x' if offices['US Senate'] else '-':>4} "
              f"{'x' if offices['US House'] else '-':>4} {'x' if offices['Governor'] else '-':>4}  {levels}")
    years = sorted(elections)
    print("new_elections.json years:", years)
    print("\nPROBLEMS:" if problems else "\nno problems found")
    for problem in problems:
        print(" -", problem)


if __name__ == "__main__":
    main()
