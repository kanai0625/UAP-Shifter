#!/usr/bin/env python3
"""Merge AUS per-point CSVs of one PMT, recompute relative columns, make plots.

  python3 runners/aus_merge_plot.py <processed>/scan_.../<PMT> <PMT>

Reads  <PMT>/thetaX_phiY/charge/csv/aus_charge_results.csv and <PMT>/thetaX_phiY/time/csv/aus_results.csv
Writes <PMT>/charge/{aus_charge_results.csv, gain_<PMT>.png, relative_gain_<PMT>.png}
       <PMT>/time/{aus_results.csv, relative_QE_<PMT>.png, arrival_time_<PMT>.png, TTS_<PMT>.png,
                   late_fraction_<PMT>.png}
gain = gain_pedestal_subtracted (if present), TTS = FWHM_signal (prompt EMG, if present)
"""
import logging
import sys
from argparse import Namespace
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))   # UAP-Shifter (uap package)
from uap.fit import common_math as cm  # noqa: E402
import uap.engine.csv2plot as c2p  # noqa: E402

logging.basicConfig(level=logging.INFO, format="[%(asctime)s][merge_plot][%(levelname)s] %(message)s")
log = logging.getLogger("merge_plot")

pmt_dir = Path(sys.argv[1])
serial = sys.argv[2]
# one line per phi value found in the data (any number of phi), colors/markers cycle
COLORS = ["C{}".format(i) for i in range(10)] + ["#{:02x}{:02x}{:02x}".format(*c) for c in (
    (31, 119, 180), (255, 127, 14), (44, 160, 44), (214, 39, 40), (148, 103, 189), (140, 86, 75))]
MARKERS = ("o", "s", "^", "D", "v", "P", "X", "<", ">", "*", "h", "p")


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
    df = df.sort_values(["phi", "theta"]).drop_duplicates(["phi", "theta"], keep="last")
    return df.reset_index(drop=True)


def center(df):
    c = df[(df["theta"] == 0) & (df["phi"] == 0)]
    return None if c.empty else c.iloc[0]


def rel(df, col, err, c, out, out_err):
    df[out] = np.nan
    df[out_err] = np.nan
    if c is None or col not in df.columns:
        return
    v0 = float(c.get(col, np.nan))
    e0 = float(c.get(err, np.nan)) if err in df.columns else np.nan
    df[out] = cm.safe_ratio(df[col].values, v0, logger=log)
    if err in df.columns:
        df[out_err] = cm.safe_ratio_err(df[col].values, df[err].values, v0, e0, logger=log)


def plot(out_dir, csv, y_col, yerr_col, y_label, what, out_name, hline):
    df = pd.read_csv(csv)
    if y_col not in df.columns or not pd.to_numeric(df[y_col], errors="coerce").notna().any():
        log.warning("skip %s: no values in column %s", out_name, y_col)
        return
    base = dict(system="aus", csv=str(csv), phi_col="phi", theta_col="theta",
                y_col=y_col, yerr_col=yerr_col, mode="single_phi",
                flip_sign=False, use_abs_theta=False, use_hamamatsu_angle=False,
                line_style="-", line_width=1.5, marker_size=4.8)
    phis = sorted(int(p) for p in pd.to_numeric(df["phi"], errors="coerce").dropna().unique())
    lines = {}
    for i, phi in enumerate(phis):
        lines["phi{}".format(phi)] = dict(base, label="phi = {} deg".format(phi), phi=phi,
                                          line_color=COLORS[i % len(COLORS)], marker=MARKERS[i % len(MARKERS)])
    if not lines:
        log.warning("skip %s: no phi values", out_name)
        return
    args = Namespace(out_dir=str(out_dir), out_base="",
                     x_label="theta (deg)", y_label=y_label,
                     title="{}  {}  ({})".format(serial, what, pmt_dir.parent.name),
                     x_min=None, x_max=None, y_min=None, y_max=None, hline=hline,
                     out_name=out_name, points_csv=out_name.replace(".png", "_points.csv"),
                     lines=lines, line_order=list(lines))
    try:
        c2p.run(args)
        log.info("plot -> %s", Path(out_dir) / out_name)
    except (SystemExit, Exception) as exc:
        log.warning("plot %s failed: %s", out_name, exc)


ok = True
# ---- charge: gain, relative gain
dfc = load("charge", "aus_charge_results.csv")
if dfc is not None:
    c = center(dfc)
    if c is None:
        log.warning("charge: theta0_phi0 not analysed yet -> relative gain is NaN")
    gcol = "gain_pedestal_subtracted" if "gain_pedestal_subtracted" in dfc.columns else "gain"
    gerr = gcol + "_err"
    rel(dfc, gcol, gerr, c, "relative_gain", "relative_gain_err")
    out = pmt_dir / "charge"
    out.mkdir(parents=True, exist_ok=True)
    csv = out / "aus_charge_results.csv"
    dfc.to_csv(csv, index=False)
    log.info("charge: %d point(s) -> %s", len(dfc), csv)
    plot(out, csv, gcol, gerr if gerr in dfc.columns else "", "Gain" + (" (pedestal subtracted)" if gcol != "gain" else ""),
         "Gain", "gain_{}.png".format(serial), None)
    plot(out, csv, "relative_gain", "relative_gain_err", "Relative gain", "Relative gain",
         "relative_gain_{}.png".format(serial), 1.0)
else:
    log.info("charge: no point CSV yet")

# ---- time: relative QE (relative_de), TTS (FWHM)
dft = load("time", "aus_results.csv")
if dft is not None:
    c = center(dft)
    if c is None:
        log.warning("time: theta0_phi0 not analysed yet -> relative QE is NaN")
    rel(dft, "sig_yield", "sig_err", c, "rel_yield", "rel_yield_err")
    use_sipm = "sipm_sig_yield" in dft.columns and pd.to_numeric(dft["sipm_sig_yield"], errors="coerce").notna().any()
    if use_sipm:
        rel(dft, "sipm_sig_yield", "sipm_sig_err", c, "rel_sipm_yield", "rel_sipm_yield_err")
        dft["_ratio"] = cm.safe_ratio(dft["sig_yield"].values, dft["sipm_sig_yield"].values, logger=log)
        dft["_ratio_err"] = cm.safe_ratio_err(dft["sig_yield"].values, dft["sig_err"].values,
                                              dft["sipm_sig_yield"].values, dft["sipm_sig_err"].values, logger=log)
        c2 = None if c is None else dft[(dft["theta"] == 0) & (dft["phi"] == 0)].iloc[0]
        rel(dft, "_ratio", "_ratio_err", c2, "relative_norm", "relative_norm_err")
        dft = dft.drop(columns=["_ratio", "_ratio_err"])
        dft["relative_de"] = dft["relative_norm"]
        dft["relative_de_err"] = dft["relative_norm_err"]
    else:
        dft["relative_norm"] = np.nan
        dft["relative_norm_err"] = np.nan
        dft["relative_de"] = dft["rel_yield"]
        dft["relative_de_err"] = dft["rel_yield_err"]
    out = pmt_dir / "time"
    out.mkdir(parents=True, exist_ok=True)
    csv = out / "aus_results.csv"
    dft.to_csv(csv, index=False)
    log.info("time: %d point(s) -> %s  (SiPM normalised: %s)", len(dft), csv, use_sipm)
    plot(out, csv, "relative_de", "relative_de_err",
         "Relative QE" + (" (SiPM normalized)" if use_sipm else ""), "Relative QE (prompt EMG yield)",
         "relative_QE_{}.png".format(serial), 1.0)
    plot(out, csv, "mu", "mu_err", "Arrival time (ns)  [PMT - laser trigger, EMG mu]", "Arrival time",
         "arrival_time_{}.png".format(serial), None)
    tcol = "FWHM_signal" if "FWHM_signal" in dft.columns else "FWHM"
    plot(out, csv, tcol, "", "TTS FWHM (ns)", "TTS (FWHM of the prompt EMG)" if tcol != "FWHM" else
         "TTS (FWHM of the timing fit)", "TTS_{}.png".format(serial), None)
    if "late_fraction" in dft.columns:
        plot(out, csv, "late_fraction", "", "Late-pulse fraction  N_late / (N_prompt + N_late)", "Late-pulse fraction",
             "late_fraction_{}.png".format(serial), None)
else:
    log.info("time: no point CSV yet")
print("MERGE_PLOT_DONE")
