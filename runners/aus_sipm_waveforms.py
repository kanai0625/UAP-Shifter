#!/usr/bin/env python3
"""
Plot SiPM waveforms: 100 events, one every 100 events (event 0, 100, 200, ..., 9900).

Uses the same definitions as aus_raw2root.py (pedestal window, baseline,
sigma, pulse start = first sample > NSIGMA * sigma, window [PS-10, PS+50)), and draws
them on every waveform so the pulse-start definition can be checked by eye.

Output (in --out-dir):
  sipm_waveforms_grid.png     10 x 10 panels, one event each (corrected waveform, mV)
  sipm_waveforms_overlay.png  all 100 waveforms on one plot
  sipm_waveforms_events.csv   event, baseline, sigma, threshold, PulseStart, PeakHeight, PulseCharge
  (--each)  ev<NNNNN>.png      one file per event

Example:
  python3 runners/aus_sipm_waveforms.py \
     --input-dir /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B/wavesave_theta0_phi0 \
     --out-dir ./output/sipm_waveforms
"""

import argparse
import csv
from pathlib import Path

import numpy as np

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

import aus_raw2root as rw  # same directory (runners/)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-dir", help=".../wavesave_thetaX_phiY")
    ap.add_argument("--file", help="explicit waveN.dat (instead of --input-dir)")
    ap.add_argument("--ch", type=int, default=1, help="channel (default 1 = SiPM)")
    ap.add_argument("--n", type=int, default=100, help="number of waveforms")
    ap.add_argument("--step", type=int, default=100, help="plot every STEP-th event")
    ap.add_argument("--first", type=int, default=0, help="first event")
    ap.add_argument("--nsigma", type=float, default=2.2)
    ap.add_argument("--nconsec", type=int, default=1)
    ap.add_argument("--out-dir", default="./output/sipm_waveforms")
    ap.add_argument("--prefix", default="", help="file name prefix, e.g. theta0_phi0_")
    ap.add_argument("--each", action="store_true", help="also one PNG per event")
    a = ap.parse_args()

    path = Path(a.file) if a.file else Path(a.input_dir) / "wave{}.dat".format(a.ch)
    need = a.first + a.step * (a.n - 1) + 1
    raw, rl, n_all = rw.read_dat(path, need)
    sel = np.arange(a.first, min(need, raw.shape[0]), a.step)[: a.n]
    d, v, meta = rw.process_channel(raw[sel], a.ch, nsigma=a.nsigma, nconsec=a.nconsec)
    t = np.arange(rl) * 2.0
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    p0, p1 = meta["pedestal"]
    print("file {}  ({} events, record {} ns)  plotting {} events: {} ... {}".format(
        path, n_all, rl * 2, sel.size, sel[0], sel[-1]))

    def draw(ax, i, small=True):
        ax.plot(t, v[i], lw=0.6 if small else 1.0, color="k")
        ax.axvspan(p0 * 2, p1 * 2, color="tab:blue", alpha=0.12)
        ax.axhline(d["Threshold"][i], color="tab:red", lw=0.6, ls="--")
        ax.axhline(0, color="gray", lw=0.4)
        ps = d["PulseStart"][i]
        if np.isfinite(ps):
            ax.axvline(ps * 2, color="tab:red", lw=0.8)
            ax.axvspan(d["WindowStart"][i] * 2, d["WindowStop"][i] * 2, color="tab:orange", alpha=0.12)
            ax.plot(d["PeakLocation"][i] * 2, d["PeakHeight"][i], "v", color="tab:green", ms=3 if small else 6)
        if small:
            ax.set_title("ev {}".format(sel[i]), fontsize=6, pad=1)
            ax.tick_params(labelsize=5, length=2, pad=1)
        else:
            ax.set_title("ch{} event {}   PulseStart {:.0f} ns   PeakHeight {:.2f} mV   charge {:.3f} pC".format(
                a.ch, sel[i], ps * 2 if np.isfinite(ps) else np.nan, d["PeakHeight"][i], d["PulseCharge"][i]))
            ax.set_xlabel("time (ns)")
            ax.set_ylabel("corrected waveform (mV)")

    ncol = 10
    nrow = int(np.ceil(sel.size / ncol))
    fig, axes = plt.subplots(nrow, ncol, figsize=(2.2 * ncol, 1.6 * nrow), sharex=True)
    for i, ax in enumerate(np.ravel(axes)):
        if i < sel.size:
            draw(ax, i)
        else:
            ax.axis("off")
    fig.suptitle("ch{}  {}  (blue: pedestal window, red dashed: {}σ threshold, red: PulseStart, "
                 "orange: peak/charge window)".format(a.ch, path.parent.name, a.nsigma), fontsize=10)
    fig.tight_layout(rect=(0, 0, 1, 0.98))
    fig.savefig(out / (a.prefix + "sipm_waveforms_grid.png"), dpi=110)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(10, 5))
    for i in range(sel.size):
        ax.plot(t, v[i], lw=0.5, alpha=0.5)
    ax.axvspan(p0 * 2, p1 * 2, color="tab:blue", alpha=0.12, label="pedestal window")
    ax.set_xlabel("time (ns)")
    ax.set_ylabel("corrected waveform (mV)")
    ax.set_title("ch{}  {}  {} events (every {})".format(a.ch, path.parent.name, sel.size, a.step))
    ax.legend()
    fig.tight_layout()
    fig.savefig(out / (a.prefix + "sipm_waveforms_overlay.png"), dpi=120)
    plt.close(fig)

    if a.each:
        for i in range(sel.size):
            fig, ax = plt.subplots(figsize=(9, 4))
            draw(ax, i, small=False)
            fig.tight_layout()
            fig.savefig(out / (a.prefix + "ev{:05d}.png".format(sel[i])), dpi=110)
            plt.close(fig)

    with open(out / (a.prefix + "sipm_waveforms_events.csv"), "w", newline="") as fo:
        w = csv.writer(fo)
        keys = ["Baseline", "BaselineStdDev", "Threshold", "PulseStart", "PeakLocation", "PeakHeight", "PulseCharge"]
        w.writerow(["event"] + keys)
        for i in range(sel.size):
            w.writerow([int(sel[i])] + ["{:.4g}".format(d[k][i]) for k in keys])
    print("-> {}/{p}sipm_waveforms_grid.png, {p}sipm_waveforms_overlay.png, {p}sipm_waveforms_events.csv{}".format(
        out, ", ev*.png" if a.each else "", p=a.prefix))


if __name__ == "__main__":
    main()
