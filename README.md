# DeerAware

DeerAware predicts deer-vehicle collision risks in real time by combining location, season, and time of day, flagging riskier points on your route. This is fully on-device, so no internet is needed.

## Why

Deer-vehicle collisions are common, costly, and largely unwarned-for. DeerAware turns historical collision records into a live risk score a driver can actually act on: not just "deer live in this state," but "this exact stretch of road, at this exact hour, in this exact season, is currently elevated risk."

## Project structure

```
Data_Analysis/
  data_analysis_filtered.ipynb   Exploratory analysis of the raw collision data (pandas/numpy/matplotlib)

Model/
  DVC_data_filtered_clean.csv    Cleaned training data (collision records, 9 states)
  dvc_risk_model.py              The risk model (spatial + seasonal + diurnal KDE)
  export_for_swift.py            Fits the model and bakes it into mobile-ready grids + manifest

model_export/
  manifest.json                  Model parameters, multiplier tables, per-state grid metadata
  grid_<State>.bin                One quantized spatial-risk grid per state

DeerAware/                       iOS app (SwiftUI)
  Engine/DVCRisk.swift           On-device port of the model - loads manifest + grids, scores risk
  AppModel.swift, AppModel+Routing.swift   App state + MapKit route fetching/scoring
  Map/                           Map screen, heatmap overlay rendering, route controls, legend
  Home/                          Current-conditions card (live risk at your location)
  LiveLocation/                  Location-permission banner
```

## Dataset

Training data comes from the public Figshare dataset *"Deer-vehicle collision data for 23 states of the United States"*, currently subset to the 9 states with exact incident coordinates (Connecticut, Georgia, Iowa, Kansas, Maryland, Massachusetts, South Carolina, Texas, Wyoming) — 439,875 rows after de-duplication and dropping out-of-bounds coordinates. Each row has the collision's latitude/longitude, date/time, day-of-year, and the computed sunrise/sunset time for that date and location.

The dataset's other 14 states only include a county centroid rather than an exact incident location, so they aren't usable by the fine-grained spatial model as-is (see **Limitations** below).

## ML pipeline

The "model" is not a neural network - it's a **non-parametric, hand-fit statistical model** (kernel density estimation). There is no gradient descent, loss function, or training loop; "fitting" means computing smoothed histograms and building a spatial index directly from the historical data.

Risk at a given place and time is the product of three independently-estimated factors:

```
risk(lat, lon, day_of_year, time) =
      spatial_intensity(lat, lon)
    x season_factor(day_of_year)
    x diurnal_factor(hours_relative_to_sunset)
```

### 1. Spatial intensity - 2D Gaussian KDE

- Every training collision's (lat, lon) is projected to a local flat-earth (x, y) in kilometers.
- All points are indexed in a k-d tree (`scipy.spatial.cKDTree`).
- To score a location, the model sums a Gaussian kernel `exp(-0.5 * distance^2 / bw^2)` over every training point within 3 bandwidths, where `bw = 2.0 km`, then normalizes so the result is a proper density (collisions per unit area).
- This is literally "how many collisions happened near here, weighted by distance, smoothed over a 2 km radius" - a live nearest-neighbor computation, not a static number.

### 2. Season factor - circular KDE over day-of-year

- All 366 possible days-of-year are binned, and a wrapped 1D Gaussian filter (`scipy.ndimage.gaussian_filter1d`, `mode="wrap"`) smooths the histogram of collision days with a 15-day bandwidth - "wrapped" so December 31st blends into January 1st.
- The result is divided by its own mean, turning it into a **multiplier**: 1.0 = an average day, ~2.2 = a day roughly 2.2x more dangerous than average (the profile peaks in November, matching the fall rutting/hunting season).

### 3. Diurnal factor - circular KDE over hours-relative-to-sunset

- Same smoothing technique, but the input is `collision_time - sunset_time` (mod 24 hours) rather than clock time, so the profile is anchored to dusk regardless of season or latitude. Bandwidth: 1.5 hours.
- Also normalized to a mean of 1.0; it peaks around ~2.3x right after sunset, matching deer's crepuscular activity pattern.

### Fitting

`DVCRiskModel.fit()` (`Model/dvc_risk_model.py`) takes the cleaned dataframe and:
1. Builds the k-d tree over all training coordinates.
2. Computes the 366-value season profile from the `doy` column.
3. Computes the 96-value diurnal profile from `time.decimal - sunset.decimal`.

### Export for mobile (`Model/export_for_swift.py`)

A phone can't carry 440K points + a k-d tree, so the continuous spatial model is baked into a static asset:

1. Fit the model on the full cleaned dataset.
2. For each state, evaluate `spatial_intensity()` on a dense 1 km-resolution lat/lon grid (padded 5% beyond the state's data bounding box).
3. Log10-compress every grid's values and clip to a global `[log_lo, log_hi]` range (the 1st and 99.8th percentile across all states), then quantize to 8-bit (`uint8`, 0-255).
4. Write one raw binary grid per state (`grid_<State>.bin`) plus `manifest.json`, which carries:
   - the exact `season_profile` (366 values) and `diurnal_profile` (96 values) computed during fitting,
   - the log-scale decode parameters,
   - per-state grid dimensions and geographic bounds,
   - `bands` - the 80th/95th/99th percentile spatial-intensity cutoffs used to bucket risk into Low/Moderate/High/Severe.
5. A verification pass compares 12 random points' bilinear grid lookups against the exact (un-quantized) model output to sanity-check the approximation.

## The app

DeerAware is a native SwiftUI iOS app with **no third-party dependencies and no ML runtime** - only Apple frameworks (`SwiftUI`, `Foundation`, `CoreLocation`, `MapKit`, `CoreGraphics`, `Combine`).

- **`Engine/DVCRisk.swift`** is a direct Swift port of the scoring pipeline: it loads `manifest.json` and the per-state `.bin` grids from the bundle, bilinearly samples the correct state's grid for a coordinate, looks up the season/diurnal multipliers by array index, and multiplies all three together - the same formula as the Python model, evaluated with simple array math instead of a live KDE.
- **`AppModel.swift` / `AppModel+Routing.swift`** hold app state and fetch routes via Apple's native `MKDirections` API.
- **`Map/`** renders the risk grid as a heatmap overlay on the map (`HeatmapOverlay` + `HeatmapImage`, drawn with `CoreGraphics`), scores the active route and highlights its riskiest segments (`RouteControls`, `HotspotAnnotation`), and lets the user switch between covered states (`StateSwitcher`, `LegendView`).
- **`Home/`** shows a live "current risk here, right now" card (`CurrentConditionsCard`), refreshed every 60 seconds via a `Combine` timer and the device's live location (`CLLocationManager`).
- **`LiveLocation/LocationBannerView.swift`** handles the location-permission prompt/banner.

Because scoring is just array lookups and bilinear interpolation over a few megabytes of bundled data, the whole thing runs instantly, fully offline, with no location data ever leaving the device.

## Limitations / future work

- **Coverage:** only the 9 states with exact incident coordinates are covered. Outside those states' grids, the app falls back to a flat placeholder risk value rather than a real spatial estimate.
- **Extending to more states:** the Figshare source dataset covers 23 states, but the other 14 only provide a county centroid, not an exact incident location. Feeding those through the current fixed 2 km-bandwidth KDE would create a false pinpoint spike on each county's centroid. The better approach is a **variable-bandwidth KDE** - keep 2 km for exact-coordinate incidents, but use a bandwidth scaled to each county's radius for centroid-only incidents, so those collisions smear into a realistic regional bump instead of a false hotspot.
- **Band thresholds:** the Low/Moderate/High/Severe cutoffs in `manifest.json` are percentiles of the *spatial-only* intensity distribution, but the app applies them to the *combined* spatial x season x diurnal score - so at high-multiplier times (e.g. a November dusk) locations can cross into "Severe" more easily than the original percentile definition implies.
- **True nationwide coverage** would require sourcing additional collision data outside the current dataset (e.g. per-state DOT crash records), since no single public dataset currently provides exact-location deer-collision data for all 50 states.
