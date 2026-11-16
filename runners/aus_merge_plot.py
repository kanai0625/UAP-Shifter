#!/usr/bin/env python3
"""Merge AUS per-point CSVs of one PMT, recompute relative columns, make plots.

  python3 runners/aus_merge_plot.py <processed>/scan_.../<PMT> <PMT>

Reads  <PMT>/thetaX_phiY/charge/csv/aus_charge_results.csv and <PMT>/thetaX_phiY/time/csv/aus_results.csv
Writes <PMT>/charge/aus_charge_results.csv, <PMT>/time/aus_results.csv and for every quantity Q
       (charge: gain, relative_gain;  time: relative_QE, arrival_time, TTS, late_fraction) three plots:
         Q_<PMT>.png        x = phi (-180..180 deg), one line per theta ring  (theta = 0: reference point)
         Q_map_<PMT>.png    polar map: angle = phi, radius = theta, colour = value (value written in the marker)
         Q_theta_<PMT>.png  x = theta, mean over phi of each ring (error bar = spread of the ring) + every point
gain = gain_pedestal_subtracted (if present), TTS = FWHM_signal (prompt EMG, if present)
relative values: point / reference point (theta = 0, phi = 0; otherwise the first theta = 0 point).
  *_err      = uncertainty of the point only (the reference itself has 0)
  *_ref_err  = relative uncertainty of the reference (common to every point, written in the plot title)
phi is drawn in -180..180 (225 -> -135); the CSV keeps the phi of the DAQ.
"""
import logging
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap, TwoSlopeNorm, Normalize  # noqa: E402

logging.basicConfig(level=logging.INFO, format="[%(asctime)s][merge_plot][%(levelname)s] %(message)s")
log = logging.getLogger("merge_plot")

pmt_dir = Path(sys.argv[1])
serial = sys.argv[2]
SCAN = pmt_dir.parent.name

# theta rings: fixed colour order (validated categorical order), theta = 0 is the black reference
RING_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
RING_MARKERS = ["o", "s", "^", "D", "v", "P", "X", "h"]
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e1e0d9"
DIVERGING = LinearSegmentedColormap.from_list("bo", ["#1c5cab", "#86b6ef", "#f0efec", "#f3a585", "#b8401a"])
SEQUENTIAL = LinearSegmentedColormap.from_list("blue", ["#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"])
plt.rcParams.update({"font.size": 10, "axes.edgecolor": "#c3c2b7", "axes.labelcolor": INK2,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.titlesize": 11})


def load(sub, name):
    dfs = []
    for f in sorted(pmt_dir.glob("theta*_phi*/{}/csv/{}".format(sub, name))):
        try:
            dfs.append(pd.read_csv(f))
        except Exception as exc:
            log.warning("cannot read %s: %s", f, exc)
    if not dfs:
        return None
    df = pd.concat(dfs, ignore_index=True)
    df["theta"] = pd.to_numeric(df["theta"], errors="coerce")
    df["phi"] = pd.to_numeric(df["phi"], errors="coerce")
    df = df.sort_values(["theta", "phi"]).drop_duplicates(["theta", "phi"], keep="last")
    return df.reset_index(drop=True)


def phi180(phi):
    p = np.mod(np.asarray(phi, dtype=float) + 180.0, 360.0) - 180.0
    return np.where(np.isclose(p, -180.0), 180.0, p)


def ref_index(df):
    z = df.index[np.isclose(df["theta"], 0)]
    if len(z) == 0:
        return None
    z0 = [i for i in z if np.isclose(phi180(df.at[i, "phi"]), 0)]
    return z0[0] if z0 else z[0]


def col(df, name):
    return pd.to_numeric(df[name], errors="coerce").to_numpy(dtype=float) if name in df.columns \
        else np.full(len(df), np.nan)


def relative(df, value, err, ref, out):
    """df[out] = value / value(ref); df[out_err] = point-only error; df[out_ref_err] = rel. error of ref."""
    v, e = np.asarray(value, float), np.asarray(err, float)
    if ref is None or not np.isfinite(v[ref]) or v[ref] == 0:
        df[out], df[out + "_err"], df[out + "_ref_err"] = np.nan, np.nan, np.nan
        return
    with np.errstate(divide="ignore", invalid="ignore"):
        r = v / v[ref]
        df[out] = r
        df[out + "_err"] = np.abs(r) * np.abs(e / v)
        df[out + "_ref_err"] = abs(e[ref] / v[ref])
    df.loc[ref, out + "_err"] = 0.0


def rings(df):
    return sorted(t for t in df["theta"].dropna().unique())


def title(what, df, y, rel_ref_err=None):
    t = "{}  {}  ({})".format(serial, what, SCAN)
    if rel_ref_err is not None and np.isfinite(rel_ref_err):
        t += "\nreference theta=0: ±{:.1f} % (common to all points, not in the error bars)".format(100 * rel_ref_err)
    return t


def plot_set(out_dir, df, y_col, e_col, y_label, what, stem, relative_plot):
    y = col(df, y_col)
    if not np.isfinite(y).any():
        log.warning("skip %s: no values in %s", stem, y_col)
        return
    e = col(df, e_col) if e_col else np.full(len(df), np.nan)
    th, ph = df["theta"].to_numpy(float), phi180(df["phi"])
    ref_err = None
    if relative_plot and (y_col + "_ref_err") in df.columns:
        r = pd.to_numeric(df[y_col + "_ref_err"], errors="coerce").dropna()
        ref_err = float(r.iloc[0]) if len(r) else None
    ok = np.isfinite(y)
    ring_list = [t for t in rings(df) if not np.isclose(t, 0)]
    color = {t: RING_COLORS[i % len(RING_COLORS)] for i, t in enumerate(ring_list)}
    marker = {t: RING_MARKERS[i % len(RING_MARKERS)] for i, t in enumerate(ring_list)}
    out_dir = Path(out_dir)

    # ---- 1. x = phi, one line per theta ring
    fig, ax = plt.subplots(figsize=(9, 5.2))
    for t in ring_list:
        m = np.isclose(th, t) & ok
        if not m.any():
            continue
        o = np.argsort(ph[m])
        ax.errorbar(ph[m][o], y[m][o], yerr=np.nan_to_num(e[m][o]) if e_col else None, color=color[t],
                    marker=marker[t], ms=5, lw=1.6, capsize=2.5, elinewidth=1, label="theta = {:g} deg".format(t))
    m0 = np.isclose(th, 0) & ok
    if m0.any():
        ax.errorbar(ph[m0], y[m0], yerr=np.nan_to_num(e[m0]) if e_col else None, color=INK, marker="*", ms=11,
                    lw=0, elinewidth=1, capsize=2.5, label="theta = 0 deg" + (" (reference)" if relative_plot else ""))
    if relative_plot:
        ax.axhline(1.0, color="#898781", lw=1, ls="--", zorder=0)
    ax.set_xlim(-185, 185)
    ax.set_xticks(np.arange(-180, 181, 45))
    ax.set_xlabel("phi (deg)")
    ax.set_ylabel(y_label)
    ax.grid(True, color=GRID, lw=0.8)
    ax.set_title(title(what, df, y_col, ref_err))
    ax.legend(fontsize=9, ncol=2 if len(ring_list) > 4 else 1, frameon=False)
    fig.tight_layout()
    fig.savefig(out_dir / "{}_{}.png".format(stem, serial), dpi=130)
    plt.close(fig)

    # ---- 2. polar map
    fig = plt.figure(figsize=(7.2, 6.6))
    ax = fig.add_subplot(projection="polar")
    if relative_plot:
        d = np.nanmax(np.abs(y[ok] - 1.0)) if ok.any() else 0.1
        d = float(np.clip(d, 0.02, 0.5))
        norm = TwoSlopeNorm(vcenter=1.0, vmin=1.0 - d, vmax=1.0 + d)
        cmap = DIVERGING
    else:
        lo, hi = np.nanmin(y[ok]), np.nanmax(y[ok])
        if hi <= lo:
            hi = lo + (abs(lo) * 0.01 or 1.0)
        norm, cmap = Normalize(vmin=lo, vmax=hi), SEQUENTIAL
    rmax = max(90.0, np.nanmax(th) + 5)
    sc = ax.scatter(np.radians(ph[ok]), th[ok], c=y[ok], cmap=cmap, norm=norm, s=330,
                    edgecolors="#fcfcfb", linewidths=1.5, zorder=3)
    fmt = "{:.2f}" if relative_plot else ("{:.3g}" if np.nanmax(np.abs(y[ok])) < 1e3 else "{:.2e}")
    for a, r, v in zip(np.radians(ph[ok]), th[ok], y[ok]):
        rgba = cmap(norm(v))
        lum = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2]
        ax.text(a, r, fmt.format(v), ha="center", va="center", fontsize=5.6, zorder=4,
                color="#0b0b0b" if lum > 0.55 else "#ffffff")
    ax.set_theta_zero_location("E")
    ax.set_theta_direction(1)
    ax.set_rlim(0, rmax)
    ax.set_rticks([t for t in ring_list if t <= rmax])
    ax.set_rlabel_position(-22.5)
    ax.tick_params(axis="y", labelsize=8, colors="#898781")
    ax.set_thetagrids(np.arange(0, 360, 45), ["0", "45", "90", "135", "180", "-135", "-90", "-45"])
    ax.grid(color=GRID)
    cb = fig.colorbar(sc, ax=ax, shrink=0.75, pad=0.08)
    cb.set_label(y_label)
    ax.set_title(title(what, df, y_col, ref_err) + "\nangle = phi (deg), radius = theta (deg)", fontsize=10)
    fig.tight_layout()
    fig.savefig(out_dir / "{}_map_{}.png".format(stem, serial), dpi=130)
    plt.close(fig)

    # ---- 3. x = theta: every point + mean of each ring (error bar = standard deviation over phi)
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.scatter(th[ok], y[ok], s=14, color="#9ec5f4", zorder=2, label="every (theta, phi) point")
    mt, mm, ms = [], [], []
    for t in rings(df):
        m = np.isclose(th, t) & ok
        if m.any():
            mt.append(t); mm.append(np.mean(y[m])); ms.append(np.std(y[m]) if m.sum() > 1 else 0.0)
    ax.errorbar(mt, mm, yerr=ms, color="#2a78d6", marker="o", ms=6, lw=2, capsize=3, zorder=3,
                label="mean over phi  (bar: spread over phi)")
    if relative_plot:
        ax.axhline(1.0, color="#898781", lw=1, ls="--", zorder=0)
    ax.set_xlabel("theta (deg)")
    ax.set_ylabel(y_label)
    ax.grid(True, color=GRID, lw=0.8)
    ax.set_title(title(what, df, y_col, ref_err))
    ax.legend(fontsize=9, frameon=False)
    fig.tight_layout()
    fig.savefig(out_dir / "{}_theta_{}.png".format(stem, serial), dpi=130)
    plt.close(fig)
    log.info("plot -> %s/{%s,%s_map,%s_theta}_%s.png", out_dir, stem, stem, stem, serial)


# ---- charge: gain, relative gain
dfc = load("charge", "aus_charge_results.csv")
if dfc is not None:
    ref = ref_index(dfc)
    if ref is None:
        log.warning("charge: theta = 0 not analysed yet -> relative gain is NaN")
    gcol = "gain_pedestal_subtracted" if "gain_pedestal_subtracted" in dfc.columns else "gain"
    gerr = gcol + "_err"
    relative(dfc, col(dfc, gcol), col(dfc, gerr), ref, "relative_gain")
    out = pmt_dir / "charge"
    out.mkdir(parents=True, exist_ok=True)
    dfc.to_csv(out / "aus_charge_results.csv", index=False)
    log.info("charge: %d point(s) -> %s", len(dfc), out / "aus_charge_results.csv")
    plot_set(out, dfc, gcol, gerr if gerr in dfc.columns else "",
             "Gain" + (" (pedestal subtracted)" if gcol != "gain" else ""), "Gain", "gain", False)
    plot_set(out, dfc, "relative_gain", "relative_gain_err", "Relative gain", "Relative gain", "relative_gain", True)
else:
    log.info("charge: no point CSV yet")

# ---- time: relative QE (relative_de), arrival time, TTS (FWHM), late fraction
dft = load("time", "aus_results.csv")
if dft is not None:
    ref = ref_index(dft)
    if ref is None:
        log.warning("time: theta = 0 not analysed yet -> relative QE is NaN")
    sy, se = col(dft, "sig_yield"), col(dft, "sig_err")
    relative(dft, sy, se, ref, "rel_yield")
    use_sipm = np.isfinite(col(dft, "sipm_sig_yield")).any()
    if use_sipm:
        py, pe = col(dft, "sipm_sig_yield"), col(dft, "sipm_sig_err")
        relative(dft, py, pe, ref, "rel_sipm_yield")
        with np.errstate(divide="ignore", invalid="ignore"):
            ratio = sy / py
            ratio_err = np.abs(ratio) * np.sqrt((se / sy) ** 2 + (pe / py) ** 2)
        relative(dft, ratio, ratio_err, ref, "relative_norm")
        src = "relative_norm"
    else:
        dft["relative_norm"], dft["relative_norm_err"], dft["relative_norm_ref_err"] = np.nan, np.nan, np.nan
        src = "rel_yield"
    dft["relative_de"] = dft[src]
    dft["relative_de_err"] = dft[src + "_err"]
    dft["relative_de_ref_err"] = dft[src + "_ref_err"]
    out = pmt_dir / "time"
    out.mkdir(parents=True, exist_ok=True)
    dft.to_csv(out / "aus_results.csv", index=False)
    log.info("time: %d point(s) -> %s  (SiPM normalised: %s)", len(dft), out / "aus_results.csv", use_sipm)
    plot_set(out, dft, "relative_de", "relative_de_err", "Relative QE" + (" (SiPM normalized)" if use_sipm else ""),
             "Relative QE (prompt EMG yield)", "relative_QE", True)
    plot_set(out, dft, "mu", "mu_err", "Arrival time (ns)  [PMT - laser trigger, EMG mu]", "Arrival time",
             "arrival_time", False)
    tcol = "FWHM_signal" if "FWHM_signal" in dft.columns else "FWHM"
    plot_set(out, dft, tcol, "", "TTS FWHM (ns)",
             "TTS (FWHM of the prompt EMG)" if tcol != "FWHM" else "TTS (FWHM of the timing fit)", "TTS", False)
    if "late_fraction" in dft.columns:
        plot_set(out, dft, "late_fraction", "", "Late-pulse fraction  N_late / (N_prompt + N_late)",
                 "Late-pulse fraction", "late_fraction", False)
else:
    log.info("time: no point CSV yet")
print("MERGE_PLOT_DONE")
