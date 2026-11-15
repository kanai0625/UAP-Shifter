#!/usr/bin/env python3
"""
Submit AUS raw2root jobs (runners/aus_raw2root.py, no pyrate) to the PJM scheduler with a cap on
the number of active jobs.  Same command line and output lines as aus_cluster_runner-dat-hk.py.

Raw layout : <raw-dir> = .../scan_YYYYMMDD_HHMMSS/<PMT>/wavesave_thetaX_phiY/waveN.dat
Per point  : one job
               runners/aus_raw2root.py --input-dir <raw>/wavesave_<pt> --channels <ch>
                   --out <out-dir>/outputs/output_<pt>.root --nevent N --nsigma S
                   [--vcut-mv V --vcut-out <out-dir>/outputs_vcut<V>mV/output_<pt>.root]
Out layout : <out-dir>/outputs/              main ROOT files
             <out-dir>/outputs_vcut<V>mV/    fixed-threshold PMT ROOT files (timing)
             <out-dir>/configs/<pt>_raw2root.yaml   parameters of the point (channels, pmt_ch, ...)
             <out-dir>/jobs/job_<pt>.sh   <out-dir>/logs/<pt>.log   <scheduler-log-dir>/<pt>.out/.err

  python3 runners/aus_cluster_runner-raw2root-hk.py \\
      --raw-dir /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B \\
      --out-dir /disk03/hk04/precalib/production/aus/processed/scan_20261108_135057/EM5370-B \\
      --channels 0,1,5,7 --queue hk --Nevent 300000 --vcut-mv 2.0 --elapse 1:00:00

Prints one line per point:  [OK]   thetaX_phiY -> <pjsub message>   /  [DRY] ...  /  [SKIP] ...  /  [FAIL] ...
"""

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ANGLE_DIR_RE = re.compile(r"^wavesave_theta(?P<theta>-?\d+)_phi(?P<phi>-?\d+)$", re.IGNORECASE)
FILE_RE = re.compile(r"^wave(?P<ch>\d+)\.dat$", re.IGNORECASE)
PMT_CHANNELS = (3, 5, 7)


def run_cmd(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, check=False)
    return p.returncode, p.stdout


def count_active_jobs(status_cmd):
    rc, out = run_cmd([status_cmd])
    if rc != 0:
        return 0
    return sum(1 for line in out.splitlines() if re.match(r"^\s*\d+(\[\d+\])?\s", line))


def discover_points(raw_dir):
    points = {}
    for d in sorted(raw_dir.iterdir()):
        m = ANGLE_DIR_RE.match(d.name)
        if not (m and d.is_dir()):
            continue
        chans = {int(FILE_RE.match(f.name).group("ch")): f for f in d.iterdir() if FILE_RE.match(f.name)}
        points[(int(m.group("theta")), int(m.group("phi")))] = (d, chans)
    return points


def main():
    repo = Path(__file__).resolve().parents[1]
    uap_home = Path(os.environ.get("UAP_HOME", str(repo))).resolve()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw-dir", required=True, help=".../scan_.../<PMT> with wavesave_thetaX_phiY/")
    ap.add_argument("--out-dir", required=True, help="output directory (outputs/, configs/, jobs/, logs/)")
    ap.add_argument("--channels", default="0,1,3,7", help="channels, e.g. 0,1,5,7")
    ap.add_argument("--pmt-ch", type=int, default=0, help="PMT channel (default: the first of 3/5/7 in --channels)")
    ap.add_argument("--points", nargs="*", help="subset: theta0_phi0 theta10_phi90 ...")
    ap.add_argument("--theta", type=int, nargs="+")
    ap.add_argument("--phi", type=int, nargs="+")
    ap.add_argument("--Nevent", "--nevent", type=int, default=300000, help="events per channel (0 = all)")
    ap.add_argument("--nsigma", type=float, default=2.2, help="PulseStart threshold in baseline sigma")
    ap.add_argument("--nconsec", type=int, default=1)
    ap.add_argument("--vcut-mv", default="2.0",
                    help="fixed PMT threshold [mV] for the timing file (0 = off); the text is used in the "
                         "directory name outputs_vcut<V>mV, e.g. 2.0 -> outputs_vcut2.0mV")
    ap.add_argument("--vcut-edge", choices=["max", "first"], default="max")
    ap.add_argument("--max-points", type=int, default=0)
    ap.add_argument("--queue", "-q", default="hk")
    ap.add_argument("--elapse", default="1:00:00")
    ap.add_argument("--submit-cmd", default="pjsub")
    ap.add_argument("--status-cmd", default="pjstat")
    ap.add_argument("--max-active-jobs", type=int, default=100)
    ap.add_argument("--poll-seconds", type=int, default=30)
    ap.add_argument("--job-prefix", default="ausr")
    ap.add_argument("--scheduler-log-dir", default=None, help="default: <out-dir>/scheduler")
    ap.add_argument("--dry-run", action="store_true", help="write the job scripts only")
    a = ap.parse_args()

    raw_dir = Path(a.raw_dir).resolve()
    run_base = Path(a.out_dir).resolve()
    if not raw_dir.is_dir():
        sys.exit("Raw directory not found: {}".format(raw_dir))
    channels = [int(c) for c in a.channels.replace(",", " ").split()]
    pmt_ch = a.pmt_ch or next((c for c in channels if c in PMT_CHANNELS), 0)
    vtag = "outputs_vcut{}mV".format(a.vcut_mv) if float(a.vcut_mv) > 0 else ""

    points = discover_points(raw_dir)
    if a.points:
        want = set()
        for item in a.points:
            m = re.match(r"^theta(-?\d+)_phi(-?\d+)$", item.strip())
            if not m:
                sys.exit("Bad --points item: {} (expected thetaX_phiY)".format(item))
            want.add((int(m.group(1)), int(m.group(2))))
        points = {k: v for k, v in points.items() if k in want}
    if a.theta:
        points = {k: v for k, v in points.items() if k[0] in a.theta}
    if a.phi:
        points = {k: v for k, v in points.items() if k[1] in a.phi}
    keys = sorted(points)
    if a.max_points > 0:
        keys = keys[: a.max_points]
    if not keys:
        sys.exit("No matching points found in {}".format(raw_dir))

    dirs = {k: run_base / k for k in ("outputs", "configs", "jobs", "logs")}
    if vtag:
        dirs["vcut"] = run_base / vtag
    sched = Path(a.scheduler_log_dir).resolve() if a.scheduler_log_dir else run_base / "scheduler"
    for d in list(dirs.values()) + [sched]:
        d.mkdir(parents=True, exist_ok=True)

    prefix = sys.prefix                                   # conda environment of the caller
    conda_sh = Path(prefix).parents[1] / "etc" / "profile.d" / "conda.sh"
    raw2root = (repo / "runners" / "aus_raw2root.py").resolve()
    submitted = skipped = 0
    for theta, phi in keys:
        ws, chans = points[(theta, phi)]
        pt = "theta{}_phi{}".format(theta, phi)
        missing = [c for c in channels if c not in chans]
        if missing:
            print("[SKIP] {}: missing channels {}".format(pt, missing))
            skipped += 1
            continue
        out = dirs["outputs"] / "output_{}.root".format(pt)
        vout = dirs["vcut"] / "output_{}.root".format(pt) if vtag else None
        (dirs["configs"] / "{}_raw2root.yaml".format(pt)).write_text(
            "point: {}\ninput_dir: {}\nchannels: [{}]\npmt_ch: {}\nnevent: {}\nnsigma: {}\nnconsec: {}\n"
            "vcut_mv: {}\nvcut_edge: {}\nout: {}\nvcut_out: {}\n".format(
                pt, ws, ", ".join(map(str, channels)), pmt_ch, a.Nevent, a.nsigma, a.nconsec, a.vcut_mv,
                a.vcut_edge, out, vout or ""))
        vflag = ' --vcut-mv {} --vcut-out "{}" --vcut-edge {}'.format(a.vcut_mv, vout, a.vcut_edge) if vtag else ""
        env = ["set +u"]
        if conda_sh.is_file():
            env += ['source "{}"'.format(conda_sh), 'conda activate "{}"'.format(prefix)]
        env += ['export PATH="{}/bin:$PATH"'.format(prefix),
                'export UAP_HOME="{}" PYTHONPATH="{}:${{PYTHONPATH:-}}"'.format(uap_home, uap_home)]
        job = dirs["jobs"] / "job_{}.sh".format(pt)
        job.write_text("""#!/usr/bin/env bash
#PJM -L rscgrp={q}
#PJM -L elapse={el}
{env}
set -eo pipefail
python3 "{r2r}" --input-dir "{ws}" --channels {ch} --out "{out}" --nevent {nev} \\
    --nsigma {ns} --nconsec {nc}{vflag} > "{log}" 2>&1
""".format(q=a.queue, el=a.elapse, env="\n".join(env), r2r=raw2root, ws=ws, ch=",".join(map(str, channels)),
           out=out, nev=a.Nevent, ns=a.nsigma, nc=a.nconsec, vflag=vflag,
           log=dirs["logs"] / "{}.log".format(pt)), encoding="utf-8")
        job.chmod(0o755)
        if a.dry_run:
            print("[DRY] {} -> {}".format(pt, job))
            submitted += 1
            continue
        while True:
            active = count_active_jobs(a.status_cmd)
            if active < a.max_active_jobs:
                break
            print("[WAIT] active_jobs={} >= limit={}; sleep {}s".format(active, a.max_active_jobs, a.poll_seconds))
            time.sleep(a.poll_seconds)
        rc, txt = run_cmd([a.submit_cmd, "-N", "{}_{}_{}".format(a.job_prefix, theta, phi),
                           "-o", str(sched / "{}.out".format(pt)), "-e", str(sched / "{}.err".format(pt)),
                           "-L", "rscgrp={}".format(a.queue), "-L", "elapse={}".format(a.elapse), str(job)])
        if rc == 0:
            submitted += 1
            print("[OK]   {} -> {}".format(pt, txt.strip().splitlines()[-1] if txt.strip() else "submitted"))
        else:
            print("[FAIL] {} submit failed (rc={})".format(pt, rc))
            if txt.strip():
                print(txt.strip())
    print("[DONE] submitted={}, skipped={}, total_points={}, base={}, pmt_ch={}, timing file={}".format(
        submitted, skipped, len(keys), run_base, pmt_ch, vtag or "off"))


if __name__ == "__main__":
    main()
