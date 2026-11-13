#!/bin/bash
# =====================================================================
#  1113-AUSUAP-auto.sh  –  automatic root2csv + csv2plot for AUS data
#  Run on : Shifter PC (precalib@10.200.102.69), next to 1113-AUSjobsubmit.sh
#
#  Usage :  ./1113-AUSUAP-auto.sh [-date YYYYMMDD] [-replot]
#           ./1113-AUSUAP-auto.sh status      (show the status from another terminal)
#
#  Input  : SUBMIT_LIST written by 1113-AUSjobsubmit.sh (point + PJM job id)
#  Every INTERVAL seconds:
#    1. sukap (hkpd): pjstat -> jobs still queued/running are skipped
#    2. a point is READY when its job is no longer in pjstat and
#         processed/scan_.../<PMT>/outputs/output_thetaX_phiY.root
#       exists and was not modified for ROOT_SETTLE seconds
#       (job gone but no root file -> [JOBFAIL] in the log)
#    3. per point (python3 main.py root2csv, same configs as the manual):
#         <PMT>/thetaX_phiY/charge/  aus_root2csv_charge_default  (csv + charge distribution plot)
#         <PMT>/thetaX_phiY/time/    aus_root2csv_emg_default     (csv + timing fit plot)
#       pmt_ch = 3 or 5, taken from the job config (wave0137 / wave0157)
#    4. per PMT, after new points: merge the point CSVs, recompute the
#       values relative to theta=0,phi=0, and plot
#         <PMT>/charge/  aus_charge_results.csv, gain, relative gain
#         <PMT>/time/    aus_results.csv,        relative QE, arrival time, TTS (FWHM)
#       every plot: x = theta, one line per phi (0, 90, 180, 270)
#    5. waveform 2D plots (time vs signal, all events) for every submitted point
#       (raw waveN.dat, no need to wait for the job), at most WF_PER_CYCLE per cycle
#         <PMT>/waveformdist/thetaX_phiY_chN.png      (runners/AUSwaveform-2Dplot.py)
#  Analysed points are remembered (ANA_LIST, with the job id) and never redone,
#  unless the point is submitted again (new job id).
#
#  While running, type in this terminal:  status | log | quit | help
# =====================================================================

# ============================ Settings ===============================
SUKAP_USER="hkpd"
SUKAP_HOST="10.220.11.100"          # sukap
SUKAP_PORT="22"
SUKAP_OUT_BASE="/disk03/hk04/precalib/production/aus/processed"   # <base>/scan_.../<PMT>

UAP_DIR="/disk03/usr8/kanai062/UAP-Shifter"
CONDA_SH="$UAP_DIR/miniforge3/etc/profile.d/conda.sh"
CONDA_ENV="$UAP_DIR/miniforge3/envs/hkprecal-uap"
PYRATE_HOME="$UAP_DIR/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61"

CHARGE_CFG="${CHARGE_CFG:-aus_root2csv_charge_default}"
TIME_CFG="${TIME_CFG:-aus_root2csv_emg_default}"
PMT_CH_CANDIDATES="${PMT_CH_CANDIDATES:-3 5}"   # first one found in the job config = pmt_ch
SUKAP_RAW_BASE="/disk03/hk04/precalib/production/aus"   # raw: <base>/<elec>/scan_.../<PMT>/wavesave_thetaX_phiY
WAVEFORM_PY="$UAP_DIR/runners/AUSwaveform-2Dplot.py"      # git branch 1107
WF_OPTS="${WF_OPTS:-}"              # extra options for AUSwaveform-2Dplot.py, e.g. "--nevent 100000"
WF_PER_CYCLE=${WF_PER_CYCLE:-10}    # waveform points per cycle (root2csv of new points is not delayed)

INTERVAL=${INTERVAL:-300}           # [s] between cycles
ROOT_SETTLE=${ROOT_SETTLE:-60}      # [s] root file unchanged for this long (job id known)
ROOT_SETTLE_NOJOB=${ROOT_SETTLE_NOJOB:-600}  # [s] same, when no job id is known
MAX_NG=3                            # a point that failed this many times is given up

LOG_DIR="$HOME/precal_transfer_logs"
SUBMIT_LIST="$LOG_DIR/AUSjobs_submitted.list"   # written by 1113-AUSjobsubmit.sh
ANA_LIST="$LOG_DIR/AUSana_done.list"            # key<TAB>job id<TAB>date
WF_LIST="$LOG_DIR/AUSwave_done.list"            # key<TAB>date   (waveform 2D plots made)
STATUS_FILE="/tmp/precal_AUSana.status"
STOP_FILE="/tmp/precal_AUSana.stop"
INSTANCE_LOCK="/tmp/precal_AUSana.lock"
REMOTE_TOOL="$SUKAP_OUT_BASE/.uap_auto/aus_merge_plot.py"   # uploaded at start

SSH_CTRL="/tmp/precal-ana-ssh-%r@%h-%p"
SUKAP_COMMON="-p $SUKAP_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=600"

# ============================ Helpers ================================
sbash() { sshpass -e ssh $SUKAP_COMMON "$SUKAP_USER@$SUKAP_HOST" 'bash -s' 7>&-; }
usage() {
    cat <<EOF
Usage:  $0 [-date YYYYMMDD] [-replot]
        $0 status
  -date YYYYMMDD   only scans scan_YYYYMMDD_* on/after this date (default: all submitted points)
  -replot          remake merged CSVs + plots for every PMT once at start
  status           print the status of the running analysis
Env overrides: CHARGE_CFG TIME_CFG PMT_CH_CANDIDATES WF_OPTS WF_PER_CYCLE INTERVAL ROOT_SETTLE
EOF
}

# remote environment (prepended to every remote script)
remote_env() {
    cat <<EOF
set +u
source '$CONDA_SH' && conda activate '$CONDA_ENV' || { echo 'REMOTE_ERR:conda'; exit; }
export UAP_HOME='$UAP_DIR'
export PYRATE_HOME='$PYRATE_HOME'
export UAP_ROOT_THISROOT='$CONDA_ENV/bin/thisroot.sh'
export PYTHONPATH='$UAP_DIR':'$PYRATE_HOME':\${PYTHONPATH:-}
export LD_LIBRARY_PATH='$CONDA_ENV/lib':'$CONDA_ENV/lib/root':\${LD_LIBRARY_PATH:-}
export MPLBACKEND=Agg
EOF
}

# python: merge point CSVs of one PMT, recompute relative values, plot
merge_plot_py() {
    cat <<'PY'
#!/usr/bin/env python3
"""Merge AUS per-point CSVs of one PMT, recompute relative columns, make plots."""
import logging
import sys
from argparse import Namespace
from pathlib import Path

import numpy as np
import pandas as pd

from uap.fit import common_math as cm
import uap.engine.csv2plot as c2p

logging.basicConfig(level=logging.INFO, format="[%(asctime)s][merge_plot][%(levelname)s] %(message)s")
log = logging.getLogger("merge_plot")

pmt_dir = Path(sys.argv[1])
serial = sys.argv[2]
PHIS = (0, 90, 180, 270)
COLORS = ("C0", "C1", "C2", "C3")
MARKERS = ("o", "s", "^", "D")


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
    phis = pd.to_numeric(df["phi"], errors="coerce")
    lines = {}
    for i, phi in enumerate(PHIS):
        if not (phis == phi).any():
            continue
        lines["phi{}".format(phi)] = dict(base, label="phi = {} deg".format(phi), phi=phi,
                                          line_color=COLORS[i], marker=MARKERS[i])
    if not lines:
        log.warning("skip %s: no points at phi %s", out_name, PHIS)
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
    rel(dfc, "gain", "gain_err", c, "relative_gain", "relative_gain_err")
    out = pmt_dir / "charge"
    out.mkdir(parents=True, exist_ok=True)
    csv = out / "aus_charge_results.csv"
    dfc.to_csv(csv, index=False)
    log.info("charge: %d point(s) -> %s", len(dfc), csv)
    plot(out, csv, "gain", "gain_err", "Gain", "Gain", "gain_{}.png".format(serial), None)
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
         "Relative QE" + (" (SiPM normalized)" if use_sipm else ""), "Relative QE",
         "relative_QE_{}.png".format(serial), 1.0)
    plot(out, csv, "mu", "mu_err", "Arrival time (ns)  [PMT - laser trigger, EMG mu]", "Arrival time",
         "arrival_time_{}.png".format(serial), None)
    plot(out, csv, "FWHM", "", "TTS FWHM (ns)", "TTS (FWHM of the timing fit)", "TTS_{}.png".format(serial), None)
else:
    log.info("time: no point CSV yet")
print("MERGE_PLOT_DONE")
PY
}

# ============================ Arguments ==============================
if [ "$1" = "status" ]; then
    if [ -f "$STATUS_FILE" ] && ! flock -n "$INSTANCE_LOCK" true 2>/dev/null; then cat "$STATUS_FILE"
    else echo "AUS analysis is not running."; fi
    exit 0
fi
DATE_OPT=""; REPLOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -date|--date) DATE_OPT="$2"; shift 2 ;;
        -replot|--replot) REPLOT=1; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done
if [ -n "$DATE_OPT" ]; then
    [[ "$DATE_OPT" =~ ^[0-9]{8}$ ]] || { echo "-date must be YYYYMMDD (got '$DATE_OPT')"; exit 1; }
    MIN_DATE=$DATE_OPT
else
    MIN_DATE=00000000
fi

for c in sshpass flock; do
    command -v $c &>/dev/null || { echo "$c is not installed (sudo apt install $c)"; exit 1; }
done

exec 7>"$INSTANCE_LOCK"
flock -n 7 || { echo "1113-AUSUAP-auto.sh is already running.  (./1113-AUSUAP-auto.sh status)"; exit 1; }

mkdir -p "$LOG_DIR"; touch "$ANA_LIST" "$WF_LIST"; rm -f "$STOP_FILE"
[ -s "$SUBMIT_LIST" ] || echo "NOTE: $SUBMIT_LIST is empty – has 1113-AUSjobsubmit.sh submitted anything?"

read -rsp "Password for $SUKAP_USER@$SUKAP_HOST (sukap): " SUKAP_PASS; echo
export SSHPASS="$SUKAP_PASS"
sshpass -e ssh $SUKAP_COMMON -O check "$SUKAP_USER@$SUKAP_HOST" &>/dev/null \
    || sshpass -e ssh $SUKAP_COMMON -fN "$SUKAP_USER@$SUKAP_HOST" &>/dev/null 7>&-

echo "Checking the environment on sukap as $SUKAP_USER ..."
CHK=$( { remote_env; cat <<EOF
for f in '$UAP_DIR/main.py' '$UAP_DIR/config/$CHARGE_CFG.yaml' '$UAP_DIR/config/$TIME_CFG.yaml' '$WAVEFORM_PY'; do
    [ -r "\$f" ] || echo "NG: cannot read \$f"
done
python3 -c 'import ROOT, hydra, omegaconf, uproot, pandas, matplotlib, uap.engine.csv2plot, uap.engine.root2csv' 2>&1 | tail -2 | sed 's/^/NG: python: /'
mkdir -p '$(dirname "$REMOTE_TOOL")' 2>/dev/null && [ -w '$(dirname "$REMOTE_TOOL")' ] || echo "NG: cannot write $(dirname "$REMOTE_TOOL")"
echo CHECK_END
EOF
} | sbash 2>&1)
if ! grep -q CHECK_END <<< "$CHK"; then
    echo "ERROR: cannot log in to $SUKAP_USER@$SUKAP_HOST (password / network?)"; echo "$CHK"; exit 1
fi
if grep -q '^NG:' <<< "$CHK"; then
    echo "ERROR: environment problem on sukap:"; grep '^NG:' <<< "$CHK" | sed 's/^/  /'; exit 1
fi
# upload the merge/plot tool
merge_plot_py | sshpass -e ssh $SUKAP_COMMON "$SUKAP_USER@$SUKAP_HOST" "cat > '$REMOTE_TOOL'" 7>&- \
    || { echo "ERROR: cannot upload $REMOTE_TOOL"; exit 1; }

LOG_FILE="$LOG_DIR/AUSana_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
{
    echo "=== AUS automatic analysis (root2csv + csv2plot) ==="
    echo "Started  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Input    : $SUBMIT_LIST  (scans >= $MIN_DATE)"
    echo "Base     : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>"
    echo "Configs  : $CHARGE_CFG / $TIME_CFG   pmt_ch from {$PMT_CH_CANDIDATES}"
    echo "------------------------------------------------------------"
} > "$LOG_FILE"

# ============================ Worker =================================
worker() {
    declare -A ANA NGCNT GIVEUP FAILED WF WNG
    local k j rest
    while IFS=$'\t' read -r k j rest; do [ -n "$k" ] && ANA[$k]="$j"; done < "$ANA_LIST"
    while IFS=$'\t' read -r k rest; do [ -n "$k" ] && WF[$k]=1; done < "$WF_LIST"

    ST_STATE="idle"; ST_LAST="-"; ST_NEXT="-"; ST_CUR=""
    ST_RUNNING=0; ST_READY=0; ST_WAITROOT=0; N_DONE=0; N_NG=0; N_PLOT=0; N_FAIL=0
    ST_WFLEFT=0; N_WF=0; N_WFNG=0

    write_status() {
        {
            echo "============ AUS analysis status ($(date '+%H:%M:%S')) ============"
            echo "State     : $ST_STATE"
            [ -n "$ST_CUR" ] && echo "            $ST_CUR"
            echo "Input     : $SUBMIT_LIST  (scans >= $MIN_DATE)"
            echo "Base      : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>"
            echo "Points    : job queued/running $ST_RUNNING   root not settled $ST_WAITROOT   ready $ST_READY"
            echo "Totals    : analysed $N_DONE   NG $N_NG   job failed (no root) $N_FAIL   PMT plots made $N_PLOT"
            echo "Waveform  : done $N_WF   NG $N_WFNG   left $ST_WFLEFT   (max $WF_PER_CYCLE per cycle)"
            echo "Last cycle: $ST_LAST      Next cycle : $ST_NEXT"
            echo "Log       : $LOG_FILE"
            echo "Recent    :"
            tail -n 6 "$LOG_FILE" | sed 's/^/  /'
            echo "======================================================================"
        } > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
    }

    # $1 scan  $2 pmt  $3 point  -> prints POINT_OK / POINT_NG:<msg>
    analyse_point() {
        local scan=$1 pmt=$2 pt=$3
        local pd="$SUKAP_OUT_BASE/$scan/$pmt"
        { remote_env; cat <<EOF
pd='$pd'; pt='$pt'; root="\$pd/outputs/output_\$pt.root"
[ -s "\$root" ] || { echo "POINT_NG:root file missing"; exit; }
pch=""
cfg=\$(ls "\$pd"/configs/*_\${pt}_dat.yaml 2>/dev/null | head -1)
for c in $PMT_CH_CANDIDATES; do
    [ -n "\$cfg" ] && grep -qE "^[[:space:]]*ch\$c:" "\$cfg" && { pch=\$c; break; }
done
[ -n "\$pch" ] || { echo "POINT_NG:cannot find pmt channel ($PMT_CH_CANDIDATES) in \${cfg:-configs/*_\${pt}_dat.yaml}"; exit; }
mkdir -p "\$pd/\$pt" && cd "\$pd/\$pt" || { echo "POINT_NG:cannot create \$pd/\$pt"; exit; }
rm -rf charge time
python3 '$UAP_DIR/main.py' root2csv --config-name '$CHARGE_CFG' --input-dir "\$root" --serial '$pmt' \
    pmt_ch=\$pch hydra.run.dir="\$pd/\$pt/charge" > charge.log 2>&1
rc1=\$?
python3 '$UAP_DIR/main.py' root2csv --config-name '$TIME_CFG' --input-dir "\$root" --serial '$pmt' \
    pmt_ch=\$pch hydra.run.dir="\$pd/\$pt/time" > time.log 2>&1
rc2=\$?
msg=""
[ -s charge/csv/aus_charge_results.csv ] || msg="charge (rc=\$rc1): \$(tail -1 charge.log)"
[ -s time/csv/aus_results.csv ]          || msg="\${msg:+\$msg | }time (rc=\$rc2): \$(tail -1 time.log)"
if [ -z "\$msg" ]; then echo "POINT_OK:pmt_ch=\$pch"; else echo "POINT_NG:\$msg"; fi
EOF
        } | sbash 2>&1 | grep -E '^(POINT_|REMOTE_ERR)' | tail -1
    }

    # $1 elec  $2 scan  $3 pmt  $4 point  -> WF_OK:<n> / WF_NG:<msg>
    waveform_point() {
        local raw="$SUKAP_RAW_BASE/$1/$2/$3/wavesave_$4" out="$SUKAP_OUT_BASE/$2/$3/waveformdist"
        { remote_env; cat <<EOF
[ -d '$raw' ] || { echo 'WF_NG:raw dir missing $raw'; exit; }
mkdir -p '$out' || { echo 'WF_NG:cannot create $out'; exit; }
python3 '$WAVEFORM_PY' --input-dir '$raw' --out-dir '$out' --prefix '$4_' $WF_OPTS > '$out/$4.log' 2>&1
r=\$(grep -o 'WAVEFORM_2DPLOT_DONE [0-9]*' '$out/$4.log' | tail -1)
if [ -n "\$r" ]; then echo "WF_OK:\${r##* }"; else echo "WF_NG:\$(tail -1 '$out/$4.log')"; fi
EOF
        } | sbash 2>&1 | grep -E '^(WF_|REMOTE_ERR)' | tail -1
    }

    waveform_stage() {
        local key sig rest n=0 r
        local -a WQ=()
        declare -A SEEN
        while IFS=$'\t' read -r key sig rest; do
            [[ "$key" =~ ^[^/]+/scan_([0-9]{8})_[0-9]{6}/[^/]+/theta-?[0-9]+_phi-?[0-9]+$ ]] || continue
            [[ "${BASH_REMATCH[1]}" < "$MIN_DATE" ]] && continue
            if [ -n "${WF[$key]}" ] || [ -n "${SEEN[$key]}" ]; then continue; fi
            (( ${WNG[$key]:-0} >= MAX_NG )) && continue
            SEEN[$key]=1; WQ+=("$key")
        done < "$SUBMIT_LIST"
        ST_WFLEFT=${#WQ[@]}
        local nmax=$(( ST_WFLEFT < WF_PER_CYCLE ? ST_WFLEFT : WF_PER_CYCLE ))
        for key in "${WQ[@]}"; do
            [ -f "$STOP_FILE" ] && break
            (( n >= WF_PER_CYCLE )) && break
            n=$(( n + 1 ))
            [[ "$key" =~ ^([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]
            local e=${BASH_REMATCH[1]} sc=${BASH_REMATCH[2]} pm=${BASH_REMATCH[3]} pt=${BASH_REMATCH[4]}
            ST_STATE="waveform 2D plot  ($n/$nmax this cycle, $ST_WFLEFT left)"
            ST_CUR="$sc/$pm/$pt  (all channels, all events)"; write_status
            r=$(waveform_point "$e" "$sc" "$pm" "$pt")
            if [[ "$r" == WF_OK* ]]; then
                WF[$key]=1; N_WF=$(( N_WF + 1 ))
                printf '%s\t%s\n' "$key" "$(date '+%F %T')" >> "$WF_LIST"
                log "[WAVE]    $key  -> waveformdist/${pt}_ch*.png (${r#WF_OK:} ch)"
            else
                WNG[$key]=$(( ${WNG[$key]:-0} + 1 )); N_WFNG=$(( N_WFNG + 1 ))
                log "[WAVE NG] $key – ${r#WF_NG:}   (attempt ${WNG[$key]}/$MAX_NG, see waveformdist/$pt.log)"
            fi
        done
        ST_WFLEFT=$(( ST_WFLEFT - n ))
        ST_CUR=""
    }

    # $1 scan  $2 pmt
    merge_plot() {
        local pd="$SUKAP_OUT_BASE/$1/$2"
        { remote_env; echo "python3 '$REMOTE_TOOL' '$pd' '$2' > '$pd/merge_plot.log' 2>&1; tail -1 '$pd/merge_plot.log'"; } \
            | sbash 2>&1 | tail -1
    }

    point_ng() {   # $1 key  $2 job  $3 message
        N_NG=$(( N_NG + 1 ))
        NGCNT[$1]=$(( ${NGCNT[$1]:-0} + 1 ))
        log "[NG]      $1 – $3   (attempt ${NGCNT[$1]}/$MAX_NG)"
        if (( ${NGCNT[$1]} >= MAX_NG )); then
            GIVEUP[$1]="$2"; log "[GAVE UP] $1 – failed $MAX_NG times (see <PMT>/thetaX_phiY/charge.log, time.log)"
        fi
    }

    do_merge_plot() {   # $1 "scan/pmt"
        local sp=$1 r
        ST_STATE="plotting  $sp"; ST_CUR=""; write_status
        r=$(merge_plot "${sp%%/*}" "${sp#*/}")
        if [ "$r" = "MERGE_PLOT_DONE" ]; then
            N_PLOT=$(( N_PLOT + 1 )); log "[PLOT]    $sp  -> charge/ time/ updated"
        else
            log "[PLOT NG] $sp – ${r:-no output}  (see <PMT>/merge_plot.log)"
        fi
    }

    cycle_once() {
        local key sig jobtxt dt jid scan pmt pt sp now
        declare -A JOB PJM_ACTIVE RSTAT DIRTY
        local -a CAND=() READY=()
        ST_STATE="reading the submit list"; write_status

        # 1. submitted points (later lines win: re-submission -> new job id)
        while IFS=$'\t' read -r key sig jobtxt dt; do
            [[ "$key" =~ ^[^/]+/(scan_([0-9]{8})_[0-9]{6})/([^/]+)/(theta-?[0-9]+_phi-?[0-9]+)$ ]] || continue
            [[ "${BASH_REMATCH[2]}" < "$MIN_DATE" ]] && continue
            jid=""; [[ "$jobtxt" =~ Job[[:space:]]+([0-9]+) ]] && jid=${BASH_REMATCH[1]}
            JOB[$key]=$jid
        done < "$SUBMIT_LIST"
        for key in "${!JOB[@]}"; do
            jid=${JOB[$key]}
            [ -n "${ANA[$key]+x}" ] && [ "${ANA[$key]}" = "$jid" ] && continue
            [ -n "${GIVEUP[$key]+x}" ] && [ "${GIVEUP[$key]}" = "$jid" ] && continue
            CAND+=("$key")
        done
        ST_LAST=$(date '+%m/%d %H:%M:%S')
        ST_RUNNING=0; ST_WAITROOT=0; ST_READY=0
        if (( ${#CAND[@]} == 0 )); then return; fi

        # 2. pjstat + root file stat in one login
        ST_STATE="checking jobs and root files (${#CAND[@]} point(s))"; write_status
        local out line
        out=$( {
            cat <<'EOS'
pj=$(pjstat 2>&1); echo "PJSTAT_RC:$?"
echo "$pj" | awk '$1 ~ /^[0-9]+/ {print "JOB", $1}'
EOS
            for key in "${CAND[@]}"; do
                [[ "$key" =~ ^[^/]+/([^/]+)/([^/]+)/(.+)$ ]]
                printf 'echo "ROOT %s $(stat -c %%Y "%s" 2>/dev/null || echo NONE)"\n' \
                    "$key" "$SUKAP_OUT_BASE/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/outputs/output_${BASH_REMATCH[3]}.root"
            done
            echo 'echo "NOW $(date +%s)"'
        } | sbash 2>/dev/null)
        if ! grep -q '^PJSTAT_RC:0' <<< "$out"; then
            log "[QUEUE]   cannot run pjstat on sukap – retry at the next cycle"; return
        fi
        while read -r a b c; do
            case "$a" in
                JOB)  PJM_ACTIVE[${b%%[*}]=1 ;;
                ROOT) RSTAT[$b]=$c ;;
                NOW)  now=$b ;;
            esac
        done <<< "$out"
        [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)

        for key in "${CAND[@]}"; do
            jid=${JOB[$key]}
            if [ -n "$jid" ] && [ -n "${PJM_ACTIVE[$jid]}" ]; then ST_RUNNING=$(( ST_RUNNING + 1 )); continue; fi
            local mt=${RSTAT[$key]:-NONE}
            if [ "$mt" = "NONE" ]; then
                if [ -n "$jid" ] && [ "${FAILED[$key]}" != "$jid" ]; then
                    FAILED[$key]=$jid; N_FAIL=$(( N_FAIL + 1 ))
                    log "[JOBFAIL] $key – job $jid finished but no root file (see <PMT>/scheduler/*/<PMT>/${key##*/}.err, logs/${key##*/}.log)"
                fi
                continue
            fi
            local settle=$ROOT_SETTLE; [ -z "$jid" ] && settle=$ROOT_SETTLE_NOJOB
            if (( now - mt < settle )); then ST_WAITROOT=$(( ST_WAITROOT + 1 )); continue; fi
            READY+=("$key")
        done
        ST_READY=${#READY[@]}
        (( ${#READY[@]} )) || return
        mapfile -t READY < <(printf '%s\n' "${READY[@]}" | sort)
        log "[CYCLE]   ${#READY[@]} point(s) ready (jobs running $ST_RUNNING, root not settled $ST_WAITROOT)"

        # 3. analyse points one by one, plot a PMT as soon as its points are done
        local i=0 prev="" r
        for key in "${READY[@]}"; do
            [ -f "$STOP_FILE" ] && break
            i=$(( i + 1 ))
            [[ "$key" =~ ^[^/]+/([^/]+)/([^/]+)/(.+)$ ]]
            scan=${BASH_REMATCH[1]}; pmt=${BASH_REMATCH[2]}; pt=${BASH_REMATCH[3]}; sp="$scan/$pmt"
            if [ -n "$prev" ] && [ "$prev" != "$sp" ] && [ -n "${DIRTY[$prev]}" ]; then
                do_merge_plot "$prev"; unset 'DIRTY[$prev]'
            fi
            prev=$sp
            ST_STATE="root2csv  ($i/${#READY[@]})"; ST_CUR="$sp/$pt  (charge + time fit)"; write_status
            r=$(analyse_point "$scan" "$pmt" "$pt")
            if [[ "$r" == POINT_OK* ]]; then
                ANA[$key]=${JOB[$key]}; unset 'NGCNT[$key]'
                printf '%s\t%s\t%s\n' "$key" "${JOB[$key]}" "$(date '+%F %T')" >> "$ANA_LIST"
                N_DONE=$(( N_DONE + 1 )); DIRTY[$sp]=1
                log "[DONE]    $key  (${r#POINT_OK:})"
            else
                point_ng "$key" "${JOB[$key]}" "${r#POINT_NG:}"
            fi
        done
        for sp in "${!DIRTY[@]}"; do [ -f "$STOP_FILE" ] && break; do_merge_plot "$sp"; done
        ST_CUR=""
    }

    if (( REPLOT )); then
        local -A PM=()
        for k in "${!ANA[@]}"; do [[ "$k" =~ ^[^/]+/([^/]+/[^/]+)/ ]] && PM[${BASH_REMATCH[1]}]=1; done
        log "[REPLOT]  ${#PM[@]} PMT(s)"
        for k in "${!PM[@]}"; do [ -f "$STOP_FILE" ] && break; do_merge_plot "$k"; done
    fi

    log "[START]   watching $SUBMIT_LIST"
    while [ ! -f "$STOP_FILE" ]; do
        local cstart; cstart=$(date +%s)
        cycle_once
        [ -f "$STOP_FILE" ] || waveform_stage
        ST_STATE="idle"
        while [ ! -f "$STOP_FILE" ]; do
            local next=$(( cstart + INTERVAL ))
            (( $(date +%s) >= next )) && break
            ST_NEXT=$(date -d "@$next" '+%H:%M:%S'); write_status
            sleep 1
        done
    done
    ST_STATE="stopped"; write_status
    log "[STOP]    stopped by user"
}

# ============================ Main (foreground) ======================
worker < /dev/null &
WPID=$!
exec 7>&-

cleanup() {
    touch "$STOP_FILE"
    wait "$WPID" 2>/dev/null
    rm -f "$STOP_FILE"
    sshpass -e ssh $SUKAP_COMMON -O exit "$SUKAP_USER@$SUKAP_HOST" &>/dev/null
    unset SSHPASS
}
trap 'echo; echo "Stopping (after the current point)..."; cleanup; echo "Stopped."; exit 0' INT TERM

cat <<EOF

AUS analysis started  (PID $WPID)
  input  : $SUBMIT_LIST  (scans >= $MIN_DATE)
  point  : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>/thetaX_phiY/{charge,time}/
  plots  : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>/{charge,time}/
  wave   : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>/waveformdist/   (max $WF_PER_CYCLE points per cycle)
  cycle  : every $((INTERVAL/60)) min
  log    : $LOG_FILE
Commands:  status | log | quit | help
EOF

if [ -t 0 ]; then
    printf '> '
    while kill -0 "$WPID" 2>/dev/null; do
        if read -r -t 1 cmd; then
            case "$cmd" in
                status|s|st)   cat "$STATUS_FILE" 2>/dev/null || echo "starting..." ;;
                log|l)         tail -n 30 "$LOG_FILE" ;;
                quit|q|exit|stop)
                               echo "Stopping after the current point..."
                               cleanup; echo "Stopped."; exit 0 ;;
                help|h|"?")    echo "status : show the status      log  : last 30 log lines"
                               echo "quit   : stop (after the current point)" ;;
                "")            ;;
                *)             echo "unknown command '$cmd'  (status | log | quit | help)" ;;
            esac
            printf '> '
        fi
    done
else
    wait "$WPID"
fi
cleanup