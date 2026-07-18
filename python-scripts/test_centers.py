import geopandas as gpd
import pandas as pd

path = "data/Texas/tx_2024_gen_cong_tx_vtd/tx_2024_gen_cong_tx_vtd.shp"
cong_gdf = gpd.read_file(path).to_crs("EPSG:4326")
cd_gdf = cong_gdf.dissolve(by='CONG_DIST')

for cd_val, row in cd_gdf.iterrows():
    if pd.isna(cd_val): continue
    geom = row.geometry
    rep = geom.representative_point()
    cent = geom.centroid
    if int(cd_val) == 13 or int(cd_val) == 19:
        print(f"CD {cd_val}:")
        print(f"  Representative Point: ({rep.x:.4f}, {rep.y:.4f})")
        print(f"  Centroid:             ({cent.x:.4f}, {cent.y:.4f})")
        print(f"  Contains Centroid?    {geom.contains(cent)}")
        print(f"  Bounds:               {geom.bounds}")
