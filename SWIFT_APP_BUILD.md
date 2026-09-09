# DeerAware — Swift App Build Spec

A build guide for the agent implementing the iOS app. Work **phase by phase**; each
phase ends with an acceptance test you can run before starting the next. Do **not**
try to build the whole app in one pass.

The risk model is already done. This app is a UI around it.

---

## 1. What already exists (do not rebuild)

Located in `Data_Analysis/` of this repo:

| Artifact | What it is |
|---|---|
| `dvc_risk_model.py` | The model (Python). Reference only — you do not run this. |
| `DVCRisk.swift` | **The scoring engine, ready to drop in.** `DVCRiskModel` class + `DVCRiskComponents`, `DVCRiskBand`, `DVCRoutePointRisk`, MapKit helpers (`routeOverlays`, `hotspots`, `MKPolyline.coordinates()`). |
| `model_export/manifest.json` | Decode params, a 366-value `season_profile`, a 96-value `diurnal_profile`, band cutoffs, and per-state grid metadata (rows, cols, bbox). |
| `model_export/grid_<State>.bin` × 9 | One state's spatial risk raster: `rows*cols` bytes, `uint8`, row-major, **row 0 = north edge**. Byte → `relative = byte/255` → `intensity = 10^(log_lo + relative*(log_hi-log_lo)) - eps`. |

**Covered states (9):** Connecticut, Georgia, Iowa, Kansas, Maryland, Massachusetts,
South Carolina, Texas, Wyoming. These are the only states with data; there is no
coverage anywhere else.

### How a score is produced

```
risk(lat, lon, date) = spatialIntensity(lat, lon)      // bilinear lookup in the state grid
                     * seasonFactor(dayOfYear)          // season_profile[...], ~2.2x in November
                     * diurnalFactor(hoursAfterSunset)  // diurnal_profile[...], ~2.3x just after dusk
```

`DVCRiskModel.risk(at:date:)` already does all of this. `DVCRiskModel.scoreRoute(...)`
samples a polyline and scores each point at the time the driver will be there.

### What the "heatmap" is

The heatmap layer **is** `grid_<State>.bin` rendered with colour — it is the model's
density surface of ~440k recorded 1994–2021 deer-vehicle collisions. Do **not** try to
plot raw collision points; they are not shipped and there are too many.

---

## 2. Target & conventions

- **iOS 17+**, SwiftUI lifecycle, Swift 5.9. Use `@Observable` for app state.
- **Apple Maps / MapKit** — no API key, no third-party map SDK.
- The **map screen is one `UIViewRepresentable` wrapping `MKMapView`** (custom raster
  overlay rules out the pure-SwiftUI `Map`). Polylines, annotations, and the heatmap
  all live on that one `MKMapView` via its delegate.
- Everything works **offline** except `MKDirections` and destination search (network).
- Info.plist: `NSLocationWhenInUseUsageDescription` = "Shows deer-collision risk near
  your location and along your route."
- No analytics, no accounts, no network calls beyond MapKit.

### Suggested file layout

```
DeerAware/
  DeerAwareApp.swift
  AppModel.swift                 // @Observable: engine, selectedState, route, location
  Engine/
    DVCRisk.swift                // existing file, + Phase 3 additions
    model_export/                // FOLDER REFERENCE (blue), keeps the subdirectory
  Home/
    HomeView.swift
    CurrentConditionsCard.swift
  Map/
    MapScreen.swift              // state switcher + RiskMapView + controls + legend
    StateSwitcher.swift
    RiskMapView.swift            // UIViewRepresentable over MKMapView + Coordinator
    HeatmapOverlay.swift         // MKOverlay + MKOverlayRenderer
    HeatmapImage.swift           // grid bytes -> CGImage
    RouteControls.swift
    LegendView.swift
  Common/
    RiskPalette.swift            // band/relative -> Color & UIColor (single source of truth)
```

### Colour palette (single source of truth — `RiskPalette.swift`)

Match `DVCRiskBand.rgba` from `DVCRisk.swift`:

| Band | RGBA (0–1) | Use |
|---|---|---|
| low | 0.20, 0.70, 0.32, 0.85 | route segments, legend |
| moderate | 0.96, 0.79, 0.22, 0.90 | |
| high | 0.95, 0.51, 0.12, 0.95 | pin tint |
| severe | 0.86, 0.16, 0.16, 1.00 | pin tint |

Heatmap uses a continuous ramp (green→yellow→orange→red) keyed off `relative`, with
alpha rising from 0 (transparent) to ~0.65.

---

## 3. Phases

### Phase 0 — Scaffold & engine smoke test

**Goal:** app launches; the model loads from the bundle; one real score prints.

**Do:**
1. New Xcode project "DeerAware", SwiftUI, iOS 17.
2. Add `Data_Analysis/DVCRisk.swift` to the target (`Engine/DVCRisk.swift`).
3. Add `Data_Analysis/model_export/` as a **folder reference** (choose "Create folder
   references", the folder icon stays blue). Confirm `manifest.json` and all 9 `.bin`
   files are in *Copy Bundle Resources* under `model_export/`.
4. Add the Info.plist location key.
5. `AppModel.swift`:

```swift
import Foundation
import CoreLocation

@Observable
final class AppModel {
    let engine: DVCRiskModel
    var loadError: String?

    init() {
        do { engine = try DVCRiskModel(bundle: .main) }
        catch {
            // Fallback so previews/tests still compile; surface the error in UI.
            fatalError("Failed to load model_export: \(error)")
        }
    }
}
```

6. Temporary `ContentView` that shows
   `appModel.engine.risk(at: .init(latitude: 41.59, longitude: -93.62), date: .now)`
   (downtown Des Moines) in a `Text`.

**Acceptance:** app runs on a device/simulator and shows a non-zero risk number with
`covered == true`. If it crashes on load, the folder reference is wrong.

**Out of scope:** any map, any navigation.

---

### Phase 1 — App shell & navigation

**Goal:** two-tab shell.

**Do:**
- `DeerAwareApp` injects `AppModel` via `.environment(...)`.
- Root `TabView` with exactly two tabs:
  - **Home** (`house` symbol) → `HomeView`
  - **Map** (`map` symbol) → `MapScreen`
- `MapScreen` for now is a placeholder `Text("Map")`.

> **On "tabs for different states":** 9 bottom tabs is unusable. Implement state
> selection as an in-screen **segmented switcher** at the top of the Map screen
> (Phase 3). The Map tab title reflects the selected state.

**Acceptance:** can switch between Home and Map tabs; `AppModel` is a single shared
instance (add a `print` in `init` to confirm it runs once).

---

### Phase 2 — Home / explainer page

**Goal:** a scrollable page that explains the app. Static content + one live card.

**Do — `HomeView.swift`:** a `ScrollView` with:

1. **Title block:** "DeerAware" + one line: "Where deer-vehicle collisions cluster, and
   when the risk peaks — for 9 US states."
2. **How it works** (3 cards, `Label` + short text):
   - *Places* — "A heatmap built from ~440,000 recorded deer-vehicle collisions
     (1994–2021). Brighter = more collisions historically."
   - *Season* — "Risk more than doubles in the rut: **October–December**, peaking in
     **November (~2.2×)**."
   - *Time of day* — "Risk peaks around **dusk and the two hours after** (~2.3×), and
     is lowest mid-morning."
3. **Coverage card:** the 9 state names. "No data outside these states."
4. **`CurrentConditionsCard`** (live): if location permission is granted and the user
   is inside a covered state, show the current `seasonFactor` and `diurnalFactor` as
   two "×N.N" chips and a one-line verdict ("Elevated — dusk in November"). If outside
   coverage, show "Not in a covered state." Use `appModel.engine.risk(at:date:)`.
5. **Disclaimer card** (muted): "Based on historical reports, which also reflect where
   traffic is heaviest. This is context, not a live deer detector — keep your eyes on
   the road."
6. Primary button "Open the map" → switches to the Map tab (bind `TabView` selection
   through `AppModel`).

**Acceptance:** Home renders all sections; the live card shows plausible multipliers
that change if you change the device clock to November / 6pm.

**Out of scope:** routing, navigation to specific states.

---

### Phase 3 — State map + collision heatmap

**Goal:** Map screen shows the selected state with a colour heatmap overlay; a
segmented switcher changes states and animates the map.

#### 3a. Add public accessors to `DVCRisk.swift`

Insert into `DVCRisk.swift` (the engine currently keeps grids private):

```swift
public struct DVCDecodeParams { public let logLo, logHi, eps: Double }

public struct DVCStateGridInfo {
    public let name: String
    public let rows, cols: Int
    public let latTop, latBottom, lonLeft, lonRight: Double
    public let bytes: [UInt8]                       // rows*cols, row 0 = north

    public var centerCoordinate: CLLocationCoordinate2D {
        .init(latitude: (latTop + latBottom) / 2, longitude: (lonLeft + lonRight) / 2)
    }
}

public extension DVCRiskModel {
    /// Covered state names, alphabetical.
    var stateNames: [String] { grids.map(\.name).sorted() }

    var decodeParams: DVCDecodeParams { .init(logLo: logLo, logHi: logHi, eps: eps) }

    /// intensity cutoffs for moderate / high / severe.
    var bandCutoffs: (p80: Double, p95: Double, p99: Double) { (bandP80, bandP95, bandP99) }

    func gridInfo(for stateName: String) -> DVCStateGridInfo? {
        guard let g = grids.first(where: { $0.name == stateName }) else { return nil }
        return .init(name: g.name, rows: g.rows, cols: g.cols,
                     latTop: g.latTop, latBottom: g.latBottom,
                     lonLeft: g.lonLeft, lonRight: g.lonRight, bytes: g.bytes)
    }

    /// intensity (from a decoded byte) for the given `relative` value.
    func intensity(forRelative r: Double) -> Double {
        max(0, pow(10.0, logLo + r * (logHi - logLo)) - eps)
    }
}

#if canImport(MapKit)
import MapKit
public extension DVCStateGridInfo {
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: centerCoordinate,
            span: MKCoordinateSpan(latitudeDelta: (latTop - latBottom) * 1.15,
                                   longitudeDelta: (lonRight - lonLeft) * 1.15))
    }
}
#endif
```

Add `selectedStateName: String` to `AppModel` (default `"Iowa"`).

#### 3b. `HeatmapImage.swift` — grid bytes → `CGImage`

```swift
import CoreGraphics

enum HeatmapStyle { case smooth, banded }

/// RGBA8, width = cols, height = rows, row 0 = north. Premultiplied alpha.
func makeHeatmapImage(_ g: DVCStateGridInfo,
                      engine: DVCRiskModel,
                      style: HeatmapStyle = .smooth) -> CGImage? {
    let w = g.cols, h = g.rows
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cut = engine.bandCutoffs

    for i in 0..<(w * h) {
        let rel = Double(g.bytes[i]) / 255.0
        var r = 0.0, gr = 0.0, b = 0.0, a = 0.0

        switch style {
        case .smooth:
            if rel > 0.02 {
                // hue 0.33 (green) -> 0.0 (red) as rel goes 0.15 -> 0.9
                let t = min(max((rel - 0.15) / 0.75, 0), 1)
                (r, gr, b) = hsv(h: 0.33 * (1 - t), s: 0.9, v: 0.95)
                a = min(max((rel - 0.05) / 0.6, 0), 0.65)
            }
        case .banded:
            let inten = engine.intensity(forRelative: rel)
            let rgba: (Double, Double, Double, Double)
            if inten >= cut.p99      { rgba = DVCRiskBand.severe.rgba   }
            else if inten >= cut.p95 { rgba = DVCRiskBand.high.rgba     }
            else if inten >= cut.p80 { rgba = DVCRiskBand.moderate.rgba }
            else if rel > 0.02       { rgba = DVCRiskBand.low.rgba      }
            else                     { rgba = (0,0,0,0)                 }
            (r, gr, b, a) = rgba
        }

        // premultiply
        px[i*4+0] = UInt8(r * a * 255); px[i*4+1] = UInt8(gr * a * 255)
        px[i*4+2] = UInt8(b * a * 255); px[i*4+3] = UInt8(a * 255)
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
    return ctx.makeImage()
}

// small helper
func hsv(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
    let i = floor(h * 6), f = h * 6 - i
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch Int(i) % 6 {
    case 0: return (v, t, p); case 1: return (q, v, p); case 2: return (p, v, t)
    case 3: return (p, q, v); case 4: return (t, p, v); default: return (v, p, q)
    }
}
```

Cache the built `CGImage` per state (don't rebuild on every map pan).

#### 3c. `HeatmapOverlay.swift`

```swift
import MapKit

final class HeatmapOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let image: CGImage

    init(_ g: DVCStateGridInfo, image: CGImage) {
        self.image = image
        let tl = MKMapPoint(CLLocationCoordinate2D(latitude: g.latTop, longitude: g.lonLeft))
        let br = MKMapPoint(CLLocationCoordinate2D(latitude: g.latBottom, longitude: g.lonRight))
        boundingMapRect = MKMapRect(x: min(tl.x, br.x), y: min(tl.y, br.y),
                                    width: abs(br.x - tl.x), height: abs(br.y - tl.y))
        coordinate = g.centerCoordinate
    }
}

final class HeatmapOverlayRenderer: MKOverlayRenderer {
    private let image: CGImage
    init(_ overlay: HeatmapOverlay) { image = overlay.image; super.init(overlay: overlay) }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let rect = self.rect(for: overlay.boundingMapRect)
        ctx.interpolationQuality = .high
        // CGImage draws y-up; flip so grid row 0 lands on the north edge.
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
    }
}
```

> The grid is equirectangular; MapKit is Mercator. Over one state the stretch is a few
> percent — acceptable for v1. If it looks visibly wrong at the top/bottom of Wyoming
> or Texas, note it and move on; a per-pixel reprojection is a later optimisation.
> If the heatmap renders upside-down, remove the translate/scale flip.

#### 3d. `RiskMapView.swift` — the `UIViewRepresentable`

```swift
import SwiftUI
import MapKit

struct RiskMapView: UIViewRepresentable {
    @Environment(AppModel.self) private var app

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.pointOfInterestFilter = .excludingAll
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.sync(mv, app: app)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var shownState: String?
        private var imageCache: [String: CGImage] = [:]

        func sync(_ mv: MKMapView, app: AppModel) {
            // 1. Heatmap for the selected state
            if shownState != app.selectedStateName,
               let info = app.engine.gridInfo(for: app.selectedStateName) {
                shownState = app.selectedStateName
                mv.removeOverlays(mv.overlays.filter { $0 is HeatmapOverlay })
                let img = imageCache[info.name] ?? makeHeatmapImage(info, engine: app.engine)
                if let img {
                    imageCache[info.name] = img
                    mv.addOverlay(HeatmapOverlay(info, image: img), level: .aboveRoads)
                }
                mv.setRegion(info.region, animated: true)
            }
            // 2. Route overlays + hotspot pins (Phases 4–5) — diff against app.routeScored
        }

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let h = overlay as? HeatmapOverlay { return HeatmapOverlayRenderer(h) }
            if let line = overlay as? MKPolyline, let raw = Int(line.title ?? ""),
               let band = DVCRiskBand(rawValue: raw) {
                let r = MKPolylineRenderer(polyline: line)
                let c = band.rgba
                r.strokeColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
                r.lineWidth = 6; r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
```

#### 3e. `StateSwitcher.swift` + `MapScreen.swift`

- `StateSwitcher`: a horizontally scrolling row of pill buttons, one per
  `engine.stateNames`, bound to `app.selectedStateName`. Selected pill filled with
  `.tint`.
- `MapScreen`: `VStack { StateSwitcher; RiskMapView }`, `.navigationTitle(app.selectedStateName)`.

**Acceptance:**
- Map tab opens on Iowa, fitted to the state, green→red heatmap tracing road corridors
  and towns.
- Tap "Wyoming" → map animates west, heatmap swaps within ~1s (first build of an
  image may take up to ~1s for Texas; cached thereafter).
- No heatmap bleeds outside the state bbox.

**Out of scope:** routes, pins, live location.

---

### Phase 4 — Route entry & colour-coded route line

**Goal:** user picks a destination; a risk-coloured route line is drawn.

**Do — `RouteControls.swift`:**
- Origin = current location (fallback: centre of selected state).
- Destination: `TextField` + `MKLocalSearchCompleter` suggestions, or a plain
  `MKLocalSearch` on submit.
- "Show risk" button.

**Routing + scoring (put in `AppModel`):**

```swift
func buildRoute(to dest: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) async {
    let req = MKDirections.Request()
    req.source = MKMapItem(placemark: .init(coordinate: origin))
    req.destination = MKMapItem(placemark: .init(coordinate: dest))
    req.transportType = .automobile
    guard let route = try? await MKDirections(request: req).calculate().routes.first else { return }
    self.route = route
    self.routeScored = engine.scoreRoute(route.polyline.coordinates(),
                                         departure: .now,
                                         expectedTravelTime: route.expectedTravelTime)
}
```

- In the map `Coordinator.sync`, when `routeScored` changes: remove old `MKPolyline`s,
  add `engine.routeOverlays(routeScored)`, and `mv.setVisibleMapRect(route.polyline
  .boundingMapRect, edgePadding: ..., animated: true)`.
- Add a "departing now / in 1h / in 3h" control that re-scores with a different
  `departure` (risk shifts with dusk).

**Acceptance:** entering a destination in the selected state draws a multi-colour line
that is mostly green with amber/red patches; changing departure time visibly changes
the colours near the far end of a long route.

**Out of scope:** turn-by-turn, pins.

---

### Phase 5 — Critical-point pins

**Goal:** a few warning pins on the worst parts of the route.

**Do:**
- `app.hotspots = engine.hotspots(routeScored, minBand: .high, limit: 3)`.
- Custom `MKAnnotationView` (or `MKMarkerAnnotationView` with
  `markerTintColor` from the band, `glyphImage` = `exclamationmark.triangle.fill`).
- Callout: title = "`<Band>` deer risk", subtitle = "`~<mins>` min ahead · `<ETA time>`".
- Tapping a pin (or a row in an optional bottom list) centres the map on it.
- In `Coordinator.sync`, diff annotations against `app.hotspots` (remove non-user,
  non-current annotations and re-add).

**Acceptance:** 1–3 triangular pins appear on red/amber stretches; callouts show a
sensible ETA; no pins when the whole route is low risk.

**Out of scope:** notifications.

---

### Phase 6 — Legend & polish

- `LegendView`: a small rounded card over the map — a green→red gradient bar labelled
  "Fewer / More recorded collisions", plus four dots for the route bands. Toggle with
  an "i" button.
- Heatmap style toggle: `.smooth` ↔ `.banded` (Phase 3b).
- Loading spinner while a route calculates; inline error text on failure ("No route
  found", "Search needs a connection").
- Empty state on the Map before a route: subtle hint "Enter a destination to score
  your drive."
- Dark mode: verify heatmap alpha still reads on the dark map; bump alpha ~0.1 if not.
- Dynamic Type on Home and callouts.
- Respect "Reduce Motion" for the state-switch animation.

**Acceptance:** legend explains every colour on screen; toggling style re-renders;
dark mode looks intentional.

---

### Phase 7 — Live location mode (stretch, optional)

- `CLLocationManager` (`whenInUse`), `desiredAccuracy = .nearestTenMeters`.
- A bottom banner showing current-location risk band + the active multipliers, tinted
  by band, updating as you move.
- When the user's location enters a `.high`/`.severe` segment of the active route,
  a single haptic + banner flash. Debounce: at most one alert per 90 s, and only if
  the band increased.
- Never alert without an active route.

**Acceptance:** driving the simulator along a scored route (GPX file) flips the banner
colour at the right places and does not spam alerts.

---

## 4. Definition of done

- [ ] Home explains places / season / time-of-day, lists the 9 states, shows the
      disclaimer, and has a live current-conditions card.
- [ ] Map tab: state switcher over a MapKit map with the collision heatmap for the
      chosen state; map fits the state.
- [ ] Destination entry produces a risk-coloured route line, re-scoreable by departure
      time.
- [ ] Up to 3 warning pins on the worst stretches with ETA callouts.
- [ ] Legend on the map; light + dark both legible.
- [ ] Fully offline except route calculation / place search.
- [ ] No crash when: location denied; destination outside all covered states; no route
      found; airplane mode.

## 5. Known caveats to preserve (surface, don't hide)

- Heatmap brightness partly reflects **traffic volume**, not just deer — the model
  can rank a general area/time well but cannot pick the exact 200 m hotspot.
- Coverage is **9 states only**. Outside them, `risk(...)` returns `covered == false`
  and a temporal-only estimate — the UI must say "no local data", not show a fake
  heatmap.
- Sunset is computed with a ~10–15 min approximation. Acceptable; a `Solar` package
  swap is noted in `DVCRisk.swift`.
- Data spans 1994–2021; recent-year reporting is uneven. This is historical context.

## 6. First steps for the implementing agent

1. Do **Phase 0** and stop. Confirm the model loads from the bundle and prints a real
   score. Everything else depends on that folder reference being correct.
2. Then Phases 1 → 2 → 3. Get the heatmap right before touching routing.
3. Phases 4–5 are the core feature; 6 is polish; 7 is optional.
4. Keep `RiskPalette.swift` the only place colours are defined.
5. After each phase, run its acceptance test on a simulator before continuing.
