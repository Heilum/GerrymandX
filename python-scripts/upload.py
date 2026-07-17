import os
import json
import pandas as pd
import geopandas as gpd
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

URL = os.environ.get("SUPABASE_URL")
KEY = os.environ.get("SUPABASE_KEY")
supabase: Client = create_client(URL, KEY)

def get_or_create(table, match_cols, insert_data):
    query = supabase.table(table).select("*")
    for k, v in match_cols.items():
        query = query.eq(k, v)
    res = query.execute()
    if len(res.data) > 0:
        return res.data[0]
    res = supabase.table(table).insert(insert_data).execute()
    return res.data[0]

print("Connecting to Supabase...")

# Base setup
election = get_or_create("elections", {"name": "2024 General Election"}, {"name": "2024 General Election"})
election_id = election["id"]

state = get_or_create("state", {"name": "Texas", "election_id": election_id}, {"name": "Texas", "election_id": election_id})
state_id = state["id"]

party_map = {
    'D': 'Democrat', 'R': 'Republican', 'L': 'Libertarian', 
    'G': 'Green', 'I': 'Independent', 'W': 'Write-In', 'O': 'Other'
}

party_ids = {}
for code, name in party_map.items():
    p = get_or_create("parties", {"name": name}, {"name": name})
    party_ids[code] = p["id"]

print("Base entities created.")

# Read shapefile
path = "data/Texas/tx_2024_gen_all_tx_vtd/tx_2024_gen_all_tx_vtd.shp"
print(f"Reading shapefile {path}...")
gdf = gpd.read_file(path).to_crs("EPSG:4326")

# Extract candidate columns
candidate_cols = [c for c in gdf.columns if len(c) == 10 and c[1:3] == '24' and c[0] in ['G']]
if not candidate_cols:
    # Some cols might not be strictly 10 chars if truncated, let's just use known prefixes from README
    prefixes = ['G24', 'GCC', 'GCO', 'GSL', 'GSS', 'GSU', 'GRR']
    candidate_cols = [c for c in gdf.columns if any(c.startswith(p) for p in prefixes) and len(c) >= 9]

print(f"Found {len(candidate_cols)} candidate columns.")

candidate_ids = {}
for col in candidate_cols:
    office = col[3:6]
    party_code = col[6] if len(col) > 6 else 'O'
    name_code = col[7:10] if len(col) > 7 else col
    party_id = party_ids.get(party_code, party_ids['O'])
    
    cand = get_or_create(
        "candidates", 
        {"name": name_code, "party_id": party_id, "office": office},
        {"name": name_code, "party_id": party_id, "office": office}
    )
    candidate_ids[col] = cand["id"]

print("Candidates created.")

print("Converting geometries to GeoJSON...")
def geom_to_dict(x):
    if x is None or x.is_empty: return None
    try:
        return json.loads(gpd.GeoSeries([x]).to_json())['features'][0]['geometry']
    except:
        return None
        
gdf['geojson'] = gdf.geometry.apply(geom_to_dict)

total_rows = len(gdf)
county_cache = {}
results_batch = []

print(f"Processing {total_rows} precincts...")
for idx, row in gdf.iterrows():
    county_name = row['County']
    if pd.isna(county_name): county_name = 'Unknown'
    
    if county_name not in county_cache:
        c = get_or_create("counties", {"name": county_name, "election_id": election_id}, {"name": county_name, "election_id": election_id})
        county_cache[county_name] = c["id"]
    county_id = county_cache[county_name]
    
    precinct_name = row.get('UNIQUE_ID') or row.get('TX_VTD') or f"Precinct_{idx}"
    geom = row['geojson']
    
    p_res = supabase.table("precincts").select("id").eq("name", precinct_name).eq("election_id", election_id).execute()
    if p_res.data:
        precinct_id = p_res.data[0]['id']
    else:
        p_ins = supabase.table("precincts").insert({
            "name": precinct_name,
            "boundary": geom,
            "election_id": election_id
        }).execute()
        precinct_id = p_ins.data[0]['id']
        
        # Link county
        supabase.table("county_precincts").insert({
            "precinct_id": precinct_id,
            "county_id": county_id
        }).execute()
        
    for col in candidate_cols:
        votes = row.get(col, 0)
        try:
            votes = int(float(votes)) if votes else 0
        except:
            votes = 0
            
        if votes > 0:
            cand_id = candidate_ids[col]
            results_batch.append({
                "precinct_id": precinct_id,
                "candidate_id": cand_id,
                "votes": votes
            })
            
    if len(results_batch) >= 1000:
        supabase.table("precinct_results").upsert(results_batch, on_conflict="precinct_id, candidate_id").execute()
        results_batch = []
        
    if (idx + 1) % 100 == 0:
        print(f"Processed {idx + 1}/{total_rows} precincts...")

if results_batch:
    supabase.table("precinct_results").upsert(results_batch, on_conflict="precinct_id, candidate_id").execute()

print("All done!")
