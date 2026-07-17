import geopandas as gpd
import os

path = "data/Texas/tx_2024_gen_all_tx_vtd/tx_2024_gen_all_tx_vtd.shp"
print(f"Reading {path}...")
gdf = gpd.read_file(path)
print("Columns:", gdf.columns.tolist())
print("First row:\n", gdf.iloc[0])
