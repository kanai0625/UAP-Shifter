#!/usr/bin/env python3
"""AUS daily report (PDF) of the scans of one night.

  python3 runners/aus_daily_report.py [--date YYYYMMDD]      (default: yesterday)

Scans  : <processed>/scan_YYYYMMDD_HHMMSS started between DATE START (09:30) and the next day START.
Pages  : 1  "AUS system DATE daily report": every scan / PMT (PMT #1 / #2 from pmt_ch), events per point, points
         2  environment monitor plot of the next day at ENV_TIME (09:00)
         then 6 pages for every scan / PMT (made by aus_merge_plot.py and aus_pmt_summary.py):
           1 charge fit of all points        <PMT>/allpoints/allpoints_charge_<PMT>.png
           2 timing fit (PMT) of all points  <PMT>/allpoints/allpoints_timing_<PMT>.png
           3 gain map + gain vs theta        <PMT>/charge/gain_map_<PMT>.png, gain_theta_<PMT>.png
           4 relative QE map + vs theta      <PMT>/time/relative_QE_map_<PMT>.png, relative_QE_theta_<PMT>.png
           5 TTS (FWHM) map + vs theta       <PMT>/time/TTS_map_<PMT>.png, TTS_theta_<PMT>.png
           6 timing fit (SiPM) of all points <PMT>/allpoints/allpoints_sipm_timing_<PMT>.png
Output : <out-dir>/AUS_daily_report_DATE.pdf
"""
import argparse
import datetime as dt
import logging
import re
import struct
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from PIL import Image  # noqa: E402

logging.basicConfig(level=logging.INFO, format="[%(asctime)s][daily_report][%(levelname)s] %(message)s")
log = logging.getLogger("daily_report")

A4 = (11.69, 8.27)
INK, INK2, MUTED, GRID = "#0b0b0b", "#52514e", "#898781", "#e1e0d9"
SCAN_RE = re.compile(r"^scan_(\d{8})_(\d{6})$")
PT_RE = re.compile(r"^theta-?\d+(?:\.\d+)?_phi-?\d+(?:\.\d+)?$")
ENV_RE = re.compile(r"(\d{4})-(\d\d)-(\d\d)-(\d\d)-(\d\d)-(\d\d)-env\.png$")


def scans_of(processed, start, end):
    out = []
    for d in sorted(Path(processed).glob("scan_*")):
        m = SCAN_RE.match(d.name)
        if not (d.is_dir() and m):
            continue
        t = dt.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
        if start <= t < end:
            out.append(d)
    return out


def n_events(dat):
    """events in a WaveDump file (header word 0 = event size in bytes)."""
    try:
        size = dat.stat().st_size
        with dat.open("rb") as f:
            ev = struct.unpack("<I", f.read(4))[0]
        return size // ev if ev > 24 and size % ev == 0 else None
    except Exception:
        return None


def pmt_info(pmt_dir, raw_base, slot_map):
    serial, scan = pmt_dir.name, pmt_dir.parent.name
    ch = None
    for y in sorted((pmt_dir / "configs").glob("*_raw2root.yaml")):
        m = re.search(r"^pmt_ch:\s*(\d+)", y.read_text(errors="ignore"), re.M)
        if m:
            ch = int(m.group(1))
            break
    raws = sorted(Path(raw_base).glob("*/{}/{}".format(scan, serial)))
    measured = sorted(raws[0].glob("wavesave_theta*_phi*")) if raws else []
    nev = [n for n in (n_events(w / "wave0.dat") for w in measured) if n]
    analysed = [d for d in pmt_dir.iterdir() if d.is_dir() and PT_RE.match(d.name)
                and (d / "charge" / "csv" / "aus_charge_results.csv").exists()]
    return {"serial": serial, "scan": scan, "dir": pmt_dir, "ch": ch,
            "slot": slot_map.get(ch) if ch is not None else None,
            "n_measured": len(measured), "n_analysed": len(analysed),
            "nev_min": min(nev) if nev else None, "nev_max": max(nev) if nev else None}


def pmt_dirs(scan_dir):
    return [d for d in sorted(scan_dir.iterdir())
            if d.is_dir() and (any(PT_RE.match(x.name) for x in d.iterdir() if x.is_dir())
                               or (d / "configs").is_dir())]


def find_env(env_dir, day, hhmm):
    want = dt.datetime.combine(day, dt.time(int(hhmm[:2]), int(hhmm[2:])))
    best, bd = None, None
    for d in (Path(env_dir) / day.strftime("%Y-%m-%d"), Path(env_dir)):
        for f in d.glob("*-env.png"):
            m = ENV_RE.search(f.name)
            if not m:
                continue
            t = dt.datetime(*map(int, m.groups()))
            diff = abs((t - want).total_seconds())
            if t.date() == day and (bd is None or diff < bd):
                best, bd = f, diff
    return best


class Report:
    def __init__(self, dpi):
        self.dpi, self.pages = dpi, []

    def new(self, header=None):
        fig = plt.figure(figsize=A4)
        if header:
            fig.text(0.02, 0.975, header, fontsize=12, fontweight="bold", color=INK, va="top")
        return fig

    def add(self, fig):
        fig.text(0.98, 0.012, "page {}".format(len(self.pages) + 1), fontsize=8, color=MUTED, ha="right")
        fig.set_dpi(self.dpi)
        fig.canvas.draw()
        img = Image.fromarray(np.asarray(fig.canvas.buffer_rgba())[..., :3].copy())
        plt.close(fig)
        self.pages.append(img)

    def image(self, fig, path, rect, missing):
        ax = fig.add_axes(rect)
        ax.axis("off")
        if path is None or not Path(path).exists():
            ax.text(0.5, 0.5, "not available\n" + missing, ha="center", va="center", color=MUTED, fontsize=11,
                    transform=ax.transAxes)
            return
        im = Image.open(path).convert("RGB")
        w = int(A4[0] * rect[2] * self.dpi * 1.2)
        h = int(A4[1] * rect[3] * self.dpi * 1.2)
        im.thumbnail((w, h))
        ax.imshow(np.asarray(im))

    def save(self, out):
        if not self.pages:
            return
        self.pages[0].save(out, "PDF", resolution=self.dpi, save_all=True, append_images=self.pages[1:], quality=90)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--date", help="YYYYMMDD of the night (default: yesterday)")
    ap.add_argument("--start", default="0930", help="scans from DATE HHMM to the next day HHMM (default 0930)")
    ap.add_argument("--processed", default="/disk03/hk04/precalib/production/aus/processed")
    ap.add_argument("--raw-base", default="/disk03/hk04/precalib/production/aus")
    ap.add_argument("--env-dir", default="/disk03/hk04/precalib/production/env/plot",
                    help="ENV plots <dir>/yyyy-mm-dd/yyyy-mm-dd-hh-mm-ss-env.png")
    ap.add_argument("--env-time", default="0900", help="ENV plot of the next day closest to HHMM (default 0900)")
    ap.add_argument("--out-dir", default="/disk03/hk04/precalib/production/aus/daily_report")
    ap.add_argument("--slot-map", default="3:1,5:2", help="pmt_ch -> PMT number (default 3:1,5:2)")
    ap.add_argument("--dpi", type=int, default=150)
    a = ap.parse_args()

    day = dt.datetime.strptime(a.date, "%Y%m%d").date() if a.date else dt.date.today() - dt.timedelta(days=1)
    t0 = dt.datetime.combine(day, dt.time(int(a.start[:2]), int(a.start[2:])))
    t1 = t0 + dt.timedelta(days=1)
    slot_map = {int(k): int(v) for k, v in (x.split(":") for x in a.slot_map.split(",") if x)}
    infos = []
    for s in scans_of(a.processed, t0, t1):
        for p in pmt_dirs(s):
            infos.append(pmt_info(p, a.raw_base, slot_map))
    log.info("%s: %d scan/PMT(s) between %s and %s", day, len(infos), t0, t1)

    R = Report(a.dpi)
    # ---- page 1: title
    fig = R.new()
    fig.text(0.5, 0.86, "AUS system {} daily report".format(day.strftime("%Y%m%d")), ha="center",
             fontsize=26, fontweight="bold", color=INK)
    fig.text(0.5, 0.80, "scans started {} – {}      created {}".format(
        t0.strftime("%Y-%m-%d %H:%M"), t1.strftime("%Y-%m-%d %H:%M"), dt.datetime.now().strftime("%Y-%m-%d %H:%M")),
        ha="center", fontsize=11, color=INK2)
    y = 0.68
    if not infos:
        fig.text(0.5, y, "no scan in this period", ha="center", fontsize=16, color=MUTED)
    for i, inf in enumerate(infos):
        slot = "PMT #{}".format(inf["slot"]) if inf["slot"] else "PMT #? (ch {})".format(inf["ch"])
        if inf["nev_min"] is None:
            ev = "N events: ?"
        elif inf["nev_min"] == inf["nev_max"]:
            ev = "{:,} events/point".format(inf["nev_min"])
        else:
            ev = "{:,}–{:,} events/point".format(inf["nev_min"], inf["nev_max"])
        fig.text(0.08, y, "{} : {} ({}), {}".format(inf["scan"], inf["serial"], slot, ev),
                 fontsize=17 if len(infos) <= 6 else 12, color=INK, va="center")
        fig.text(0.08, y - 0.045, "{} point(s) measured, {} analysed   ->  pages {}–{}".format(
            inf["n_measured"], inf["n_analysed"], 3 + 6 * i, 8 + 6 * i), fontsize=10, color=INK2, va="center")
        y -= 0.13 if len(infos) <= 4 else 0.09
    R.add(fig)

    # ---- page 2: environment
    env_day = day + dt.timedelta(days=1)
    env = find_env(a.env_dir, env_day, a.env_time)
    hdr = "Environment monitor  {} {}:{}".format(env_day, a.env_time[:2], a.env_time[2:])
    if env is not None:
        hdr += "   ({})".format(env.name)
    fig = R.new(hdr)
    R.image(fig, env, (0.02, 0.03, 0.96, 0.9), "ENV plot of {} in {}".format(env_day, a.env_dir))
    R.add(fig)

    # ---- 6 pages per scan / PMT
    for inf in infos:
        d, s = inf["dir"], inf["serial"]
        name = "{} : {} (PMT #{})".format(inf["scan"], s, inf["slot"] or "?")

        def single(title, path):
            pages = sorted(path.parent.glob(path.stem + "_p*.png"))
            for k, pth in enumerate([path] + pages):
                f = R.new("{}  –  {}{}".format(name, title, "" if k == 0 else " ({})".format(k + 1)))
                R.image(f, pth, (0.01, 0.02, 0.98, 0.92), str(pth))
                R.add(f)

        def pair(title, left, right):
            f = R.new("{}  –  {}".format(name, title))
            R.image(f, left, (0.01, 0.06, 0.47, 0.86), str(left))
            R.image(f, right, (0.50, 0.06, 0.49, 0.86), str(right))
            R.add(f)

        single("charge fit, all points", d / "allpoints" / "allpoints_charge_{}.png".format(s))
        single("timing fit (target PMT), all points", d / "allpoints" / "allpoints_timing_{}.png".format(s))
        pair("gain map / gain vs theta", d / "charge" / "gain_map_{}.png".format(s),
             d / "charge" / "gain_theta_{}.png".format(s))
        pair("relative QE map / relative QE vs theta", d / "time" / "relative_QE_map_{}.png".format(s),
             d / "time" / "relative_QE_theta_{}.png".format(s))
        pair("TTS (FWHM) map / TTS vs theta (target PMT)", d / "time" / "TTS_map_{}.png".format(s),
             d / "time" / "TTS_theta_{}.png".format(s))
        single("timing fit (SiPM), all points", d / "allpoints" / "allpoints_sipm_timing_{}.png".format(s))

    out_dir = Path(a.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "AUS_daily_report_{}.pdf".format(day.strftime("%Y%m%d"))
    R.save(out)
    log.info("-> %s (%d pages)", out, len(R.pages))
    print("DAILY_REPORT_DONE {} {}".format(out, len(R.pages)))


if __name__ == "__main__":
    main()
