#!/usr/bin/env python3
"""
2D waveform distribution (persistence plot) from CAEN WaveDump binary files.

  x : time (ns)          = sample index * --sample-ns
  y : signal (mV)        = (ADC - baseline) * vpp / 2^bits   (baseline = mean of the first
                           --baseline-samples samples of each event; 0 = no subtraction)
  color : number of waveform points in each (time, signal) bin

One PNG per channel.  All events are used by default (--nevent 0); the file is read
in chunks with numpy.memmap, so memory use stays small even for large files.

Input (one of):
  --input-dir  DIR    every waveN.dat in DIR  (e.g. .../wavesave_theta0_phi0)
  --files      F ...  explicit waveN.dat files

WaveDump binary layout (auto-detected):
  with header : per event 6 x uint32 [event size in bytes, board, pattern, channel,
                event counter, trigger time tag] + record_length x uint16
  no header   : record_length x uint16 per event  (give --record-length)

Examples:
  python3 runners/waveform_2Dplot.py \\
      --input-dir /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_101543/EM5370-B/wavesave_theta0_phi0 \\
      --out-dir   /disk03/hk04/precalib/production/aus/processed/scan_20261108_101543/EM5370-B/waveformdist \\
      --prefix theta0_phi0_
  python3 runners/waveform_2Dplot.py --files wave5.dat --nevent 10000 --out-dir ./wf
"""

import argparse
import logging
import re
import sys
import time
from pathlib import Path

import numpy as np

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LogNorm  # noqa: E402

logger = logging.getLogger("waveform_2Dplot")

FILE_RE = re.compile(r"^wave(?P<ch>\d+)\.dat$", re.IGNORECASE)
ANGLE_RE = re.compile(r"theta(?P<theta>-?\d+)_phi(?P<phi>-?\d+)", re.IGNORECASE)
HEADER_WORDS = 6
HEADER_BYTES = HEADER_WORDS * 4


# ---------------------------------------------------------------------------
# File layout
# ---------------------------------------------------------------------------
def detect_layout(path, record_length=0, header="auto"):
    """Return (has_header, record_length, n_events)."""
    size = path.stat().st_size
    if size == 0:
        raise ValueError("empty file: {}".format(path))

    if header in ("auto", "yes"):
        with path.open("rb") as fi:
            first = np.frombuffer(fi.read(HEADER_BYTES), dtype="<u4")
        ev_bytes = int(first[0]) if first.size == HEADER_WORDS else 0
        ok = ev_bytes > HEADER_BYTES and (ev_bytes - HEADER_BYTES) % 2 == 0 and size % ev_bytes == 0
        if ok and size > ev_bytes:
            # the next event must start with the same event size
            with path.open("rb") as fi:
                fi.seek(ev_bytes)
                second = np.frombuffer(fi.read(4), dtype="<u4")
            ok = second.size == 1 and int(second[0]) == ev_bytes
        if ok:
            rl = (ev_bytes - HEADER_BYTES) // 2
            if record_length and record_length != rl:
                logger.warning("%s: header says record length %d (given %d) -> use %d",
                               path.name, rl, record_length, rl)
            return True, rl, size // ev_bytes
        if header == "yes":
            raise ValueError("{}: no valid WaveDump event header found".format(path))

    if not record_length:
        raise ValueError("{}: no WaveDump header detected; give --record-length".format(path))
    ev_bytes = record_length * 2
    if size % ev_bytes:
        logger.warning("%s: file size %d is not a multiple of %d bytes, last partial event ignored",
                       path.name, size, ev_bytes)
    return False, record_length, size // ev_bytes


def open_events(path, has_header, record_length, n_events):
    if has_header:
        dtype = np.dtype([("hdr", "<u4", (HEADER_WORDS,)), ("wf", "<u2", (record_length,))])
        mm = np.memmap(path, dtype=dtype, mode="r", shape=(n_events,))
        return mm, lambda a, b: mm["wf"][a:b]
    mm = np.memmap(path, dtype="<u2", mode="r", shape=(n_events, record_length))
    return mm, lambda a, b: mm[a:b]


# ---------------------------------------------------------------------------
# Histogram
# ---------------------------------------------------------------------------
def to_mv(raw, mv_per_adc, baseline_samples, invert):
    wf = raw.astype(np.float32)
    if baseline_samples > 0:
        wf -= wf[:, :baseline_samples].mean(axis=1, keepdims=True)
    wf *= mv_per_adc
    if invert:
        wf = -wf
    return wf


def auto_range(sample_mv, margin=0.05):
    lo, hi = np.percentile(sample_mv, [0.001, 99.999])
    lo, hi = min(float(lo), 0.0), max(float(hi), 0.0)
    span = max(hi - lo, 1.0)
    return lo - margin * span, hi + margin * span


def waveform_hist2d(path, args, mv_per_adc):
    has_header, rl, n_all = detect_layout(path, args.record_length, args.header)
    n_use = n_all if args.nevent <= 0 else min(args.nevent, n_all)
    logger.info("%s: %s, record length %d samples (%.1f ns), %d events (use %d)",
                path.name, "header" if has_header else "no header", rl, rl * args.sample_ns, n_all, n_use)
    if n_use == 0:
        raise ValueError("{}: no events".format(path))
    _mm, get = open_events(path, has_header, rl, n_all)

    # signal range
    if args.vmin is not None and args.vmax is not None:
        vmin, vmax = float(args.vmin), float(args.vmax)
    else:
        probe = to_mv(np.asarray(get(0, min(n_use, 5000))), mv_per_adc, args.baseline_samples, args.invert)
        vmin, vmax = auto_range(probe)
        if args.vmin is not None:
            vmin = float(args.vmin)
        if args.vmax is not None:
            vmax = float(args.vmax)
    nv = int(args.vbins)
    dv = (vmax - vmin) / nv

    # time bins: one column per sample (or merged samples with --tbin-samples)
    tb = max(1, int(args.tbin_samples))
    nt = (rl + tb - 1) // tb
    tcol = (np.arange(rl) // tb).astype(np.int64)

    counts = np.zeros(nt * nv, dtype=np.int64)
    n_over = 0
    t0 = time.time()
    for a in range(0, n_use, args.chunk):
        b = min(a + args.chunk, n_use)
        wf = to_mv(np.asarray(get(a, b)), mv_per_adc, args.baseline_samples, args.invert)
        vi = np.floor((wf - vmin) / dv).astype(np.int64)
        inside = (vi >= 0) & (vi < nv)
        n_over += int(inside.size - np.count_nonzero(inside))
        flat = (np.broadcast_to(tcol, vi.shape) * nv + vi)[inside]
        counts += np.bincount(flat, minlength=nt * nv)
        if args.progress and (b == n_use or (a // args.chunk) % 20 == 0):
            logger.info("  %s: %d/%d events  (%.0f s)", path.name, b, n_use, time.time() - t0)

    h = counts.reshape(nt, nv).T  # [signal, time]
    t_edges = np.arange(nt + 1) * tb * args.sample_ns
    v_edges = vmin + np.arange(nv + 1) * dv
    if n_over:
        logger.info("  %s: %d points outside %.1f..%.1f mV (not drawn)", path.name, n_over, vmin, vmax)
    return h, t_edges, v_edges, n_use, rl


def plot_hist(h, t_edges, v_edges, out_png, title, log_color):
    fig, ax = plt.subplots(figsize=(9, 5.5), dpi=130)
    hm = np.ma.masked_where(h <= 0, h)
    norm = LogNorm(vmin=1, vmax=max(int(h.max()), 2)) if log_color else None
    mesh = ax.pcolormesh(t_edges, v_edges, hm, cmap="viridis", norm=norm, shading="flat", rasterized=True)
    cb = fig.colorbar(mesh, ax=ax)
    cb.set_label("Points / bin")
    ax.set_xlabel("Time (ns)")
    ax.set_ylabel("Signal (mV)")
    ax.set_title(title)
    ax.grid(alpha=0.25)
    fig.tight_layout()
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png)
    plt.close(fig)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def collect_files(args):
    files = []
    if args.files:
        files = [Path(f) for f in args.files]
    elif args.input_dir:
        d = Path(args.input_dir)
        if not d.is_dir():
            raise SystemExit("input dir not found: {}".format(d))
        files = sorted((p for p in d.iterdir() if FILE_RE.match(p.name)),
                       key=lambda p: int(FILE_RE.match(p.name).group("ch")))
    else:
        raise SystemExit("give --input-dir or --files")
    out = []
    want = set(args.channels) if args.channels else None
    for f in files:
        m = FILE_RE.match(f.name)
        ch = int(m.group("ch")) if m else None
        if want is not None and ch not in want:
            continue
        if not f.is_file():
            raise SystemExit("file not found: {}".format(f))
        out.append((ch, f))
    if not out:
        raise SystemExit("no waveN.dat files selected")
    return out


def default_label(path):
    # .../scan_X/PMT/wavesave_thetaT_phiP/waveN.dat -> "PMT theta T phi P (scan_X)"
    parts = path.resolve().parts
    label = []
    m = ANGLE_RE.search(path.parent.name)
    if len(parts) >= 3:
        label.append(parts[-3])
    if m:
        label.append("theta {} phi {}".format(m.group("theta"), m.group("phi")))
    if len(parts) >= 4 and parts[-4].startswith("scan_"):
        label.append("({})".format(parts[-4]))
    return " ".join(label)


def main():
    ap = argparse.ArgumentParser(description="2D waveform distribution (time vs signal) from WaveDump binary files.")
    ap.add_argument("--input-dir", help="directory with waveN.dat files (e.g. wavesave_thetaX_phiY)")
    ap.add_argument("--files", nargs="+", help="explicit waveN.dat files")
    ap.add_argument("--channels", type=int, nargs="+", help="only these channels (default: all waveN.dat)")
    ap.add_argument("--out-dir", default=".", help="output directory for PNGs")
    ap.add_argument("--prefix", default="", help="PNG name prefix, e.g. theta0_phi0_  ->  theta0_phi0_ch3.png")
    ap.add_argument("--title", default="", help="title prefix (default: PMT, angle and scan from the path)")
    ap.add_argument("--nevent", "--Nevent", type=int, default=0, help="events per channel (0 = all)")
    ap.add_argument("--record-length", type=int, default=0, help="samples per event (only for files without header)")
    ap.add_argument("--header", choices=["auto", "yes", "no"], default="auto", help="WaveDump event header")
    ap.add_argument("--sample-ns", type=float, default=2.0, help="sampling period in ns (500 MS/s -> 2)")
    ap.add_argument("--vpp", type=float, default=2.0, help="input range in V (same as CorrectedWaveform vpp)")
    ap.add_argument("--adc-bits", type=int, default=14, help="ADC resolution (adcrange = 2^bits)")
    ap.add_argument("--baseline-samples", type=int, default=40, help="baseline = mean of first N samples (0 = off)")
    ap.add_argument("--invert", action="store_true", help="flip the sign of the signal")
    ap.add_argument("--vmin", type=float, default=None, help="signal axis min in mV (default: auto)")
    ap.add_argument("--vmax", type=float, default=None, help="signal axis max in mV (default: auto)")
    ap.add_argument("--vbins", type=int, default=400, help="number of signal bins")
    ap.add_argument("--tbin-samples", type=int, default=1, help="samples per time bin")
    ap.add_argument("--linear", action="store_true", help="linear color scale (default: log)")
    ap.add_argument("--chunk", type=int, default=5000, help="events per read chunk")
    ap.add_argument("--progress", action="store_true", help="print progress")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="[%(asctime)s][waveform_2Dplot][%(levelname)s] %(message)s")
    mv_per_adc = args.vpp * 1000.0 / float(2 ** args.adc_bits)
    out_dir = Path(args.out_dir)
    n_ok = 0
    for ch, f in collect_files(args):
        try:
            h, te, ve, n_use, rl = waveform_hist2d(f, args, mv_per_adc)
        except Exception as exc:  # keep going with the other channels
            logger.error("%s: %s", f, exc)
            continue
        tag = "ch{}".format(ch) if ch is not None else f.stem
        name = "{}{}.png".format(args.prefix, tag)
        title = "{} {}  ({} events)".format(args.title or default_label(f), tag, n_use)
        plot_hist(h, te, ve, out_dir / name, title, log_color=not args.linear)
        logger.info("-> %s", out_dir / name)
        n_ok += 1
    if n_ok == 0:
        sys.exit(1)
    print("WAVEFORM_2DPLOT_DONE {}".format(n_ok))


if __name__ == "__main__":
    main()