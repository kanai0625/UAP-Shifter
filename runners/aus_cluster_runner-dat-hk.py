#!/usr/bin/env python3
"""
Submit AUS Pyrate processing jobs to a cluster scheduler with a max active-job cap.
Supports waveN.dat files under datastorage directory layout:
  scan_YYYYMMDD_HHMMSS/PMT_label/wavesave_thetaX_phiY/waveN.dat

Default scheduler mode is PJM (pjsub/pjstat), matching SUKAP usage.
"""

import argparse
import copy
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

# Match scan directory like scan_20261023_143138
SCAN_RE = re.compile(r"^scan_(?P<datetime>\d{8}_\d{6})$", re.IGNORECASE)

# Match PMT label like EM6190-C, XX0000-X
PMT_LABEL_RE = re.compile(r"^[A-Za-z]{2}\d{4}-[A-Za-z0-9]+$")

# Match directory format like wavesave_theta10_phi90
ANGLE_DIR_RE = re.compile(
    r"^wavesave_theta(?P<theta>-?\d+)_phi(?P<phi>-?\d+)$",
    re.IGNORECASE,
)

# Match file like wave0.dat
FILE_RE = re.compile(r"^wave(?P<ch>\d+)\.dat$", re.IGNORECASE)


def run_cmd(cmd):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, check=False)
    return proc.returncode, proc.stdout


def count_active_jobs(scheduler, status_cmd, user):
    if scheduler == "slurm":
        rc, out = run_cmd([status_cmd, "-u", user, "-h"])
        if rc != 0:
            return 0
        return sum(1 for line in out.splitlines() if line.strip())

    # pjm
    rc, out = run_cmd([status_cmd])
    if rc != 0:
        return 0
    n = 0
    for line in out.splitlines():
        txt = line.strip()
        if not txt or txt.startswith("JOB_ID"):
            continue
        if user in txt:
            n += 1
    return n


def submit_job(
    scheduler,
    submit_cmd,
    job_name,
    job_script,
    scheduler_out,
    scheduler_err,
    queue=None,
    rscgrp=None,
    elapse=None,
):
    if scheduler == "slurm":
        cmd = [
            submit_cmd,
            "-J",
            job_name,
            "-o",
            str(scheduler_out),
            "-e",
            str(scheduler_err),
        ]
        if queue:
            cmd.extend(["-p", queue])
        if elapse:
            cmd.extend(["-t", elapse])
        cmd.append(str(job_script))
    else:
        cmd = [
            submit_cmd,
            "-N",
            job_name,
            "-o",
            str(scheduler_out),
            "-e",
            str(scheduler_err),
        ]
        target_group = rscgrp or queue
        if target_group:
            cmd.extend(["-L", f"rscgrp={target_group}"])
        if elapse:
            cmd.extend(["-L", f"elapse={elapse}"])
        cmd.append(str(job_script))
    return run_cmd(cmd)


def parse_channels(text):
    out = []
    for tok in text.split(","):
        tok = tok.strip()
        if not tok:
            continue
        out.append(int(tok))
    if not out:
        raise ValueError("No channels parsed from --channels.")
    return out


def discover_points(raw_dir):
    points = {}
    for fp in sorted(raw_dir.rglob("wave*.dat")):
        if not fp.is_file():
            continue
        
        file_m = FILE_RE.match(fp.name)
        dir_m = ANGLE_DIR_RE.match(fp.parent.name)
        
        if not file_m or not dir_m:
            continue
            
        ch = int(file_m.group("ch"))
        theta = int(dir_m.group("theta"))
        phi = int(dir_m.group("phi"))
        key = (theta, phi)
        
        if key not in points:
            points[key] = {}
        points[key][ch] = fp.resolve()
    return points


def filter_points_by_angles(points, theta_list, phi_list):
    if theta_list is None and phi_list is None:
        return points

    filtered = {}
    for (theta, phi), ch_dict in points.items():
        if theta_list is not None and theta not in theta_list:
            continue
        if phi_list is not None and phi not in phi_list:
            continue
        filtered[(theta, phi)] = ch_dict
    return filtered


def keep_requested_points(points, requested):
    if not requested:
        return points
    keep = {}
    for item in requested:
        m = re.match(r"^theta(-?\d+)_phi(-?\d+)$", item.strip())
        if not m:
            raise ValueError(f"Bad --points item: {item} (expected thetaX_phiY)")
        key = (int(m.group(1)), int(m.group(2)))
        if key in points:
            keep[key] = points[key]
    return keep


def extract_scan_and_pmt(raw_dir):
    curr = raw_dir.resolve()
    scan = "unknown_scan"
    pmt = "unknown_pmt"
    
    while curr != curr.parent:
        if SCAN_RE.match(curr.name):
            scan = curr.name
        elif PMT_LABEL_RE.match(curr.name):
            pmt = curr.name
        curr = curr.parent

    if scan == "unknown_scan" and pmt == "unknown_pmt":
        pmt = raw_dir.name
        scan = raw_dir.parent.name
        
    return scan, pmt


def build_config_for_point(template_cfg, channels, point_files, output_root, nevent=0):
    cfg = copy.deepcopy(template_cfg)
    cfg["<channels>"] = channels

    if "InputName" not in cfg:
        raise KeyError("Template config missing top-level key: InputName")

    input_block = cfg["InputName"]

    for k in list(input_block.keys()):
        if re.match(r"^ch\d+$", str(k)):
            del input_block[k]

    for ch in channels:
        if ch not in point_files:
            raise KeyError(f"Missing waveform file for channel {ch} at this theta/phi point.")
        ch_entry = {
            "reader": "ReaderWaveDumpBinary",
            "files": [str(point_files[ch])],
        }
        if nevent > 0:
            ch_entry["events"] = nevent
            ch_entry["max_events"] = nevent
        input_block[f"ch{ch}"] = ch_entry

    for obj_name, obj_cfg in cfg.items():
        if not isinstance(obj_cfg, dict):
            continue
        if obj_cfg.get("algorithm") == "TreeMaker":
            obj_cfg["file"] = str(output_root)

    return cfg


def write_job_script(
    job_script,
    root_thisroot,
    pyrate_cmd,
    config_path,
    log_path,
    nevent=0,
    queue=None,
    rscgrp=None,
    elapse=None,
):
    header = ["#!/usr/bin/env bash"]
    target_group = rscgrp or queue
    if target_group:
        header.append(f"#PJM -L rscgrp={target_group}")
    if elapse:
        header.append(f'#PJM -L elapse="{elapse}"')

    header_str = "\n".join(header)
    nevent_flag = f" -n {nevent}" if nevent > 0 else ""

    current_prefix = sys.prefix
    py_ver = f"python{sys.version_info.major}.{sys.version_info.minor}"
    conda_sh = Path(current_prefix).parents[1] / "etc" / "profile.d" / "conda.sh"

    # Pyrate ソースコードディレクトリのパス
    pyrate_src = "/disk03/usr8/kanai062/UAP-Shifter/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61"

    env_lines = [
        "set +u"
    ]

    # Conda環境のアクティベート
    if conda_sh.is_file():
        env_lines.append(f'source "{conda_sh}"')
        env_lines.append(f'conda activate "{current_prefix}"')

    if root_thisroot and Path(root_thisroot).is_file() and "miniforge3" in str(root_thisroot):
        env_lines.append(f'source "{root_thisroot}"')

    # パス設定（PyrateソースディレクトリをPYTHONPATHに追加）
    env_lines.append(f'export CONDA_PREFIX="{current_prefix}"')
    env_lines.append(f'export PATH="{current_prefix}/bin:$PATH"')
    env_lines.append(f'export LD_LIBRARY_PATH="{current_prefix}/lib:{current_prefix}/lib/root:${{LD_LIBRARY_PATH:-}}"')
    env_lines.append(f'export PYTHONPATH="{pyrate_src}:{current_prefix}/lib/{py_ver}/site-packages:${{PYTHONPATH:-}}"')

    env_setup_str = "\n".join(env_lines)

    # python3 -m pyrate で直接モジュール起動
    text = f"""{header_str}
{env_setup_str}
set -eo pipefail
python3 -m pyrate -c "{config_path}"{nevent_flag} > "{log_path}" 2>&1
"""
    job_script.write_text(text, encoding="utf-8")
    job_script.chmod(0o755)
def main():
    repo_root = Path(__file__).resolve().parents[1]
    uap_home = Path(os.environ.get("UAP_HOME", str(repo_root))).resolve()

    # テンプレート YAML の探索
    env_template = os.environ.get("UAP_AUS_TEMPLATE")
    if env_template and Path(env_template).is_file():
        default_template = Path(env_template).resolve()
    else:
        candidate_repo = repo_root / "upstream" / "aus_pyrate" / "R12860_config_dat.yaml"
        candidate_cwd = Path.cwd() / "R12860_config_dat.yaml"
        if candidate_repo.is_file():
            default_template = candidate_repo
        elif candidate_cwd.is_file():
            default_template = candidate_cwd
        else:
            default_template = Path("R12860_config_dat.yaml")

    default_root_thisroot = Path(
        os.environ.get(
            "UAP_ROOT_THISROOT",
            "/usr/local/sklib_gcc8/root_v6.22.06_python3.8/bin/thisroot.sh",
        )
    ).resolve()

    default_root_base = Path(
        os.environ.get("UAP_AUS_ROOT_DIR", str(repo_root.parent / "datastorage" / "aus" / "root"))
    ).resolve()
    default_scheduler_log_dir = (uap_home / "logs" / "scheduler").resolve()

    ap = argparse.ArgumentParser(description="Submit AUS pyrate .dat point-jobs to cluster with active-job cap.")
    ap.add_argument("--raw-dir", required=True, help="Folder containing PMT_label/wavesave_thetaX_phiY/waveN.dat")
    ap.add_argument("--out-dir", default="", help="Exact output directory for configs/logs/outputs/jobs")
    ap.add_argument("--out-root-base", default=str(default_root_base), help="Base output directory (if --out-dir not set)")
    ap.add_argument("--template", default=str(default_template), help="Template YAML config")
    ap.add_argument("--pyrate-cmd", default="", help="Pyrate executable path (autodetected if omitted)")
    ap.add_argument("--root-thisroot", default=str(default_root_thisroot), help="ROOT thisroot.sh path")
    ap.add_argument("--channels", default="0,1,3,7", help="Comma-separated channels, e.g. 0,1,3,7")
    ap.add_argument("--points", nargs="*", help="Subset points: theta0_phi0 theta10_phi90")
    ap.add_argument("--theta", type=int, nargs="+", help="Filter theta angles, e.g. --theta 10 20")
    ap.add_argument("--phi", type=int, nargs="+", help="Filter phi angles, e.g. --phi 0 90")
    ap.add_argument("--Nevent", "--nevent", type=int, default=0, help="Number of events to process (0 = all events)")
    ap.add_argument("--max-points", type=int, default=0, help="Only submit first N points")
    ap.add_argument("--scheduler", choices=["pjm", "slurm"], default="pjm", help="Scheduler type")
    ap.add_argument("--queue", "-q", help="Queue name for pjsub (-q) or slurm (-p)")
    ap.add_argument("--rscgrp", help="PJM resource group (-L rscgrp=NAME)")
    ap.add_argument("--elapse", help="Elapse time limit for PJM (e.g. 1:00:00 or 01:00:00)")
    ap.add_argument("--submit-cmd", default="pjsub", help="Submit command")
    ap.add_argument("--status-cmd", default="pjstat", help="Queue status command")
    ap.add_argument("--max-active-jobs", type=int, default=100, help="Max active jobs for current user")
    ap.add_argument("--poll-seconds", type=int, default=10, help="Wait time between queue checks")
    ap.add_argument("--job-prefix", default="ausp", help="Job name prefix")
    ap.add_argument(
        "--scheduler-log-dir",
        default=str(default_scheduler_log_dir),
        help="Directory under UAP_HOME to store scheduler stdout/stderr files",
    )
    ap.add_argument("--dry-run", action="store_true", help="Generate configs/scripts only, do not submit")
    args = ap.parse_args()

    raw_dir = Path(args.raw_dir).resolve()
    template_path = Path(args.template).resolve()

    # pyrate 実行ファイルの自動検出
    pyrate_cmd_path = None
    if args.pyrate_cmd:
        p = Path(args.pyrate_cmd).resolve()
        if p.is_file():
            pyrate_cmd_path = p
    
    if not pyrate_cmd_path:
        w = shutil.which("pyrate")
        if w:
            pyrate_cmd_path = Path(w).resolve()

    if not pyrate_cmd_path:
        cand = Path(sys.prefix) / "bin" / "pyrate"
        if cand.is_file():
            pyrate_cmd_path = cand.resolve()

    if not pyrate_cmd_path:
        raise SystemExit(
            f"Pyrate executable not found in PATH or {sys.prefix}/bin.\n"
            "Please ensure hkprecal-uap conda environment is active."
        )

    root_thisroot = Path(args.root_thisroot).resolve()
    out_root_base = Path(args.out_root_base).resolve()
    scheduler_log_base = Path(args.scheduler_log_dir).resolve()
    channels = parse_channels(args.channels)

    if not raw_dir.is_dir():
        raise SystemExit(f"Raw directory not found: {raw_dir}")
    if not template_path.is_file():
        raise SystemExit(f"Template YAML not found: {template_path}")

    user = os.environ.get("USER", "")
    if not user:
        raise SystemExit("USER environment variable is empty.")

    with template_path.open("r", encoding="utf-8") as fi:
        template_cfg = yaml.safe_load(fi)

    points_all = discover_points(raw_dir)
    points = keep_requested_points(points_all, args.points)
    points = filter_points_by_angles(points, args.theta, args.phi)

    ordered_keys = sorted(points.keys(), key=lambda x: (x[0], x[1]))
    if args.max_points > 0:
        ordered_keys = ordered_keys[: args.max_points]

    if not ordered_keys:
        raise SystemExit(f"No matching points found in {raw_dir}")

    scan_name, pmt_name = extract_scan_and_pmt(raw_dir)
    run_base = Path(args.out_dir).resolve() if args.out_dir else (out_root_base / scan_name / pmt_name)
    scheduler_dir = scheduler_log_base / scan_name / pmt_name
    cfg_dir = run_base / "configs"
    log_dir = run_base / "logs"
    out_root_dir = run_base / "outputs"
    job_dir = run_base / "jobs"
    scheduler_dir.mkdir(parents=True, exist_ok=True)
    cfg_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    out_root_dir.mkdir(parents=True, exist_ok=True)
    job_dir.mkdir(parents=True, exist_ok=True)

    submitted = 0
    skipped = 0

    for theta, phi in ordered_keys:
        point_files = points[(theta, phi)]
        missing = [ch for ch in channels if ch not in point_files]
        point_tag = f"theta{theta}_phi{phi}"
        if missing:
            print(f"[SKIP] {point_tag}: missing channels {missing}")
            skipped += 1
            continue

        out_root = out_root_dir / f"output_{point_tag}.root"
        cfg_path = cfg_dir / f"R12860_{point_tag}_dat.yaml"
        log_path = log_dir / f"{point_tag}.log"
        scheduler_out = scheduler_dir / f"{point_tag}.out"
        scheduler_err = scheduler_dir / f"{point_tag}.err"
        job_script = job_dir / f"job_{point_tag}.sh"
        job_name = f"{args.job_prefix}_{theta}_{phi}"

        cfg = build_config_for_point(template_cfg, channels, point_files, out_root, nevent=args.Nevent)
        with cfg_path.open("w", encoding="utf-8") as fo:
            yaml.safe_dump(cfg, fo, sort_keys=False)

        write_job_script(
            job_script,
            root_thisroot,
            pyrate_cmd_path,
            cfg_path,
            log_path,
            nevent=args.Nevent,
            queue=args.queue,
            rscgrp=args.rscgrp,
            elapse=args.elapse,
        )

        if args.dry_run:
            print(f"[DRY] {point_tag} -> {job_script}")
            submitted += 1
            continue

        while True:
            active = count_active_jobs(args.scheduler, args.status_cmd, user)
            if active < args.max_active_jobs:
                break
            print(
                f"[WAIT] active_jobs={active} >= limit={args.max_active_jobs}; "
                f"sleep {args.poll_seconds}s"
            )
            time.sleep(args.poll_seconds)

        rc, out = submit_job(
            args.scheduler,
            args.submit_cmd,
            job_name,
            job_script,
            scheduler_out,
            scheduler_err,
            queue=args.queue,
            rscgrp=args.rscgrp,
            elapse=args.elapse,
        )
        if rc == 0:
            submitted += 1
            msg = out.strip().splitlines()[-1] if out.strip() else "submitted"
            print(f"[OK]   {point_tag} -> {msg}")
        else:
            print(f"[FAIL] {point_tag} submit failed (rc={rc})")
            if out.strip():
                print(out.strip())

    print(
        f"[DONE] submitted={submitted}, skipped={skipped}, total_points={len(ordered_keys)}, "
        f"base={run_base}, scheduler_logs={scheduler_dir}"
    )


if __name__ == "__main__":
    main()