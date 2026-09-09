"""
Export the fitted DVC risk model to files a Swift app can read.

Produces  model_export/
    manifest.json          - decode params, the two temporal profiles, band cutoffs,
                             and one entry per state (grid file + geographic bbox)
    grid_<State>.bin        - rows*cols bytes, uint8, row-major, ROW 0 = NORTH edge.
                             byte b  ->  relative = b/255
                                         log10(intensity+eps) = log_lo + relative*(log_hi-log_lo)
                                         intensity = 10**that - eps

The Swift side loads these once and computes
    risk = intensity(lat,lon) * season_profile[doy] * diurnal_profile[hoursAfterSunset]
"""
import json
import time
from pathlib import Path

import numpy as np
import pandas as pd

from dvc_risk_model import DVCRiskModel, US_LAT, US_LON

CSV = "DVC_data_filtered.csv"
OUT = Path("model_export")
CELL_KM = 1.0          # grid resolution (deer risk isn't meaningful below the 2 km bandwidth)
BBOX_PAD = 0.05        # pad each state's data bounding box by 5%
EPS = 1e-12
CHUNK = 40_000         # grid points scored per call (bounds memory)

OUT.mkdir(exist_ok=True)

# --------------------------------------------------------------- fit on all data ---
df = pd.read_csv(CSV, index_col=0)
n0 = len(df)
df = df.drop_duplicates()
df = df[df["Latitude"].between(*US_LAT) & df["Longitude"].between(*US_LON)].copy()
print(f"training on {len(df):,} rows (from {n0:,})")

model = DVCRiskModel(spatial_bw_km=2.0, season_bw_days=15.0, diurnal_bw_hours=1.5).fit(df)

# --------------------------------------------------- pass 1: raw intensity grids ---
raw = {}
for name, g in df.groupby("state"):
    # Clip the grid extent to robust percentiles so a few mislocated records
    # don't blow the bounding box up (the KDE itself is unaffected by them).
    latmin, latmax = (float(v) for v in np.percentile(g["Latitude"], [0.05, 99.95]))
    lonmin, lonmax = (float(v) for v in np.percentile(g["Longitude"], [0.05, 99.95]))
    latpad, lonpad = BBOX_PAD * (latmax - latmin), BBOX_PAD * (lonmax - lonmin)
    latmin, latmax = latmin - latpad, latmax + latpad
    lonmin, lonmax = lonmin - lonpad, lonmax + lonpad
    mean_lat = 0.5 * (latmin + latmax)

    rows = max(2, int(np.ceil((latmax - latmin) * 110.57 / CELL_KM)))
    cols = max(2, int(np.ceil((lonmax - lonmin) * 111.32 * np.cos(np.radians(mean_lat)) / CELL_KM)))
    lat_axis = np.linspace(latmax, latmin, rows)   # row 0 = north
    lon_axis = np.linspace(lonmin, lonmax, cols)   # col 0 = west
    LON, LAT = np.meshgrid(lon_axis, lat_axis)
    flat_lat, flat_lon = LAT.ravel(), LON.ravel()

    Z = np.empty(flat_lat.size)
    t0 = time.time()
    for i in range(0, flat_lat.size, CHUNK):
        s = slice(i, i + CHUNK)
        Z[s] = model.spatial_intensity(flat_lat[s], flat_lon[s])
    Z = Z.reshape(rows, cols)

    raw[name] = dict(Z=Z, rows=rows, cols=cols,
                     lat_top=latmax, lat_bottom=latmin, lon_left=lonmin, lon_right=lonmax)
    print(f"  {name:16s} {rows:4d}x{cols:<4d}  {time.time() - t0:5.1f}s  Zmax={Z.max():.3e}")

# ------------------------------------------------- global log scale for encoding ---
logv_pool = np.concatenate([np.log10(r["Z"][r["Z"] > 0].ravel() + EPS) for r in raw.values()])
log_lo = float(np.percentile(logv_pool, 1.0))
log_hi = float(np.percentile(logv_pool, 99.8))
print(f"\nglobal log10(intensity) encoding range: [{log_lo:.3f}, {log_hi:.3f}]")

# --------------------------------------------------- pass 2: write .bin + bands ---
states_meta, band_pool = [], []
floor_Z = 10.0 ** log_lo - EPS
for name, r in raw.items():
    rel = np.clip((np.log10(r["Z"] + EPS) - log_lo) / (log_hi - log_lo), 0.0, 1.0)
    u8 = np.round(rel * 255).astype(np.uint8)
    fname = f"grid_{name.replace(' ', '_')}.bin"
    (OUT / fname).write_bytes(u8.tobytes())

    band_pool.append(r["Z"][r["Z"] > floor_Z].ravel())   # populated cells only
    states_meta.append(dict(
        name=name, file=fname, rows=r["rows"], cols=r["cols"],
        lat_top=r["lat_top"], lat_bottom=r["lat_bottom"],
        lon_left=r["lon_left"], lon_right=r["lon_right"],
    ))

bz = np.concatenate(band_pool)
bands = {f"p{p}": float(np.percentile(bz, p)) for p in (80, 95, 99)}

# ---------------------------------------------------------------- write manifest ---
manifest = dict(
    version=1,
    model="spatiotemporal-kde",
    cell_km=CELL_KM,
    spatial_bw_km=2.0,
    trained_rows=int(len(df)),
    decode=dict(log_lo=log_lo, log_hi=log_hi, eps=EPS),
    season_index="array[dayOfYear % 366]; dayOfYear is 1..366",
    season_profile=[float(x) for x in model.season_prof],          # length 366
    diurnal_index="array[floor(((hoursAfterSunset mod 24) / 24) * 96)]; length 96",
    diurnal_profile=[float(x) for x in model.diurnal_prof],        # length 96
    bands=bands,   # intensity cutoffs over populated grid cells: moderate>=p80, high>=p95, severe>=p99
    states=states_meta,
)
(OUT / "manifest.json").write_text(json.dumps(manifest, indent=1))

# --------------------------------------------------------------- verify + report ---
print("\nverification (bilinear grid lookup vs model.score, 12 random collisions):")
chk = df.sample(12, random_state=0)
man = json.loads((OUT / "manifest.json").read_text())
grids = {s["name"]: (np.frombuffer((OUT / s["file"]).read_bytes(), np.uint8).reshape(s["rows"], s["cols"]), s)
         for s in man["states"]}


def lookup(lat, lon, meta_grid):
    arr, s = meta_grid
    fy = (s["lat_top"] - lat) / (s["lat_top"] - s["lat_bottom"]) * (s["rows"] - 1)
    fx = (lon - s["lon_left"]) / (s["lon_right"] - s["lon_left"]) * (s["cols"] - 1)
    y0 = min(max(int(np.floor(fy)), 0), s["rows"] - 1); y1 = min(y0 + 1, s["rows"] - 1)
    x0 = min(max(int(np.floor(fx)), 0), s["cols"] - 1); x1 = min(x0 + 1, s["cols"] - 1)
    ty, tx = fy - y0, fx - x0
    top = arr[y0, x0] * (1 - tx) + arr[y0, x1] * tx
    bot = arr[y1, x0] * (1 - tx) + arr[y1, x1] * tx
    rel = (top * (1 - ty) + bot * ty) / 255.0
    return 10.0 ** (log_lo + rel * (log_hi - log_lo)) - EPS


for _, row in chk.iterrows():
    approx = lookup(row["Latitude"], row["Longitude"], grids[row["state"]])
    exact = float(model.spatial_intensity(np.array([row["Latitude"]]), np.array([row["Longitude"]]))[0])
    ratio = approx / exact if exact else float("nan")
    print(f"  {row['state']:14s} exact={exact:.3e}  grid={approx:.3e}  ratio={ratio:.2f}")

total = sum((OUT / s["file"]).stat().st_size for s in states_meta) + (OUT / "manifest.json").stat().st_size
print(f"\nwrote {OUT}/  ({len(states_meta)} grids + manifest.json, {total/1e6:.2f} MB total)")
