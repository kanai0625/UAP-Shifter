#!/usr/bin/env python3
"""AUS: pedestal summary + all-point montages of one PMT (run after aus_merge_plot.py).

  python3 runners/aus_pmt_summary.py <processed>/scan_.../<PMT> <PMT> [--raw-base /disk03/hk04/precalib/production/aus]

Points = <PMT>/thetaX_phiY.  Point number = order of the measurement (time of the raw
<raw-base>/<elec>/scan_.../<PMT>/wavesave_thetaX_phiY/wave0.dat), or theta, phi order without raw data.

<PMT>/pedfit/            pedestal of the charge fit (ped_mean, ped_sigma of thetaX_phiY/charge/csv/aus_charge_results.csv)
    ped_<PMT>.csv                 point, theta, phi, mu, mu_err, sigma, sigma_err
    ped_dist_<PMT>.png            distributions of mu and sigma
    ped_mu_map_<PMT>.png          polar map (angle = phi, radius = theta) of mu
    ped_sigma_map_<PMT>.png       same for sigma
    ped_mu_vs_point_<PMT>.png     mu vs point number
    ped_sigma_vs_point_<PMT>.png  sigma vs point number
<PMT>/allpoints/         every point in one image, 8 x 8 per page (_p2, _p3 ... above 64 points)
    allpoints_charge_<PMT>.png       charge fit (thetaX_phiY/charge/figures, ..._log.png of step 4)
    allpoints_timing_<PMT>.png       timing fit of the PMT (thetaX_phiY/time/figures, not sipm*)
    allpoints_sipm_timing_<PMT>.png  timing fit of the SiPM (thetaX_phiY/time/figures/sipm*)
"""
import argparse
import logging
import re
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap, Normalize  # noqa: E402

logging.basicConfig(level=logging.INFO, format="[%(asctime)s][pmt_summary][%(levelname)s] %(message)s")
log = logging.getLogger("pmt_summary")

INK2, GRID, SERIES = "#52514e", "#e1e0d9", "#2a78d6"
SEQUENTIAL = LinearSegmentedColormap.from_list("blue", ["#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"])
plt.rcParams.update({"font.size": 10, "axes.edgecolor": "#c3c2b7", "axes.labelcolor": INK2,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.titlesize": 11})
PT_RE = re.compile(r"^theta(-?\d+(?:\.\d+)?)_phi(-?\d+(?:\.\d+)?)$")


def phi180(p):
    p = (float(p) + 180.0) % 360.0 - 180.0
    return 180.0 if np.isclose(p, -180.0) else p


def find_points(pmt_dir, serial, raw_base):
    pts = []
    for d in sorted(pmt_dir.iterdir()):
        m = PT_RE.match(d.name)
        if d.is_dir() and m:
            pts.append({"name": d.name, "theta": float(m.group(1)), "phi": float(m.group(2)), "dir": d, "t": np.nan})
    scan = pmt_dir.parent.name
    raws = [p for p in Path(raw_base).glob("*/{}/{}".format(scan, serial))] if raw_base else []
    for p in pts:
        for r in raws:
            w = r / "wavesave_{}".format(p["name"]) / "wave0.dat"
            if w.exists():
                p["t"] = w.stat().st_mtime
                break
    have_t = all(np.isfinite(p["t"]) for p in pts) and pts
    pts.sort(key=(lambda p: p["t"]) if have_t else (lambda p: (p["theta"], phi180(p["phi"]))))
    for i, p in enumerate(pts, 1):
        p["point"] = i
    log.info("%d point(s), order: %s", len(pts), "measurement time (raw wave0.dat)" if have_t else "theta, phi")
    return pts


def label(p):
    return "#{}  θ{:g} φ{:g}".format(p["point"], p["theta"], p["phi"])


def polar_map(values, pts, title, cbar_label, out):
    th = np.array([p["theta"] for p in pts]); ph = np.array([phi180(p["phi"]) for p in pts])
    v = np.asarray(values, float); ok = np.isfinite(v)
    if not ok.any():
        return
    lo, hi = np.nanmin(v[ok]), np.nanmax(v[ok])
    if hi <= lo:
        hi = lo + (abs(lo) * 0.01 or 1e-3)
    norm = Normalize(vmin=lo, vmax=hi)
    fig = plt.figure(figsize=(7.2, 6.6))
    ax = fig.add_subplot(projection="polar")
    sc = ax.scatter(np.radians(ph[ok]), th[ok], c=v[ok], cmap=SEQUENTIAL, norm=norm, s=330,
                    edgecolors="#fcfcfb", linewidths=1.5, zorder=3)
    for a, r, x in zip(np.radians(ph[ok]), th[ok], v[ok]):
        rgba = SEQUENTIAL(norm(x))
        lum = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2]
        ax.text(a, r, "{:.3g}".format(x), ha="center", va="center", fontsize=5.4, zorder=4,
                color="#0b0b0b" if lum > 0.55 else "#ffffff")
    ax.set_theta_zero_location("E")
    ax.set_rlim(0, max(90.0, np.nanmax(th) + 5))
    rings = sorted(t for t in set(th) if t > 0)
    if rings:
        ax.set_rticks(rings)
    ax.set_rlabel_position(-22.5)
    ax.tick_params(axis="y", labelsize=8, colors="#898781")
    ax.set_thetagrids(np.arange(0, 360, 45), ["0", "45", "90", "135", "180", "-135", "-90", "-45"])
    ax.grid(color=GRID)
    cb = fig.colorbar(sc, ax=ax, shrink=0.75, pad=0.08)
    cb.set_label(cbar_label)
    ax.set_title(title + "\nangle = phi (deg), radius = theta (deg)", fontsize=10)
    fig.tight_layout()
    fig.savefig(out, dpi=130)
    plt.close(fig)


def vs_point(df, col, ecol, ylabel, title, out):
    fig, ax = plt.subplots(figsize=(11, 4.6))
    ax.errorbar(df["point"], df[col], yerr=df[ecol].fillna(0), color=SERIES, marker="o", ms=4, lw=1.2,
                capsize=2, elinewidth=1)
    # theta rings in measurement order: dotted line where theta changes
    prev = None
    for _, r in df.iterrows():
        if r["theta"] != prev:
            ax.axvline(r["point"] - 0.5, color="#c3c2b7", lw=0.8, ls=":")
            ax.text(r["point"] - 0.4, 1.0, "θ{:g}".format(r["theta"]), transform=ax.get_xaxis_transform(),
                    fontsize=8, color="#898781", va="bottom")
            prev = r["theta"]
    mean = np.nanmean(df[col])
    ax.axhline(mean, color="#898781", lw=1, ls="--")
    ax.set_xlabel("point (measurement order)")
    ax.set_ylabel(ylabel)
    ax.set_xlim(0.3, len(df) + 0.7)
    ax.grid(True, color=GRID, lw=0.8)
    ax.set_title(title + "   (dashed: mean {:.4g})".format(mean), pad=16)
    fig.tight_layout()
    fig.savefig(out, dpi=130)
    plt.close(fig)


def pedestal(pmt_dir, serial, pts):
    rows = []
    for p in pts:
        f = p["dir"] / "charge" / "csv" / "aus_charge_results.csv"
        r = {"point": p["point"], "theta": p["theta"], "phi": p["phi"],
             "mu": np.nan, "mu_err": np.nan, "sigma": np.nan, "sigma_err": np.nan}
        if f.exists():
            try:
                c = pd.read_csv(f).iloc[-1]
                for k, s in (("mu", "ped_mean"), ("mu_err", "ped_mean_err"), ("sigma", "ped_sigma"),
                             ("sigma_err", "ped_sigma_err")):
                    r[k] = pd.to_numeric(c.get(s, np.nan), errors="coerce")
            except Exception as exc:
                log.warning("cannot read %s: %s", f, exc)
        rows.append(r)
    df = pd.DataFrame(rows)
    out = pmt_dir / "pedfit"
    out.mkdir(parents=True, exist_ok=True)
    df.to_csv(out / "ped_{}.csv".format(serial), index=False)
    if not np.isfinite(df["mu"]).any():
        log.warning("pedestal: no ped_mean in the charge CSVs")
        return
    scan = pmt_dir.parent.name
    head = "{}  pedestal of the charge fit  ({})".format(serial, scan)
    # distributions
    fig, axs = plt.subplots(1, 2, figsize=(11, 4.4))
    for ax, col, xl in ((axs[0], "mu", "pedestal mean mu_ped (pC)"), (axs[1], "sigma", "pedestal sigma sigma_ped (pC)")):
        v = df[col].dropna().to_numpy()
        ax.hist(v, bins=max(8, min(40, len(v))), color=SERIES, edgecolor="#fcfcfb", linewidth=1)
        ax.axvline(np.mean(v), color="#0b0b0b", lw=1, ls="--")
        ax.set_xlabel(xl)
        ax.set_ylabel("points")
        ax.grid(True, axis="y", color=GRID, lw=0.8)
        ax.set_title("mean {:.4g}   std {:.3g}   ({} points)".format(np.mean(v), np.std(v), len(v)), fontsize=10)
    fig.suptitle(head)
    fig.tight_layout()
    fig.savefig(out / "ped_dist_{}.png".format(serial), dpi=130)
    plt.close(fig)
    polar_map(df["mu"], pts, head.replace("pedestal", "pedestal mean mu_ped"), "mu_ped (pC)",
              out / "ped_mu_map_{}.png".format(serial))
    polar_map(df["sigma"], pts, head.replace("pedestal", "pedestal sigma sigma_ped"), "sigma_ped (pC)",
              out / "ped_sigma_map_{}.png".format(serial))
    vs_point(df, "mu", "mu_err", "mu_ped (pC)", head.replace("pedestal", "pedestal mean"),
             out / "ped_mu_vs_point_{}.png".format(serial))
    vs_point(df, "sigma", "sigma_err", "sigma_ped (pC)", head.replace("pedestal", "pedestal sigma"),
             out / "ped_sigma_vs_point_{}.png".format(serial))
    log.info("pedestal -> %s", out)


def pick(files, kind):
    files = sorted(files)
    if kind == "charge":
        best = [f for f in files if f.name.endswith("_log.png") and "step2" not in f.name]
        return (best or [f for f in files if "step2" not in f.name] or files or [None])[0]
    if kind == "sipm":
        return ([f for f in files if f.name.startswith("sipm")] or [None])[0]
    return ([f for f in files if not f.name.startswith("sipm")] or [None])[0]


def montage(pts, kind, title, out_stem, ncol=8, nrow=8):
    from PIL import Image
    sub = "charge" if kind == "charge" else "time"
    per = ncol * nrow
    pages = [pts[i:i + per] for i in range(0, len(pts), per)] or [[]]
    made = []
    for ip, page in enumerate(pages, 1):
        nr = max(1, min(nrow, -(-len(page) // ncol)))          # rows actually needed (53 points -> 7)
        fig, axs = plt.subplots(nr, ncol, figsize=(ncol * 3.0, nr * 2.35 + 0.6), squeeze=False)
        for ax in axs.flat:
            ax.axis("off")
        n_ok = 0
        for ax, p in zip(axs.flat, page):
            f = pick((p["dir"] / sub / "figures").rglob("*.png"), kind)
            ax.set_title(label(p), fontsize=8, color="#0b0b0b", pad=2)
            if f is None:
                ax.text(0.5, 0.5, "no plot", ha="center", va="center", color="#898781", fontsize=9,
                        transform=ax.transAxes)
                continue
            try:
                im = Image.open(f).convert("RGB")
                im.thumbnail((560, 420))
                ax.imshow(np.asarray(im))
                n_ok += 1
            except Exception as exc:
                log.warning("cannot read %s: %s", f, exc)
        fig.suptitle("{}   ({} of {} points{})".format(title, n_ok, len(page),
                     "" if len(pages) == 1 else ", page {}/{}".format(ip, len(pages))), fontsize=15)
        fig.tight_layout(rect=(0, 0, 1, 0.985), h_pad=0.4, w_pad=0.2)
        o = Path("{}{}.png".format(out_stem, "" if ip == 1 else "_p{}".format(ip)))
        fig.savefig(o, dpi=100)
        plt.close(fig)
        made.append(o)
    log.info("montage %s -> %s", kind, ", ".join(m.name for m in made))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pmt_dir")
    ap.add_argument("serial")
    ap.add_argument("--raw-base", default="/disk03/hk04/precalib/production/aus",
                    help="raw data: <raw-base>/<elec>/scan_.../<PMT>/wavesave_thetaX_phiY (measurement order)")
    ap.add_argument("--grid", default="8x8", help="montage columns x rows (default 8x8)")
    a = ap.parse_args()
    pmt_dir, serial = Path(a.pmt_dir).resolve(), a.serial
    ncol, nrow = (int(x) for x in a.grid.lower().split("x"))
    pts = find_points(pmt_dir, serial, a.raw_base)
    if not pts:
        log.warning("no thetaX_phiY folder in %s", pmt_dir)
        print("PMT_SUMMARY_DONE")
        return
    pedestal(pmt_dir, serial, pts)
    out = pmt_dir / "allpoints"
    out.mkdir(parents=True, exist_ok=True)
    scan = pmt_dir.parent.name
    montage(pts, "charge", "{}  charge fit, all points  ({})".format(serial, scan),
            out / "allpoints_charge_{}".format(serial), ncol, nrow)
    montage(pts, "timing", "{}  timing fit (PMT), all points  ({})".format(serial, scan),
            out / "allpoints_timing_{}".format(serial), ncol, nrow)
    montage(pts, "sipm", "{}  timing fit (SiPM), all points  ({})".format(serial, scan),
            out / "allpoints_sipm_timing_{}".format(serial), ncol, nrow)
    print("PMT_SUMMARY_DONE")


if __name__ == "__main__":
    main()
