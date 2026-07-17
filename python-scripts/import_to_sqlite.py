import sqlite3
import json
import os
import geopandas as gpd
import pandas as pd
import warnings

# Suppress some geometry warnings during dissolve
warnings.filterwarnings('ignore')

DB_NAME = "2024-National-President-rr.db"

if os.path.exists(DB_NAME):
    os.remove(DB_NAME)

conn = sqlite3.connect(DB_NAME)
cursor = conn.cursor()

with open('schema.sql', 'r') as f:
    cursor.executescript(f.read())

print(f"Initialized {DB_NAME}")

def geom_to_dict(x):
    if x is None or x.is_empty: return None
    try:
        return json.dumps(x.__geo_interface__)
    except Exception as e:
        return None

# ID Counters
states_id_seq = 1
parties_id_seq = 1
cands_id_seq = 1
counties_id_seq = 1
cds_id_seq = 1
precincts_id_seq = 1
results_id_seq = 1

# 1. Read shapefiles
path = "data/Texas/tx_2024_gen_all_tx_vtd/tx_2024_gen_all_tx_vtd.shp"
print(f"Reading shapefile {path}...")
gdf = gpd.read_file(path).to_crs("EPSG:4326")

cong_path = "data/Texas/tx_2024_gen_cong_tx_vtd/tx_2024_gen_cong_tx_vtd.shp"
print(f"Reading Congressional shapefile {cong_path}...")
cong_gdf = gpd.read_file(cong_path).to_crs("EPSG:4326")

# 2. Compute Boundaries (Dissolve)
print("Computing State, County, and District boundaries (this may take 10-30 seconds)...")
# State
state_gdf = gdf.assign(state='Texas').dissolve(by='state')
state_boundary = geom_to_dict(state_gdf.iloc[0].geometry) if not state_gdf.empty else None

# Counties
county_gdf = gdf.dissolve(by='County')
county_boundaries = {}
for county_name, row in county_gdf.iterrows():
    county_boundaries[county_name] = geom_to_dict(row.geometry)

# Congressional Districts
cd_gdf = cong_gdf.dissolve(by='CONG_DIST')
cd_boundaries = {}
for cd_val, row in cd_gdf.iterrows():
    if not pd.isna(cd_val):
        cd_str = str(int(cd_val))
        cd_boundaries[cd_str] = geom_to_dict(row.geometry)

# Build precinct to CD mapping
precinct_to_cd = {}
for _, row in cong_gdf.iterrows():
    uid = row.get('UNIQUE_ID')
    cd_val = row.get('CONG_DIST')
    if uid and not pd.isna(cd_val):
        precinct_to_cd[uid] = str(int(cd_val))

# 3. Base Setup (States)
state_id = states_id_seq
states_id_seq += 1
cursor.execute("INSERT INTO states (id, name, boundary) VALUES (?, ?, ?)", (state_id, "Texas", state_boundary))

party_map = {
    'D': 'Democrat', 'R': 'Republican', 'L': 'Libertarian', 
    'G': 'Green', 'I': 'Independent', 'W': 'Write-In', 'O': 'Other'
}
party_ids = {}
for code, name in party_map.items():
    pid = parties_id_seq
    parties_id_seq += 1
    cursor.execute("INSERT INTO parties (id, name) VALUES (?, ?)", (pid, name))
    party_ids[code] = pid

print("Base entities created.")

# Extract candidate columns (Presidential)
president_cols = [c for c in gdf.columns if c.startswith('G24PRE') and len(c) >= 9]

candidate_ids = {}
for col in president_cols:
    office = "President"
    party_code = col[6] if len(col) > 6 else 'O'
    name_code = col[7:10] if len(col) > 7 else col
    party_id = party_ids.get(party_code, party_ids['O'])
    
    cand_id = cands_id_seq
    cands_id_seq += 1
    cursor.execute(
        "INSERT INTO candidates (id, name, party_id, office) VALUES (?, ?, ?, ?)",
        (cand_id, name_code, party_id, office)
    )
    candidate_ids[col] = cand_id

print("Candidates created.")

print("Converting precinct geometries to GeoJSON...")
gdf['geojson'] = gdf.geometry.apply(geom_to_dict)

total_rows = len(gdf)
county_cache = {}
cd_cache = {}

precincts_batch = []
counties_batch = []
cds_batch = []
county_precincts_batch = []
cd_precincts_batch = []
state_regions_batch = []
results_batch = []

print(f"Processing {total_rows} precincts...")
for idx, row in gdf.iterrows():
    # 1. Handle County
    county_name = row['County'] if 'County' in row and not pd.isna(row['County']) else 'Unknown'
    if county_name not in county_cache:
        cid = counties_id_seq
        counties_id_seq += 1
        cb = county_boundaries.get(county_name)
        counties_batch.append((cid, county_name, cb))
        state_regions_batch.append((state_id, cid, 'county'))
        county_cache[county_name] = cid
    county_id = county_cache[county_name]
    
    # 2. Handle Precinct
    uid = row.get('UNIQUE_ID')
    precinct_name = uid or row.get('TX_VTD') or f"Precinct_{idx}"
    precinct_id = precincts_id_seq
    precincts_id_seq += 1
    geom = row['geojson']
    
    # Removed duplicate append
    
    # 3. Handle Congressional District (CD) using mapping
    best_cd_str = precinct_to_cd.get(uid)
    if best_cd_str:
        cd_name = f"District {best_cd_str}"
        if cd_name not in cd_cache:
            cdid = cds_id_seq
            cds_id_seq += 1
            cdb = cd_boundaries.get(best_cd_str)
            cds_batch.append((cdid, cd_name, cdb))
            state_regions_batch.append((state_id, cdid, 'congressional_district'))
            cd_cache[cd_name] = cdid
        cd_id = cd_cache[cd_name]
        cd_precincts_batch.append((precinct_id, cd_id))
        
    # 4. Handle Presidential Results & Population
    total_precinct_presidential_votes = 0
    for col in president_cols:
        votes = row.get(col, 0)
        try:
            votes = int(float(votes)) if votes else 0
        except:
            votes = 0
            
        if votes > 0:
            total_precinct_presidential_votes += votes
            results_batch.append((
                results_id_seq, precinct_id, candidate_ids[col], votes
            ))
            results_id_seq += 1
            
    # Mock Population: Assume ~55% voter turnout (1 / 0.55 ≈ 1.8)
    # Give a small base population if votes are 0 to prevent div-by-zero later
    mock_population = int(total_precinct_presidential_votes * 1.8) if total_precinct_presidential_votes > 0 else 100
    
    precincts_batch.append((precinct_id, precinct_name, geom, mock_population))
    county_precincts_batch.append((precinct_id, county_id))

print("Executing bulk inserts...")
cursor.executemany("INSERT INTO counties (id, name, boundary) VALUES (?, ?, ?)", counties_batch)
cursor.executemany("INSERT INTO congressional_districts (id, name, boundary) VALUES (?, ?, ?)", cds_batch)
cursor.executemany("INSERT INTO state_regions (state_id, region_id, region_type) VALUES (?, ?, ?)", state_regions_batch)
cursor.executemany("INSERT INTO precincts (id, name, boundary, population) VALUES (?, ?, ?, ?)", precincts_batch)
cursor.executemany("INSERT INTO county_precincts (precinct_id, county_id) VALUES (?, ?)", county_precincts_batch)
cursor.executemany("INSERT INTO congressional_district_precincts (precinct_id, congressional_district_id) VALUES (?, ?)", cd_precincts_batch)
cursor.executemany("INSERT INTO precinct_results (id, precinct_id, candidate_id, votes) VALUES (?, ?, ?, ?)", results_batch)

conn.commit()
conn.close()

print(f"Successfully created {DB_NAME} with:")
print(f"- {len(precincts_batch)} precincts")
print(f"- {len(counties_batch)} counties")
print(f"- {len(cds_batch)} congressional districts")
print(f"- {len(state_regions_batch)} state region links")
print(f"- {len(results_batch)} presidential vote records")
