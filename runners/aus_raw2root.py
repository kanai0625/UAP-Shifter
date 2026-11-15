#!/usr/bin/env python3
"""
AUS raw2root: WaveDump .dat -> ROOT (replaces the pyrate step).

Output: one ROOT file with Tree_CH<ch> per channel and the branch names UAP root2csv
reads (PulseStart, PeakHeight, PeakLocation, PulseCharge, ...).

Per event and channel
---------------------
1. Pedestal window
     ch0 (laser trigger, its pulse is at ~100 ns): the LAST  PED_LAST  samples (default 30)
     other channels                              : the FIRST PED_FIRST samples (default 40)
   baseline = mean, sigma = standard deviation of the ADC values in that window.
2. Corrected waveform  V[mV] = polarity * (ADC - baseline) * Vpp / 2^bits
     polarity: +1 for ch0 (laser) and ch1 (SiPM), -1 for the PMTs (ch3, ch5, ch7)
     -> pulses are positive, the baseline is 0 mV
3. PulseStart = first sample, looking from right after the pedestal window
   (ch0: from sample 0 up to the pedestal window), where
        V > NSIGMA * sigma          (default NSIGMA = 2.2)
   on NCONSEC consecutive samples (default 1).  No such sample -> NaN.
   PulseStartInterp = the same crossing linearly interpolated between samples.
4. Same windows as the original UAP/pyrate config:
     window = [PulseStart - 10, PulseStart + 50)  (samples, clipped to the record)
     PeakHeight   = max V in the window [mV],  PeakLocation = its sample index
     PulseCharge  = sum of V in the window * dt / R   [pC]
5. pC conversion for CAEN DT5730S (14 bit, 2 Vpp, 500 MS/s, 50 Ohm):
     1 ADC count = 2000 mV / 16384 = 0.1221 mV ;  dt = 2 ns ;  R = 50 Ohm
     -> 1 mV x 1 sample = 1 mV * 2 ns / 50 Ohm = 0.04 pC

Times are in samples (x 2 ns), like pyrate.

--vcut-mv 1.5 --vcut-out FILE: a second ROOT file in which the PMT channels (ch3/5/7) use a FIXED
pulse-height threshold of 1.5 mV above the baseline instead of NSIGMA * sigma:
  events whose largest pulse (max V after the pedestal window) is above 1.5 mV,
  PulseStart = rising edge of that pulse (first sample above 1.5 mV going back from the maximum)
  (--vcut-edge first: first 1.5 mV crossing instead).  PeakHeight / charge in [PS-10, PS+50).
Trigger and SiPM trees are the same as in the main file.  Used for the timing fit.

Example:
  python3 runners/aus_raw2root.py \
     --input-dir /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B/wavesave_theta0_phi0 \
     --nevent 300000 --out ./outputs/output_theta0_phi0.root \
     --vcut-mv 2.0 --vcut-out ./outputs_vcut2.0mV/output_theta0_phi0.root
"""

import argparse
import re
import sys
import time
from pathlib import Path

import numpy as np

FILE_RE = re.compile(r"^wave(?P<ch>\d+)\.dat$", re.IGNORECASE)
HEADER_WORDS = 6
HEADER_BYTES = HEADER_WORDS * 4
POLARITY = {0: +1, 1: +1, 3: -1, 5: -1, 7: -1}   # from R12860_config_dat*.yaml
TRIGGER_CH = 0


# ----------------------------------------------------------------------------- reading
def read_dat(path, nevent=0, record_length=0):
    """Return raw ADC waveforms (n_events, record_length) as uint16 (WaveDump binary)."""
    path = Path(path)
    size = path.stat().st_size
    with path.open("rb") as fi:
        first = np.frombuffer(fi.read(HEADER_BYTES), dtype="<u4")
    ev_bytes = int(first[0]) if first.size == HEADER_WORDS else 0
    has_header = ev_bytes > HEADER_BYTES and (ev_bytes - HEADER_BYTES) % 2 == 0 and size % ev_bytes == 0
    if has_header and size > ev_bytes:
        with path.open("rb") as fi:
            fi.seek(ev_bytes)
            has_header = int(np.frombuffer(fi.read(4), dtype="<u4")[0]) == ev_bytes
    if has_header:
        rl = (ev_bytes - HEADER_BYTES) // 2
        n_all = size // ev_bytes
        dtype = np.dtype([("hdr", "<u4", (HEADER_WORDS,)), ("wf", "<u2", (rl,))])
        mm = np.memmap(path, dtype=dtype, mode="r", shape=(n_all,))
        n = n_all if nevent <= 0 else min(nevent, n_all)
        return np.asarray(mm["wf"][:n]), rl, n_all
    if not record_length:
        raise ValueError("{}: no WaveDump header; give --record-length".format(path))
    rl = int(record_length)
    n_all = size // (2 * rl)
    mm = np.memmap(path, dtype="<u2", mode="r", shape=(n_all, rl))
    n = n_all if nevent <= 0 else min(nevent, n_all)
    return np.asarray(mm[:n]), rl, n_all


def find_channels(input_dir):
    out = {}
    for p in sorted(Path(input_dir).iterdir()):
        m = FILE_RE.match(p.name)
        if m:
            out[int(m.group("ch"))] = p
    return dict(sorted(out.items()))


# ----------------------------------------------------------------------------- processing
def pedestal_window(ch, rl, ped_first=40, ped_last=30):
    """(start, stop) of the pedestal window and (start, stop) of the pulse-start search."""
    if ch == TRIGGER_CH:
        return (rl - ped_last, rl), (0, rl - ped_last)
    return (0, ped_first), (ped_first, rl)


def process_channel(raw, ch, nsigma=2.2, nconsec=1, ped_first=40, ped_last=30,
                    win_pre=10, win_post=50, vpp=2.0, bits=14, dt_ns=2.0, impedance=50.0, thr_mv=None,
                    edge="first"):
    """Return dict of per-event arrays for one channel (+ the corrected waveform).
    thr_mv: fixed threshold in mV above the baseline instead of nsigma * sigma (e.g. 1.5).
    edge  : "first" = first threshold crossing in the search range
            "max"   = rising edge of the LARGEST pulse: events whose maximum is above the threshold,
                      PulseStart = first sample above the threshold going back from the maximum"""
    n, rl = raw.shape
    mv_per_adc = vpp * 1000.0 / float(2 ** bits)
    pol = POLARITY.get(ch, +1)
    (p0, p1), (s0, s1) = pedestal_window(ch, rl, ped_first, ped_last)

    adc = raw.astype(np.float64)
    ped = adc[:, p0:p1]
    base = ped.mean(axis=1)
    sd = ped.std(axis=1)
    v = pol * (adc - base[:, None]) * mv_per_adc              # mV, pulse positive, baseline 0
    sd_mv = sd * mv_per_adc
    thr = nsigma * sd_mv if thr_mv is None else np.full(n, float(thr_mv))   # mV above baseline

    # first sample in [s0, s1) with V > thr on nconsec consecutive samples
    seg = v[:, s0:s1] > thr[:, None]
    if nconsec > 1:
        c = np.cumsum(np.pad(seg.astype(np.int32), ((0, 0), (1, 0))), axis=1)
        k = nconsec
        run = (c[:, k:] - c[:, :-k]) == k                     # run[i] = seg[i:i+k] all True
        seg = np.zeros_like(seg)
        seg[:, :run.shape[1]] = run
    if edge == "max":
        vs = v[:, s0:s1]
        imax = np.argmax(vs, axis=1)
        has = vs[np.arange(n), imax] > thr
        below = (vs <= thr[:, None]) & (np.arange(s1 - s0)[None, :] < imax[:, None])
        anyb = below.any(axis=1)
        lastb = (s1 - s0 - 1) - np.argmax(below[:, ::-1], axis=1)       # last sample below thr before max
        first = np.where(anyb, lastb + 1, 0) + s0
    else:
        has = seg.any(axis=1)
        first = np.argmax(seg, axis=1) + s0
    ps = np.where(has, first, np.nan).astype(np.float64)

    # interpolated crossing between first-1 and first
    ps_interp = ps.copy()
    rows = np.where(has & (first > 0))[0]
    if rows.size:
        i1 = first[rows]
        v1, v0 = v[rows, i1], v[rows, i1 - 1]
        t = thr[rows]
        with np.errstate(divide="ignore", invalid="ignore"):
            frac = np.where(v1 > v0, (t - v0) / (v1 - v0), 1.0)
        ps_interp[rows] = (i1 - 1) + np.clip(frac, 0.0, 1.0)

    # windows [ps - pre, ps + post) clipped to the record
    idx = np.arange(rl)[None, :]
    lo = np.where(has, np.clip(first - win_pre, 0, rl), 0)[:, None]
    hi = np.where(has, np.clip(first + win_post, 0, rl), 0)[:, None]
    inwin = (idx >= lo) & (idx < hi)
    vm = np.where(inwin, v, -np.inf)
    ploc = np.argmax(vm, axis=1).astype(np.float64)
    pheight = vm[np.arange(n), ploc.astype(int)]
    charge = (np.where(inwin, v, 0.0).sum(axis=1)) * dt_ns / impedance   # mV*ns/Ohm = pC
    nan = ~has
    ploc[nan] = np.nan
    pheight = np.where(nan, np.nan, pheight)
    charge = np.where(nan, np.nan, charge)

    out = {
        "PulseStart": ps,
        "PulseStartInterp": ps_interp,
        "PeakHeight": pheight,
        "PeakLocation": ploc,
        "PulseCharge": charge,
        "Baseline": base,                       # ADC
        "BaselineMV": base * mv_per_adc,        # mV (raw scale, before subtraction)
        "BaselineStdDev": sd_mv,                # mV
        "Threshold": thr,                       # mV above baseline
        "WindowStart": np.where(has, lo[:, 0], np.nan).astype(np.float64),
        "WindowStop": np.where(has, hi[:, 0], np.nan).astype(np.float64),
    }
    meta = {"pedestal": (p0, p1), "search": (s0, s1), "polarity": pol, "mv_per_adc": mv_per_adc}
    return out, v, meta


def summary(ch, d, rl, n):
    ps = d["PulseStart"]
    f = np.isfinite(ps)
    def med(x):
        x = x[np.isfinite(x)]
        return float(np.median(x)) if x.size else float("nan")
    return ("  ch{:<2d} events {:6d}  PulseStart found {:6.2%}  median PulseStart {:7.1f} ns  "
            "median sigma {:5.2f} mV  median PeakHeight {:7.2f} mV  median charge {:7.3f} pC").format(
        ch, n, f.mean(), med(ps) * 2.0, med(d["BaselineStdDev"]), med(d["PeakHeight"]), med(d["PulseCharge"]))


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-dir", required=True, help=".../wavesave_thetaX_phiY (waveN.dat)")
    ap.add_argument("--out", required=True, help="output ROOT file, e.g. .../output_theta0_phi0.root")
    ap.add_argument("--nevent", type=int, default=10000, help="events per channel (0 = all)")
    ap.add_argument("--channels", type=lambda t: [int(c) for c in t.replace(",", " ").split()], default=None,
                    help="e.g. 0,1,5,7 (default: every waveN.dat)")
    ap.add_argument("--nsigma", type=float, default=2.2, help="pulse start threshold in baseline sigma")
    ap.add_argument("--nconsec", type=int, default=1, help="consecutive samples above threshold")
    ap.add_argument("--ped-first", type=int, default=40, help="pedestal samples at the start (not ch0)")
    ap.add_argument("--ped-last", type=int, default=30, help="pedestal samples at the end (ch0)")
    ap.add_argument("--win-pre", type=int, default=10, help="window start = PulseStart - N")
    ap.add_argument("--win-post", type=int, default=50, help="window stop  = PulseStart + N")
    ap.add_argument("--vpp", type=float, default=2.0)
    ap.add_argument("--bits", type=int, default=14)
    ap.add_argument("--record-length", type=int, default=0, help="only for files without header")
    ap.add_argument("--chunk", type=int, default=20000, help="events processed at once (memory)")
    ap.add_argument("--vcut-mv", type=float, default=0.0,
                    help="also write --vcut-out with a FIXED threshold of this many mV for the PMT channels")
    ap.add_argument("--vcut-out", default=None, help="second ROOT file (PMT PulseStart etc. with --vcut-mv)")
    ap.add_argument("--vcut-edge", choices=["max", "first"], default="max",
                    help="max: rising edge of the largest pulse above --vcut-mv (default); first: first crossing")
    a = ap.parse_args()

    try:
        import uproot
    except ImportError:
        sys.exit("uproot is required (activate the UAP conda environment)")

    chans = find_channels(a.input_dir)
    if a.channels:
        chans = {c: p for c, p in chans.items() if c in a.channels}
    if not chans:
        sys.exit("no waveN.dat in {}".format(a.input_dir))
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    print("input : {}\noutput: {}\nchannels: {}  nevent: {}  nsigma: {}  nconsec: {}".format(
        a.input_dir, out, list(chans), a.nevent, a.nsigma, a.nconsec))

    t0 = time.time()
    trees = {}
    vtrees = {}
    do_vcut = a.vcut_mv > 0 and a.vcut_out
    n_common = None
    for ch, path in chans.items():
        raw, rl, n_all = read_dat(path, a.nevent, a.record_length)   # uint16 (2 bytes/sample)
        parts, meta = [], None
        for i0 in range(0, raw.shape[0], a.chunk):                   # chunks keep memory small
            d, _, meta = process_channel(raw[i0:i0 + a.chunk], ch, a.nsigma, a.nconsec, a.ped_first,
                                         a.ped_last, a.win_pre, a.win_post, a.vpp, a.bits)
            parts.append(d)
        d = {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}
        trees[ch] = d
        if do_vcut:
            if POLARITY.get(ch, +1) < 0:                               # PMT channels: fixed threshold
                vp = [process_channel(raw[i0:i0 + a.chunk], ch, a.nsigma, a.nconsec, a.ped_first, a.ped_last,
                                      a.win_pre, a.win_post, a.vpp, a.bits, thr_mv=a.vcut_mv,
                                      edge=a.vcut_edge)[0]
                      for i0 in range(0, raw.shape[0], a.chunk)]
                vtrees[ch] = {k: np.concatenate([p[k] for p in vp]) for k in vp[0]}
            else:                                                       # trigger / SiPM: same as above
                vtrees[ch] = d
        n_common = raw.shape[0] if n_common is None else min(n_common, raw.shape[0])
        print("  ch{}: {} ({} events in file, record {} samples = {} ns, pedestal samples {}..{}, "
              "search {}..{}, polarity {:+d})".format(ch, path.name, n_all, rl, rl * 2, meta["pedestal"][0],
                                                     meta["pedestal"][1], meta["search"][0],
                                                     meta["search"][1], meta["polarity"]))
        print(summary(ch, d, rl, raw.shape[0]))
        if do_vcut and POLARITY.get(ch, +1) < 0:
            print(summary(ch, vtrees[ch], rl, raw.shape[0]) + "   [fixed {:g} mV, {}]".format(
                a.vcut_mv, "edge of the largest pulse" if a.vcut_edge == "max" else "first crossing"))

    outs = [(out, trees)]
    if do_vcut:
        Path(a.vcut_out).parent.mkdir(parents=True, exist_ok=True)
        outs.append((Path(a.vcut_out), vtrees))
    for path, tr in outs:
        with uproot.recreate(str(path)) as f:
            for ch, d in tr.items():
                d = {k: np.asarray(v[:n_common], dtype=np.float64) for k, v in d.items()}
                t = f.mktree("Tree_CH{}".format(ch), {k: np.float64 for k in d})
                t.extend(d)
        print("wrote {} ({} events per channel, {:.1f} s)".format(path, n_common, time.time() - t0))


if __name__ == "__main__":
    main()
