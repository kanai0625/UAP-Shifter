#!/usr/bin/env python3
"""
SiPM waveform distributions (2D histogram: time vs corrected waveform, all waveforms overlaid).

Three plots (same binning, same definitions as aus_raw2root.py: baseline = mean of the
first 40 samples, V = (ADC - baseline) * 2000/16384 mV, positive pulses):
  sipm_wfdist_10pct.png      10 % of the events  (every 10th event, --frac)
  sipm_wfdist_100pct.png     100 % of the events
  sipm_wfdist_vthr100mV.png  events whose waveform exceeds VTHR = 100 mV anywhere (of the 100 %)
  sipm_wfdist.npz            the three histograms (time edges, voltage edges, counts)
  sipm_wfdist_summary.txt    numbers of events

"the events" = the first --nevent events of the file (0 = every event in the file).

Example:
  python3 runners/aus_sipm_wfdist.py \\
     --input-dir /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B/wavesave_theta0_phi0 \\
     --out-dir ./output/sipm_wfdist
"""

import argparse
import time
from pathlib import Path

import numpy as np

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LogNorm  # noqa: E402

import aus_raw2root as rw  # same directory (runners/)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-dir", help=".../wavesave_thetaX_phiY")
    ap.add_argument("--file", help="explicit waveN.dat (instead of --input-dir)")
    ap.add_argument("--ch", type=int, default=1, help="channel (default 1 = SiPM)")
    ap.add_argument("--nevent", type=int, default=0, help="events used (0 = all in the file)")
    ap.add_argument("--frac", type=float, default=10.0, help="percent of the events for the first plot (10)")
    ap.add_argument("--vthr", type=float, default=100.0, help="threshold [mV] for the third plot (100)")
    ap.add_argument("--vmin", type=float, default=None, help="voltage axis min [mV] (default: from data)")
    ap.add_argument("--vmax", type=float, default=None, help="voltage axis max [mV] (default: from data)")
    ap.add_argument("--nbins-v", type=int, default=300, help="voltage bins")
    ap.add_argument("--chunk", type=int, default=20000, help="events processed at once (memory)")
    ap.add_argument("--out-dir", default="./output/sipm_wfdist")
    ap.add_argument("--prefix", default="", help="file name prefix, e.g. theta0_phi0_")
    a = ap.parse_args()

    path = Path(a.file) if a.file else Path(a.input_dir) / "wave{}.dat".format(a.ch)
    t0 = time.time()
    raw, rl, n_all = rw.read_dat(path, a.nevent)
    n = raw.shape[0]
    step = max(1, int(round(100.0 / a.frac)))
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    # voltage range from the first chunk unless given
    _, v0, _ = rw.process_channel(raw[: min(n, a.chunk)], a.ch)
    vmin = a.vmin if a.vmin is not None else min(float(np.percentile(v0, 0.01)) * 1.2, -5.0)
    vmax = a.vmax if a.vmax is not None else max(float(v0.max()) * 1.05, 1.5 * a.vthr)
    del v0
    t_edges = (np.arange(rl + 1) - 0.5) * 2.0                     # ns, one bin per sample
    v_edges = np.linspace(vmin, vmax, a.nbins_v + 1)
    nb = a.nbins_v
    hists = {k: np.zeros(rl * nb, np.int64) for k in ("frac", "all", "vthr")}
    nsel = {"frac": 0, "all": 0, "vthr": 0}

    for i0 in range(0, n, a.chunk):
        _, v, _ = rw.process_channel(raw[i0:i0 + a.chunk], a.ch)
        m = v.shape[0]
        vb = np.clip(((v - vmin) / (vmax - vmin) * nb).astype(np.int64), -1, nb)
        ok = (vb >= 0) & (vb < nb)                                  # outside the axis: not counted
        flat = (np.arange(rl)[None, :] * nb + np.clip(vb, 0, nb - 1))
        ev = np.arange(i0, i0 + m)
        sel = {"all": np.ones(m, bool), "frac": (ev % step) == 0, "vthr": v.max(axis=1) > a.vthr}
        for k, s in sel.items():
            if s.any():
                w = ok[s]
                hists[k] += np.bincount(flat[s][w], minlength=rl * nb)
                nsel[k] += int(s.sum())

    titles = {"frac": ("sipm_wfdist_{:g}pct.png".format(a.frac),
                       "{:g} % of the events (every {}th): {} waveforms".format(a.frac, step, nsel["frac"])),
              "all": ("sipm_wfdist_100pct.png", "100 % of the events: {} waveforms".format(nsel["all"])),
              "vthr": ("sipm_wfdist_vthr{:g}mV.png".format(a.vthr),
                       "max > {:g} mV: {} waveforms ({:.2%} of {})".format(a.vthr, nsel["vthr"],
                                                                         nsel["vthr"] / max(n, 1), n))}
    for k, (fname, title) in titles.items():
        h = hists[k].reshape(rl, nb).T
        fig, ax = plt.subplots(figsize=(11, 5.5))
        if h.sum() > 0:
            pm = ax.pcolormesh(t_edges, v_edges, np.where(h > 0, h, np.nan), norm=LogNorm(vmin=1, vmax=h.max()),
                               cmap="viridis", shading="flat")
            fig.colorbar(pm, ax=ax, label="entries")
        else:
            ax.text(0.5, 0.5, "no waveform", transform=ax.transAxes, ha="center")
        if k == "vthr":
            ax.axhline(a.vthr, color="red", lw=0.8, ls="--", label="{:g} mV".format(a.vthr))
            ax.legend(loc="upper right")
        ax.set_xlim(t_edges[0], t_edges[-1])
        ax.set_xlabel("time (ns)")
        ax.set_ylabel("corrected waveform (mV)")
        ax.set_title("ch{}  {}   {}".format(a.ch, path.parent.name, title), fontsize=10)
        fig.tight_layout()
        fig.savefig(out / (a.prefix + fname), dpi=120)
        plt.close(fig)

    np.savez_compressed(out / (a.prefix + "sipm_wfdist.npz"), t_edges=t_edges, v_edges=v_edges,
                        **{k: hists[k].reshape(rl, nb) for k in hists}, **{"n_" + k: nsel[k] for k in nsel})
    text = ("file {}  ({} events in file, {} used, record {} ns)\n"
            "10%: every {}th event -> {} waveforms\n100%: {} waveforms\n"
            "max > {:g} mV: {} waveforms ({:.2%})\nvoltage axis {:.1f} .. {:.1f} mV, {:.1f} s").format(
        path, n_all, n, rl * 2, step, nsel["frac"], nsel["all"], a.vthr, nsel["vthr"],
        nsel["vthr"] / max(n, 1), vmin, vmax, time.time() - t0)
    (out / (a.prefix + "sipm_wfdist_summary.txt")).write_text(text + "\n")
    print(text)
    print("-> {}/{}".format(out, ", ".join(a.prefix + v[0] for v in titles.values())))


if __name__ == "__main__":
    main()
