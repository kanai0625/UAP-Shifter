#!/bin/bash
# =====================================================================
#  1113-AUSUAP-auto.sh  –  automatic AUS point analysis + PMT plots (branch 1116)
#  Run on : Shifter PC (precalib@10.200.102.69), next to 1113-AUSjobsubmission.sh
#
#  Usage :  ./1113-AUSUAP-auto.sh [-date YYYYMMDD] [-replot] [-publish]
#           ./1113-AUSUAP-auto.sh status      (show the status from another terminal)
#
#  Input  : SUBMIT_LIST written by 1113-AUSjobsubmission.sh (point + PJM job id of aus_raw2root.py)
#  Every INTERVAL seconds:
#    1. sukap (hkpd): pjstat -> jobs still queued/running are skipped
#    2. a point is READY when its job is no longer in pjstat and
#         processed/scan_.../<PMT>/outputs/output_thetaX_phiY.root
#       exists and was not modified for ROOT_SETTLE seconds
#       (job gone but no root file -> [JOBFAIL] in the log)
#    3. per point: runners/aus_run_point.sh with the ROOT files of the job (same as the manual)
#         <PMT>/thetaX_phiY/charge/  4-step charge fit: pedestal -> SPE+2PE in 1..5 pC (SPE start = max bin above
#                                    ped + 3 sigma, 2PE/SPE = occupancy/2) -> ped+SPE+2PE (Poisson weights)
#                                    -> + backscatter (SPE free within the step-2 window)
#         <PMT>/thetaX_phiY/time/    timing fit of outputs_vcut<VCUT>mV (fixed PMT threshold VCUT mV):
#                                    prompt EMG -> late-pulse EMG -> linear background, PMT window 100 ns
#         <PMT>/thetaX_phiY/plots/   PulseStart / delta t / charge / PeakHeight + summary.txt
#         <PMT>/waveformdist/thetaX_phiY_sipm_*.png   SiPM waveforms (100) + distributions (10 %/100 %/>100 mV)
#       pmt_ch = from configs/thetaX_phiY_raw2root.yaml of the job
#    4. per PMT, after new points: runners/aus_merge_plot.py merges the point CSVs, recomputes the
#       values relative to theta=0,phi=0, and plots
#         <PMT>/charge/  aus_charge_results.csv, gain (pedestal subtracted), relative gain
#         <PMT>/time/    aus_results.csv, relative QE, arrival time, TTS (FWHM of the prompt EMG), late fraction
#       every plot: x = theta, one line per phi (every phi value in the scan)
#    5. waveform 2D plots (time vs signal, all events) for every submitted point
#       (raw waveN.dat, no need to wait for the job), at most WF_PER_CYCLE per cycle
#         <PMT>/waveformdist/thetaX_phiY_chN.png      (runners/AUSwaveform-2Dplot.py)
#    6. copy all PNGs of a PMT to the web directory (world readable) right after its plots of step 4
#       (waveform-only updates: at the end of the cycle)
#         WEB_BASE/scan_.../<PMT>/charge/        charge fits of every theta_phi + gain, relative gain
#         WEB_BASE/scan_.../<PMT>/timing/        timing fits of every theta_phi + relative QE, arrival time, TTS
#         WEB_BASE/scan_.../<PMT>/waveformdist/  thetaX_phiY_chN.png, thetaX_phiY_sipm_*.png
#         WEB_BASE/scan_.../<PMT>/plots/         thetaX_phiY_{pulsestart_chN,delta_t,charge_peakheight}.png
#       (file names unchanged; WEB_BASE = /home/hkpd/public_html/precalib/aus_daily_check)
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

UAP_DIR="/disk03/usr8/kanai062/UAP-Shifter"     # branch 1116
CONDA_SH="$UAP_DIR/miniforge3/etc/profile.d/conda.sh"
CONDA_ENV="$UAP_DIR/miniforge3/envs/hkprecal-uap"
POINT_SH="$UAP_DIR/runners/aus_run_point.sh"
MERGE_PY="$UAP_DIR/runners/aus_merge_plot.py"

VCUT="${VCUT:-2.0}"                 # fixed PMT threshold [mV] of the timing file (same as 1113-AUSjobsubmission.sh)
POINT_OPTS="${POINT_OPTS:--twin 100}"   # extra options of runners/aus_run_point.sh (see its -h)
PMT_CH_CANDIDATES="${PMT_CH_CANDIDATES:-3 5}"   # fallback: first one found in an old pyrate job config
SUKAP_RAW_BASE="/disk03/hk04/precalib/production/aus"   # raw: <base>/<elec>/scan_.../<PMT>/wavesave_thetaX_phiY
WAVEFORM_PY="$UAP_DIR/runners/AUSwaveform-2Dplot.py"      # git branch 1107
WF_OPTS="${WF_OPTS:-}"              # extra options for AUSwaveform-2Dplot.py, e.g. "--nevent 100000"
WF_PER_CYCLE=${WF_PER_CYCLE:-10}    # waveform points per cycle (root2csv of new points is not delayed)
WEB_BASE="/home/hkpd/public_html/precalib/aus_daily_check"   # PNG copies: <base>/scan_.../<PMT>/{charge,timing,waveformdist}

INTERVAL=${INTERVAL:-300}           # [s] between cycles
ROOT_SETTLE=${ROOT_SETTLE:-60}      # [s] root file unchanged for this long (job id known)
ROOT_SETTLE_NOJOB=${ROOT_SETTLE_NOJOB:-600}  # [s] same, when no job id is known
MAX_NG=3                            # a point that failed this many times is given up

LOG_DIR="$HOME/precal_transfer_logs"
SUBMIT_LIST="$LOG_DIR/AUSjobs_raw2root_submitted.list"   # written by 1113-AUSjobsubmission.sh
ANA_LIST="$LOG_DIR/AUSana_raw2root_done.list"            # key<TAB>job id<TAB>date
WF_LIST="$LOG_DIR/AUSwave_done.list"            # key<TAB>date   (waveform 2D plots made)
STATUS_FILE="/tmp/precal_AUSana.status"
STOP_FILE="/tmp/precal_AUSana.stop"
INSTANCE_LOCK="/tmp/precal_AUSana.lock"

SSH_CTRL="/tmp/precal-ana-ssh-%r@%h-%p"
SUKAP_COMMON="-p $SUKAP_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=600"

# ============================ Helpers ================================
sbash() { sshpass -e ssh $SUKAP_COMMON "$SUKAP_USER@$SUKAP_HOST" 'bash -s' 7>&-; }
usage() {
    cat <<EOF
Usage:  $0 [-date YYYYMMDD] [-replot] [-publish]
        $0 status
  -date YYYYMMDD   only scans scan_YYYYMMDD_* on/after this date (default: all submitted points)
  -replot          remake merged CSVs + plots for every PMT once at start (and copy them to the web dir)
  -publish         copy the PNGs of every analysed PMT to the web dir once at start
  status           print the status of the running analysis
Env overrides: VCUT POINT_OPTS PMT_CH_CANDIDATES WF_OPTS WF_PER_CYCLE INTERVAL ROOT_SETTLE
EOF
}

# remote environment (prepended to every remote script)
remote_env() {
    cat <<EOF
set +u
source '$CONDA_SH' && conda activate '$CONDA_ENV' || { echo 'REMOTE_ERR:conda'; exit; }
export UAP_HOME='$UAP_DIR'
export PYTHONPATH='$UAP_DIR':\${PYTHONPATH:-}
export MPLBACKEND=Agg
EOF
}

# ============================ Arguments ==============================
if [ "$1" = "status" ]; then
    if [ -f "$STATUS_FILE" ] && ! flock -n "$INSTANCE_LOCK" true 2>/dev/null; then cat "$STATUS_FILE"
    else echo "AUS analysis is not running."; fi
    exit 0
fi
DATE_OPT=""; REPLOT=0; PUBLISH=0
while [ $# -gt 0 ]; do
    case "$1" in
        -date|--date) DATE_OPT="$2"; shift 2 ;;
        -replot|--replot) REPLOT=1; shift ;;
        -publish|--publish) PUBLISH=1; shift ;;
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
[ -s "$SUBMIT_LIST" ] || echo "NOTE: $SUBMIT_LIST is empty – has 1113-AUSjobsubmission.sh submitted anything?"

read -rsp "Password for $SUKAP_USER@$SUKAP_HOST (sukap): " SUKAP_PASS; echo
export SSHPASS="$SUKAP_PASS"
sshpass -e ssh $SUKAP_COMMON -O check "$SUKAP_USER@$SUKAP_HOST" &>/dev/null \
    || sshpass -e ssh $SUKAP_COMMON -fN "$SUKAP_USER@$SUKAP_HOST" &>/dev/null 7>&-

echo "Checking the environment on sukap as $SUKAP_USER ..."
CHK=$( { remote_env; cat <<EOF
for f in '$POINT_SH' '$MERGE_PY' '$UAP_DIR/runners/aus_root2csv.py' '$UAP_DIR/uap/fit/aus_timing_late.py' \
         '$UAP_DIR/config/aus_root2csv_charge_default.yaml' '$UAP_DIR/config/aus_root2csv_emg_default.yaml' '$WAVEFORM_PY'; do
    [ -r "\$f" ] || echo "NG: cannot read \$f  (UAP-Shifter branch 1116?)"
done
python3 -c 'import uproot, iminuit, scipy, yaml, pandas, matplotlib, uap.engine.csv2plot, uap.engine.root2csv' 2>&1 | tail -2 | sed 's/^/NG: python: /'
mkdir -p '$SUKAP_OUT_BASE' 2>/dev/null && [ -w '$SUKAP_OUT_BASE' ] || echo "NG: cannot write $SUKAP_OUT_BASE"
mkdir -p '$WEB_BASE' 2>/dev/null && [ -w '$WEB_BASE' ] && chmod a+rx '$WEB_BASE' 2>/dev/null || echo "NG: cannot write $WEB_BASE"
echo CHECK_END
EOF
} | sbash 2>&1)
if ! grep -q CHECK_END <<< "$CHK"; then
    echo "ERROR: cannot log in to $SUKAP_USER@$SUKAP_HOST (password / network?)"; echo "$CHK"; exit 1
fi
if grep -q '^NG:' <<< "$CHK"; then
    echo "ERROR: environment problem on sukap:"; grep '^NG:' <<< "$CHK" | sed 's/^/  /'; exit 1
fi

LOG_FILE="$LOG_DIR/AUSana_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
{
    echo "=== AUS automatic analysis (root2csv + csv2plot) ==="
    echo "Started  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Input    : $SUBMIT_LIST  (scans >= $MIN_DATE)"
    echo "Base     : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>"
    echo "Point    : runners/aus_run_point.sh  -vcut $VCUT $POINT_OPTS"
    echo "Web      : sukap:$WEB_BASE/scan_.../<PMT>/{charge,timing,waveformdist,plots}"
    echo "------------------------------------------------------------"
} > "$LOG_FILE"

# ============================ Worker =================================
worker() {
    declare -A ANA NGCNT GIVEUP FAILED WF WNG PUBQ
    local k j rest
    while IFS=$'\t' read -r k j rest; do [ -n "$k" ] && ANA[$k]="$j"; done < "$ANA_LIST"
    while IFS=$'\t' read -r k rest; do [ -n "$k" ] && WF[$k]=1; done < "$WF_LIST"

    ST_STATE="idle"; ST_LAST="-"; ST_NEXT="-"; ST_CUR=""
    ST_RUNNING=0; ST_READY=0; ST_WAITROOT=0; N_DONE=0; N_NG=0; N_PLOT=0; N_FAIL=0
    ST_WFLEFT=0; N_WF=0; N_WFNG=0; N_PUB=0

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
            echo "Web copy  : $N_PUB PMT update(s)  -> $WEB_BASE"
            echo "Last cycle: $ST_LAST      Next cycle : $ST_NEXT"
            echo "Log       : $LOG_FILE"
            echo "Recent    :"
            tail -n 6 "$LOG_FILE" | sed 's/^/  /'
            echo "======================================================================"
        } > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
    }

    # $1 elec  $2 scan  $3 pmt  $4 point  -> prints POINT_OK / POINT_NG:<msg>
    analyse_point() {
        local elec=$1 scan=$2 pmt=$3 pt=$4
        local pd="$SUKAP_OUT_BASE/$scan/$pmt" raw="$SUKAP_RAW_BASE/$1/$2/$3"
        { remote_env; cat <<EOF
pd='$pd'; pt='$pt'; root="\$pd/outputs/output_\$pt.root"; vroot="\$pd/outputs_vcut${VCUT}mV/output_\$pt.root"
[ -s "\$root" ] || { echo "POINT_NG:root file missing"; exit; }
pch=\$(awk '/^pmt_ch:/ {print \$2}' "\$pd/configs/\${pt}_raw2root.yaml" 2>/dev/null)
if [ -z "\$pch" ]; then                     # old pyrate job config
    cfg=\$(ls "\$pd"/configs/*_\${pt}_dat.yaml 2>/dev/null | head -1)
    for c in $PMT_CH_CANDIDATES; do
        [ -n "\$cfg" ] && grep -qE "^[[:space:]]*ch\$c:" "\$cfg" && { pch=\$c; break; }
    done
fi
[ -n "\$pch" ] || { echo "POINT_NG:cannot find the pmt channel (configs/\${pt}_raw2root.yaml)"; exit; }
mkdir -p "\$pd/\$pt" "\$pd/waveformdist" || { echo "POINT_NG:cannot create \$pd/\$pt"; exit; }
rm -rf "\$pd/\$pt/charge" "\$pd/\$pt/time" "\$pd/\$pt/time_nsigma" "\$pd/\$pt/plots"
bash '$POINT_SH' -no-conda -raw '$raw' -point "\$pt" -serial '$pmt' -pmt-ch "\$pch" \
    -root "\$root" -vroot "\$vroot" -vcut '$VCUT' -out "\$pd/\$pt" \
    -wf-out "\$pd/waveformdist" -wf-prefix "\${pt}_" $POINT_OPTS > "\$pd/\$pt.log" 2>&1
if grep -q '^AUS_POINT_OK' "\$pd/\$pt.log"; then
    echo "POINT_OK:pmt_ch=\$pch\$( [ -s "\$vroot" ] || echo ', no vcut file: timing from the main ROOT file')"
else
    echo "POINT_NG:\$(grep -E 'FAILED|missing|errors' "\$pd/\$pt.log" | head -2 | tr '\n' ' ') (see \$pd/\$pt.log)"
fi
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
                WF[$key]=1; N_WF=$(( N_WF + 1 )); PUBQ[$sc/$pm]=1
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

    # copy all PNGs of one PMT to the web dir; $1 scan  $2 pmt  -> PUB_OK:<n> / PUB_NG:<msg>
    publish_pmt() {
        local pd="$SUKAP_OUT_BASE/$1/$2" w="$WEB_BASE/$1/$2"
        sbash 2>&1 <<EOF | grep -E '^PUB_' | tail -1
shopt -s nullglob globstar
mkdir -p '$w/charge' '$w/timing' '$w/waveformdist' '$w/plots' || { echo 'PUB_NG:cannot create $w'; exit; }
n=0
cp_png() { local dst=\$1; shift; local f; for f in "\$@"; do [ -f "\$f" ] && cp -pu "\$f" "\$dst/" && n=\$((n+1)); done; }
cp_png '$w/charge'       '$pd'/theta*_phi*/charge/figures/**/*.png '$pd'/charge/*.png
cp_png '$w/timing'       '$pd'/theta*_phi*/time/figures/**/*.png   '$pd'/time/*.png
cp_png '$w/waveformdist' '$pd'/waveformdist/*.png
mkdir -p '$w/plots'
for d in '$pd'/theta*_phi*/plots; do      # per-point plots: same names in every point -> point prefix
    p=\$(basename "\$(dirname "\$d")")
    for f in "\$d"/*.png; do [ -f "\$f" ] && cp -pu "\$f" '$w/plots/'"\${p}_\$(basename "\$f")" && n=\$((n+1)); done
done
chmod -R a+rX '$WEB_BASE/$1' 2>/dev/null
echo "PUB_OK:\$n"
EOF
    }

    publish_one() {   # $1 "scan/pmt"
        local sp=$1 r
        ST_STATE="copying PNGs to the web dir  $sp"; ST_CUR=""; write_status
        r=$(publish_pmt "${sp%%/*}" "${sp#*/}")
        if [[ "$r" == PUB_OK* ]]; then
            N_PUB=$(( N_PUB + 1 ))
            log "[WEB]     $sp  -> aus_daily_check/$sp/{charge,timing,waveformdist,plots}  (${r#PUB_OK:} png)"
        else
            log "[WEB NG]  $sp – ${r#PUB_NG:}"
        fi
        unset 'PUBQ[$sp]'
    }

    publish_pending() {
        local sp
        for sp in "${!PUBQ[@]}"; do
            [ -f "$STOP_FILE" ] && break
            publish_one "$sp"
        done
    }

    # $1 scan  $2 pmt
    merge_plot() {
        local pd="$SUKAP_OUT_BASE/$1/$2"
        { remote_env; echo "python3 '$MERGE_PY' '$pd' '$2' > '$pd/merge_plot.log' 2>&1; tail -1 '$pd/merge_plot.log'"; } \
            | sbash 2>&1 | tail -1
    }

    point_ng() {   # $1 key  $2 job  $3 message
        N_NG=$(( N_NG + 1 ))
        NGCNT[$1]=$(( ${NGCNT[$1]:-0} + 1 ))
        log "[NG]      $1 – $3   (attempt ${NGCNT[$1]}/$MAX_NG)"
        if (( ${NGCNT[$1]} >= MAX_NG )); then
            GIVEUP[$1]="$2"; log "[GAVE UP] $1 – failed $MAX_NG times (see <PMT>/thetaX_phiY.log and <PMT>/thetaX_phiY/logs/)"
        fi
    }

    do_merge_plot() {   # $1 "scan/pmt"
        local sp=$1 r
        ST_STATE="plotting  $sp"; ST_CUR=""; write_status
        r=$(merge_plot "${sp%%/*}" "${sp#*/}")
        if [ "$r" = "MERGE_PLOT_DONE" ]; then
            N_PLOT=$(( N_PLOT + 1 )); log "[PLOT]    $sp  -> charge/ time/ updated"
            publish_one "$sp"     # copy this PMT to the web dir right away (not at the end of the cycle)
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
            ST_STATE="point analysis  ($i/${#READY[@]})"; ST_CUR="$sp/$pt  (charge + timing fit + plots + SiPM)"; write_status
            r=$(analyse_point "${key%%/*}" "$scan" "$pmt" "$pt")
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
    if (( PUBLISH )); then
        for k in "${!ANA[@]}" "${!WF[@]}"; do
            [[ "$k" =~ ^[^/]+/(scan_([0-9]{8})_[0-9]{6}/[^/]+)/ ]] || continue
            [[ "${BASH_REMATCH[2]}" < "$MIN_DATE" ]] && continue
            PUBQ[${BASH_REMATCH[1]}]=1
        done
        log "[PUBLISH] ${#PUBQ[@]} PMT(s)"
    fi
    (( ${#PUBQ[@]} )) && publish_pending

    log "[START]   watching $SUBMIT_LIST"
    while [ ! -f "$STOP_FILE" ]; do
        local cstart; cstart=$(date +%s)
        cycle_once
        [ -f "$STOP_FILE" ] || waveform_stage
        [ -f "$STOP_FILE" ] || publish_pending
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
  point  : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>/thetaX_phiY/{charge,time,plots}/   (aus_run_point.sh -vcut $VCUT $POINT_OPTS)
  plots  : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>/{charge,time}/
  wave   : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>/waveformdist/   (max $WF_PER_CYCLE points per cycle)
  web    : sukap:$WEB_BASE/scan_.../<PMT>/{charge,timing,waveformdist,plots}
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