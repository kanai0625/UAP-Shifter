#!/usr/bin/env python3
"""
AUS: distributions of one point over the FULL record (0-520 ns) + a text summary of the fits.

  python3 runners/aus_point_plots.py --out <point>/plots --root <point>/root/output_theta0_phi0.root \
      --vroot <point>/root_vcut2.0mV/output_theta0_phi0.root --pmt-ch 5 \
      --charge-csv <point>/charge/csv/aus_charge_results.csv --timing-csv <point>/time/csv/aus_results.csv

Writes into --out (file names start with --prefix):
  pulsestart_ch<N>.png      PulseStart of every channel (main ROOT file), 0-520 ns
  delta_t.png               PMT - trigger and SiPM - trigger, -520..520 ns
                            (from --vroot = fixed-threshold PMT timing, if given)
  charge_peakheight.png     PulseCharge / PeakHeight / baseline sigma of every channel (main ROOT file)
  summary.txt               main fit results (charge + timing)
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

SAMPLE_NS = 2.0


def load_root(path):
    import uproot
    f = uproot.open(path)
    out = {}
    for key in f.keys():
        name = key.split(";")[0]
        if name.startswith("Tree_CH"):
            ch = int(name[len("Tree_CH"):])
            out[ch] = {b: np.asarray(f[name][b].array(library="np"), dtype=float) for b in f[name].keys()}
    return dict(sorted(out.items()))


def distributions(trees, vtrees, pmt_ch, pdir, prefix, vlabel):
    for ch in trees:
        ps = trees[ch]["PulseStart"] * SAMPLE_NS
        fig, ax = plt.subplots(figsize=(9, 4))
        ax.hist(ps[np.isfinite(ps)], bins=np.arange(0, 522, 2), histtype="step", label="main")
        if vtrees is not None and ch == pmt_ch and ch in vtrees:
            vps = vtrees[ch]["PulseStart"] * SAMPLE_NS
            ax.hist(vps[np.isfinite(vps)], bins=np.arange(0, 522, 2), histtype="step", label=vlabel)
            ax.legend(fontsize=8)
        ax.set_xlim(0, 520)
        ax.set_yscale("log")
        ax.set_xlabel("PulseStart (ns)")
        ax.set_title("ch{} PulseStart  (found in {:.1%} of {} events)".format(ch, np.isfinite(ps).mean(), ps.size))
        fig.tight_layout()
        fig.savefig(pdir / "{}pulsestart_ch{}.png".format(prefix, ch))
        plt.close(fig)

    src = vtrees if vtrees is not None else trees
    t0 = src[0]["PulseStart"] * SAMPLE_NS
    fig, axes = plt.subplots(2, 1, figsize=(9, 7))
    for ax, ch, name in zip(axes, (pmt_ch, 1), ("PMT", "SiPM")):
        if ch not in src:
            ax.axis("off")
            continue
        dt = src[ch]["PulseStart"] * SAMPLE_NS - t0
        g = dt[np.isfinite(dt)]
        ax.hist(g, bins=np.arange(-520, 522, 2), histtype="step")
        ax.set_xlim(-520, 520)
        ax.set_yscale("log")
        ax.set_xlabel("delta t = PulseStart(ch{}) - PulseStart(ch0)  (ns)".format(ch))
        ax.set_title("{} ch{} - trigger  ({} events){}".format(
            name, ch, g.size, "   [{}]".format(vlabel) if (vtrees is not None and ch == pmt_ch) else ""))
    fig.tight_layout()
    fig.savefig(pdir / "{}delta_t.png".format(prefix))
    plt.close(fig)

    chans = list(trees)
    fig, axes = plt.subplots(len(chans), 3, figsize=(14, 2.8 * len(chans)))
    for row, ch in zip(np.atleast_2d(axes), chans):
        for ax, key, unit in zip(row, ("PulseCharge", "PeakHeight", "BaselineStdDev"), ("pC", "mV", "mV")):
            x = trees[ch][key]
            g = x[np.isfinite(x)]
            if g.size:
                lo, hi = np.percentile(g, [0.05, 99.95])
                ax.hist(g, bins=300, range=(lo, hi if hi > lo else lo + 1), histtype="step")
                ax.set_yscale("log")
            ax.set_title("ch{} {} ({})".format(ch, key, unit), fontsize=9)
    fig.tight_layout()
    fig.savefig(pdir / "{}charge_peakheight.png".format(prefix))
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="output directory of the plots")
    ap.add_argument("--root", required=True, help="main ROOT file (aus_raw2root.py)")
    ap.add_argument("--vroot", default=None, help="fixed-threshold ROOT file (--vcut-out of aus_raw2root.py)")
    ap.add_argument("--vlabel", default="fixed threshold", help="label of --vroot in the plots")
    ap.add_argument("--charge-csv", default=None)
    ap.add_argument("--timing-csv", default=None)
    ap.add_argument("--pmt-ch", type=int, default=5)
    ap.add_argument("--prefix", default="")
    a = ap.parse_args()
    pdir = Path(a.out)
    pdir.mkdir(parents=True, exist_ok=True)

    vtrees = load_root(a.vroot) if a.vroot and Path(a.vroot).is_file() else None
    distributions(load_root(a.root), vtrees, a.pmt_ch, pdir, a.prefix, a.vlabel)

    lines = []
    if a.charge_csv and Path(a.charge_csv).is_file():
        c = pd.read_csv(a.charge_csv)
        cols = [k for k in ("theta", "phi", "fit_status", "n_in_window", "ped_mean", "ped_sigma", "ped_yield",
                            "spe_seed_start", "spe_seed_mean", "step2_spe_mean",
                            "spe_mean", "spe_sigma", "spe_yield", "gain", "gain_pedestal_subtracted",
                            "resolution", "peak_to_valley", "fit_parameters_at_limit") if k in c]
        lines += ["== charge ==", c[cols].T.to_string(header=False)]
    else:
        lines.append("no charge CSV: {}".format(a.charge_csv))
    if a.timing_csv and Path(a.timing_csv).is_file():
        t = pd.read_csv(a.timing_csv)
        cols = [k for k in ("theta", "phi", "fit_status", "fit_model", "window_min", "window_max", "n_in_window",
                            "mu", "mu_err", "sigma", "lambda", "FWHM_signal", "FWHM", "sig_yield", "bkg_yield",
                            "coeff", "late_mu", "late_dmu", "late_sigma", "late_lambda", "late_yield",
                            "late_fraction", "sipm_n_in_window", "sipm_mu", "sipm_sig_yield",
                            "fit_parameters_at_limit") if k in t]
        lines += ["", "== timing ==", t[cols].T.to_string(header=False)]
    else:
        lines.append("no timing CSV: {}".format(a.timing_csv))
    text = "\n".join(lines)
    (pdir / "{}summary.txt".format(a.prefix)).write_text(text + "\n")
    print(text)
    print("\nplots -> {}".format(pdir))


if __name__ == "__main__":
    main()
