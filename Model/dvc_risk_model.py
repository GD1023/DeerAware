
from __future__ import annotations

import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.spatial import cKDTree

KM_PER_DEG_LAT = 110.57
KM_PER_DEG_LON_EQUATOR = 111.32

# Plausible US bounding box (incl. Alaska) - used to drop corrupt coordinates.
US_LAT = (18.0, 72.0)
US_LON = (-170.0, -60.0)

# Standard-time UTC offsets by the dataset's `timezone` values (DST ignored).
TZ_OFFSET = {"Eastern": -5, "Central": -6, "Mountain": -7, "Pacific": -8, "Alaska": -9}


def _circular_profile(samples, period, nbins, bw_units):
    """Binned circular KDE -> array of length nbins, normalised to mean 1.0."""
    samples = np.asarray(samples, float) % period
    idx = np.clip((samples / period * nbins).astype(int), 0, nbins - 1)
    hist = np.bincount(idx, minlength=nbins).astype(float)
    sigma_bins = bw_units / (period / nbins)
    smooth = gaussian_filter1d(hist, sigma_bins, mode="wrap")
    smooth /= smooth.mean()
    return smooth


class DVCRiskModel:
    def __init__(self, spatial_bw_km=2.0, season_bw_days=15.0, diurnal_bw_hours=1.5):
        self.spatial_bw_km = float(spatial_bw_km)
        self.season_bw_days = float(season_bw_days)
        self.diurnal_bw_hours = float(diurnal_bw_hours)

    # ------------------------------------------------------------------ fit ---
    def fit(self, df):
        lat = df["Latitude"].to_numpy(float)
        lon = df["Longitude"].to_numpy(float)
        self.lat0 = float(np.mean(lat))
        self.lon0 = float(np.mean(lon))
        self.n_train = len(df)
        self.tree = cKDTree(self._project(lat, lon))

        self.season_nbins = 366
        self.season_prof = _circular_profile(
            df["doy"].to_numpy(float), 366.0, self.season_nbins, self.season_bw_days
        )

        hrel = (df["time.decimal"].to_numpy(float) - df["sunset.decimal"].to_numpy(float)) % 24.0
        self.diurnal_nbins = 96
        self.diurnal_prof = _circular_profile(
            hrel, 24.0, self.diurnal_nbins, self.diurnal_bw_hours
        )
        return self

    # -------------------------------------------------------------- helpers ---
    def _project(self, lat, lon):
        lat = np.asarray(lat, float)
        lon = np.asarray(lon, float)
        x = (lon - self.lon0) * KM_PER_DEG_LON_EQUATOR * np.cos(np.radians(lat))
        y = (lat - self.lat0) * KM_PER_DEG_LAT
        return np.column_stack([np.ravel(x), np.ravel(y)])

    # ---------------------------------------------------------- components ----
    def spatial_intensity(self, lat, lon):
        xy = self._project(lat, lon)
        bw = self.spatial_bw_km
        radius = 3.0 * bw
        nbr = self.tree.query_ball_point(xy, radius, workers=-1)
        counts = np.fromiter((len(n) for n in nbr), int, len(nbr))
        out = np.zeros(len(xy))
        if counts.sum():
            flat = np.concatenate([np.asarray(n, int) for n in nbr if n])
            grp = np.repeat(np.arange(len(nbr)), counts)
            diff = self.tree.data[flat] - xy[grp]
            w = np.exp(-0.5 * np.einsum("ij,ij->i", diff, diff) / bw**2)
            np.add.at(out, grp, w)
        return out / (self.n_train * 2.0 * np.pi * bw**2)

    def season_factor(self, doy):
        idx = np.clip(
            (np.asarray(doy, float) % 366.0 / 366.0 * self.season_nbins).astype(int),
            0, self.season_nbins - 1,
        )
        return self.season_prof[idx]

    def diurnal_factor(self, time_decimal, sunset_decimal):
        hrel = (np.asarray(time_decimal, float) - np.asarray(sunset_decimal, float)) % 24.0
        idx = np.clip((hrel / 24.0 * self.diurnal_nbins).astype(int), 0, self.diurnal_nbins - 1)
        return self.diurnal_prof[idx]

    # -------------------------------------------------------------- score ----
    def score(self, lat, lon, doy, time_decimal, sunset_decimal, components=False):
        s = self.spatial_intensity(lat, lon)
        se = np.atleast_1d(self.season_factor(doy))
        di = np.atleast_1d(self.diurnal_factor(time_decimal, sunset_decimal))
        risk = s * se * di
        if components:
            return {"risk": risk, "spatial": s, "season": se, "diurnal": di}
        return risk


def solar_sunset_decimal(lat, lon, doy, tz_offset_hours):
    """Approx local decimal hour of sunset (NOAA low-accuracy algorithm, no DST)."""
    lat = np.asarray(lat, float)
    lon = np.asarray(lon, float)
    doy = np.asarray(doy, float)
    gamma = 2.0 * np.pi / 365.0 * (doy - 1.0)
    eqtime = 229.18 * (
        0.000075 + 0.001868 * np.cos(gamma) - 0.032077 * np.sin(gamma)
        - 0.014615 * np.cos(2 * gamma) - 0.040849 * np.sin(2 * gamma)
    )
    decl = (
        0.006918 - 0.399912 * np.cos(gamma) + 0.070257 * np.sin(gamma)
        - 0.006758 * np.cos(2 * gamma) + 0.000907 * np.sin(2 * gamma)
        - 0.002697 * np.cos(3 * gamma) + 0.00148 * np.sin(3 * gamma)
    )
    lat_r = np.radians(lat)
    cos_ha = np.cos(np.radians(90.833)) / (np.cos(lat_r) * np.cos(decl)) - np.tan(lat_r) * np.tan(decl)
    ha = np.degrees(np.arccos(np.clip(cos_ha, -1.0, 1.0)))
    solar_noon_min = 720.0 - 4.0 * lon - eqtime + tz_offset_hours * 60.0
    return (solar_noon_min + 4.0 * ha) / 60.0
