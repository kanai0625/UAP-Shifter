#!/bin/bash
# =====================================================================
#  1113-AUSjobsubmit.sh  –  automatic pyrate job submission for AUS data
#  Run on : Shifter PC (precalib@10.200.102.69), next to 1112-AUSbackup.sh
#
#  Usage :  ./1113-AUSjobsubmit.sh [-date YYYYMMDD] [-elec caendigi|hkelec] [-dry]
#           ./1113-AUSjobsubmit.sh status      (show the status from another terminal)
#
#  Input  : DONE_LIST written by 1112-AUSbackup.sh
#           (= files already rsynced DAQ -> Shifter -> sukap AND zombie-checked)
#  Every INTERVAL seconds:
#    1. read DONE_LIST, group the files by point
#         scan_YYYYMMDD_HHMMSS/<PMT>/wavesave_thetaX_phiY/waveN.dat
#    2. a point is READY when
#         - the channel set of exactly one PROFILE is in DONE_LIST
#             wave0,1,3,7.dat -> R12860_config_dat.yaml
#             wave0,1,5,7.dat -> R12860_config_dat-0157.yaml
#           (both sets present = ambiguous -> not submitted, see log), and
#         - the DAQ has moved on to another point of the same scan/PMT,
#           or the newest file of the point is older than SETTLE seconds
#    3. log in to sukap as hkpd, count the active jobs (pjstat),
#       and submit at most (MAX_ACTIVE - active) READY points with
#         runners/aus_cluster_runner-dat-hk.py --points thetaX_phiY ...
#       raw : SUKAP_RAW_BASE/<elec>/scan_.../<PMT>
#       out : SUKAP_OUT_BASE/scan_.../<PMT>
#  Submitted points are remembered (SUBMIT_LIST) and never submitted again,
#  unless the backup re-transferred one of their files (size/mtime changed).
#
#  While running, type in this terminal:  status | log | jobs | quit | help
# =====================================================================

# ============================ Settings ===============================
SUKAP_USER="hkpd"
SUKAP_HOST="10.220.11.100"          # sukap
SUKAP_PORT="22"
SUKAP_RAW_BASE="/disk03/hk04/precalib/production/aus"   # raw : <base>/<elec>/scan_.../<PMT>
SUKAP_OUT_BASE="/disk03/hk04/precalib/production/aus/processed"   # out : <base>/scan_.../<PMT>
ELEC="caendigi"                     # default, change with -elec

# UAP-Shifter on sukap (hkpd must be able to READ these)
UAP_DIR="/disk03/usr8/kanai062/UAP-Shifter"
CONDA_SH="$UAP_DIR/miniforge3/etc/profile.d/conda.sh"
CONDA_ENV="$UAP_DIR/miniforge3/envs/hkprecal-uap"
PYRATE_HOME="$UAP_DIR/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61"
RUNNER="runners/aus_cluster_runner-dat-hk.py"

# job parameters (same as the manual command)
# channel set -> template, chosen automatically per point from the transferred waveN.dat
PROFILES="${PROFILES:-0,1,3,7:R12860_config_dat.yaml 0,1,5,7:R12860_config_dat-0157.yaml}"
QUEUE="hk"
NEVENT="${NEVENT:-300000}"
ELAPSE="${ELAPSE:-2:00:00}"
MAX_ACTIVE=${MAX_ACTIVE:-100}       # hk queue limit for hkpd (all hkpd jobs are counted)

INTERVAL=${INTERVAL:-300}           # [s] between submission cycles
SETTLE=${SETTLE:-600}               # [s] last point of a scan: newest file older than this = finished
MAX_NG=3                            # a point that failed this many times is given up (see log)

LOG_DIR="$HOME/precal_transfer_logs"
DONE_LIST="$LOG_DIR/AUSbackup_done.list"        # written by 1112-AUSbackup.sh
SUBMIT_LIST="$LOG_DIR/AUSjobs_submitted.list"   # elec/scan/PMT/thetaX_phiY<TAB>signature<TAB>job id<TAB>date
STATUS_FILE="/tmp/precal_AUSjobs.status"
STOP_FILE="/tmp/precal_AUSjobs.stop"
INSTANCE_LOCK="/tmp/precal_AUSjobs.lock"

# own ControlPath: 1112-AUSbackup.sh closes its master with "-O exit" when it stops
SSH_CTRL="/tmp/precal-jobs-ssh-%r@%h-%p"
SUKAP_COMMON="-p $SUKAP_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=600"

# ============================ Helpers ================================
# hkpd's login shell may be tcsh -> always run a bash script fed on stdin
sbash() { sshpass -e ssh $SUKAP_COMMON "$SUKAP_USER@$SUKAP_HOST" 'bash -s' 7>&-; }
usage() {
    cat <<EOF
Usage:  $0 [-date YYYYMMDD] [-elec caendigi|hkelec] [-dry]
        $0 status
  -date YYYYMMDD   submit points whose files were written on/after YYYYMMDD 00:00 (default: from now)
  -elec NAME       electronics directory (default: $ELEC)
  -dry             make configs/job scripts on sukap but do not pjsub (runner --dry-run)
  status           print the status of the running submitter
Env overrides: PROFILES NEVENT ELAPSE MAX_ACTIVE INTERVAL SETTLE
EOF
}

# ============================ Arguments ==============================
if [ "$1" = "status" ]; then
    if [ -f "$STATUS_FILE" ] && ! flock -n "$INSTANCE_LOCK" true 2>/dev/null; then cat "$STATUS_FILE"
    else echo "AUS job submitter is not running."; fi
    exit 0
fi
DATE_OPT=""; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -date|--date) DATE_OPT="$2"; shift 2 ;;
        -elec|--elec) ELEC=$(echo "$2" | tr 'A-Z' 'a-z'); shift 2 ;;
        -dry|--dry|--dry-run) DRY=1; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done
if [ -n "$DATE_OPT" ]; then
    [[ "$DATE_OPT" =~ ^[0-9]{8}$ ]] && SINCE=$(date -d "$DATE_OPT 00:00:00" +%s 2>/dev/null) \
        || { echo "-date must be YYYYMMDD (got '$DATE_OPT')"; exit 1; }
else
    SINCE=$(date +%s)
fi
[[ "$ELEC" == "caendigi" || "$ELEC" == "hkelec" ]] || { echo "-elec must be caendigi or hkelec"; exit 1; }
SINCE_STR=$(date -d "@$SINCE" '+%Y-%m-%d %H:%M:%S')
RAW_DIR="$SUKAP_RAW_BASE/$ELEC"
PROF_CH=(); PROF_TPL=()
for p in $PROFILES; do
    [[ "$p" =~ ^[0-9]+(,[0-9]+)*:[^:]+$ ]] || { echo "bad PROFILES entry '$p' (expected 0,1,3,7:template.yaml)"; exit 1; }
    PROF_CH+=("${p%%:*}"); PROF_TPL+=("${p#*:}")
done
PROF_STR=$(for i in "${!PROF_CH[@]}"; do printf 'wave{%s} -> %s   ' "${PROF_CH[$i]}" "${PROF_TPL[$i]}"; done)

for c in sshpass flock; do
    command -v $c &>/dev/null || { echo "$c is not installed (sudo apt install $c)"; exit 1; }
done

exec 7>"$INSTANCE_LOCK"
flock -n 7 || { echo "1113-AUSjobsubmit.sh is already running.  (./1113-AUSjobsubmit.sh status)"; exit 1; }

# ============================ Connection / environment check =========
mkdir -p "$LOG_DIR"; touch "$DONE_LIST" "$SUBMIT_LIST"; rm -f "$STOP_FILE"
[ -s "$DONE_LIST" ] || echo "NOTE: $DONE_LIST is empty – is 1112-AUSbackup.sh running?"

read -rsp "Password for $SUKAP_USER@$SUKAP_HOST (sukap): " SUKAP_PASS; echo
export SSHPASS="$SUKAP_PASS"
sshpass -e ssh $SUKAP_COMMON -O check "$SUKAP_USER@$SUKAP_HOST" &>/dev/null \
    || sshpass -e ssh $SUKAP_COMMON -fN "$SUKAP_USER@$SUKAP_HOST" &>/dev/null 7>&-

echo "Checking the environment on sukap as $SUKAP_USER ..."
CHK=$(sbash 2>&1 <<EOF
for c in pjsub pjstat; do command -v \$c >/dev/null || echo "NG: \$c not in PATH"; done
[ -r '$UAP_DIR/$RUNNER' ]           || echo "NG: cannot read $UAP_DIR/$RUNNER"
for t in ${PROF_TPL[*]}; do [ -r "$UAP_DIR/\$t" ] || echo "NG: cannot read $UAP_DIR/\$t"; done
[ -r '$CONDA_SH' ]                  || echo "NG: cannot read $CONDA_SH"
[ -x '$CONDA_ENV/bin/python3' ]     || echo "NG: cannot run $CONDA_ENV/bin/python3"
[ -r '$PYRATE_HOME' ]               || echo "NG: cannot read $PYRATE_HOME"
[ -r '$CONDA_ENV/bin/thisroot.sh' ] || echo "NG: cannot read $CONDA_ENV/bin/thisroot.sh"
mkdir -p '$SUKAP_OUT_BASE' 2>/dev/null && [ -w '$SUKAP_OUT_BASE' ] || echo "NG: cannot write $SUKAP_OUT_BASE"
echo CHECK_END
EOF
)
if ! grep -q CHECK_END <<< "$CHK"; then
    echo "ERROR: cannot log in to $SUKAP_USER@$SUKAP_HOST (password / network?)"; echo "$CHK"; exit 1
fi
if grep -q '^NG:' <<< "$CHK"; then
    echo "ERROR: environment problem on sukap:"; grep '^NG:' <<< "$CHK" | sed 's/^/  /'; exit 1
fi

LOG_FILE="$LOG_DIR/AUSjobs_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
{
    echo "=== AUS automatic job submission ==="
    echo "Started  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Input    : $DONE_LIST  (files written after $SINCE_STR)"
    echo "Raw      : sukap:$RAW_DIR/scan_.../<PMT>"
    echo "Output   : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>"
    echo "Profiles : $PROF_STR"
    echo "Job      : queue=$QUEUE  Nevent=$NEVENT  elapse=$ELAPSE  max=$MAX_ACTIVE$( [ $DRY = 1 ] && echo '  (DRY RUN)')"
    echo "------------------------------------------------------------"
} > "$LOG_FILE"

# ============================ Worker =================================
worker() {
    declare -A SUBMITTED NGCNT GIVEUP AMBIG
    local k sig rest
    while IFS=$'\t' read -r k sig rest; do [ -n "$k" ] && SUBMITTED[$k]="$sig"; done < "$SUBMIT_LIST"

    ST_STATE="idle"; ST_LAST="-"; ST_NEXT="-"; ST_ACTIVE="-"; ST_WAITING=0; ST_READY=0
    N_SUB=0; N_NG=0

    write_status() {
        {
            echo "============ AUS job submitter status ($(date '+%H:%M:%S')) ============"
            echo "State     : $ST_STATE"
            echo "Input     : files written after $SINCE_STR  (DONE list of 1112-AUSbackup.sh)"
            echo "Output    : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>"
            echo "Jobs      : active $ST_ACTIVE / $MAX_ACTIVE   (hkpd, pjstat at last cycle)"
            echo "Points    : ready but not yet submitted $ST_READY   incomplete (waiting for channels/DAQ) $ST_WAITING"
            echo "Totals    : submitted $N_SUB   NG $N_NG$( [ $DRY = 1 ] && echo '   (DRY RUN)')"
            echo "Last cycle: $ST_LAST      Next cycle : $ST_NEXT"
            echo "Log       : $LOG_FILE"
            echo "Recent    :"
            tail -n 6 "$LOG_FILE" | sed 's/^/  /'
            echo "======================================================================"
        } > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
    }

    # count all jobs of hkpd (lines of pjstat that start with a job id)
    count_active() {
        sbash 2>/dev/null <<'EOF'
out=$(pjstat 2>/dev/null) || { echo ERR; exit; }
echo "$out" | awk '$1 ~ /^[0-9]+(\[[0-9]+\])?$/' | wc -l
EOF
    }

    # $1 scan  $2 pmt  $3 template  $4 channels  $5.. points (thetaX_phiY) -> runner output
    submit_points() {
        local scan=$1 pmt=$2 tpl=$3 chs=$4; shift 4
        local dry=""; [ $DRY = 1 ] && dry="--dry-run"
        local out="$SUKAP_OUT_BASE/$scan/$pmt"
        sbash 2>&1 <<EOF
set +u
source '$CONDA_SH' && conda activate '$CONDA_ENV' || { echo 'RUNNER_EXIT:conda'; exit; }
export PYRATE_HOME='$PYRATE_HOME'
export UAP_HOME='$UAP_DIR'
export UAP_ROOT_THISROOT='$CONDA_ENV/bin/thisroot.sh'   # job scripts source it (same as the manual)
export KOR_NTP_HOME='$UAP_DIR/kor_ntp'
export PYTHONPATH='$PYRATE_HOME':\${PYTHONPATH:-}
export LD_LIBRARY_PATH='$CONDA_ENV/lib':'$CONDA_ENV/lib/root':\${LD_LIBRARY_PATH:-}
# pjsub needs a current directory that hkpd can write to -> run from the output directory
mkdir -p '$out' && cd '$out' || { echo 'RUNNER_EXIT:cd'; exit; }
python3 '$UAP_DIR/$RUNNER' \\
  --raw-dir '$RAW_DIR/$scan/$pmt' \\
  --out-dir '$out' \\
  --scheduler-log-dir '$out/scheduler' \\
  --template '$UAP_DIR/$tpl' \\
  --channels '$chs' \\
  --queue '$QUEUE' \\
  --Nevent '$NEVENT' \\
  --elapse '$ELAPSE' \\
  --max-active-jobs '$MAX_ACTIVE' \\
  --poll-seconds 30 $dry \\
  --points $*
echo "RUNNER_EXIT:\$?"
EOF
    }

    point_ng() {   # $1 key  $2 sig  $3 message
        N_NG=$(( N_NG + 1 ))
        NGCNT[$1]=$(( ${NGCNT[$1]:-0} + 1 ))
        log "[NG]      $1 – $3   (attempt ${NGCNT[$1]}/$MAX_NG)"
        if (( ${NGCNT[$1]} >= MAX_NG )); then
            GIVEUP[$1]="$2"; log "[GAVE UP] $1 – failed $MAX_NG times, not retried any more (check by hand)"
        fi
    }

    cycle_once() {
        local rel size mt now ch scan pmt pt pk sp key
        declare -A CHMT PCH PT_LAST SP_LAST PSIG PPROF
        local -a READY=()
        ST_STATE="reading the DONE list"; write_status
        now=$(date +%s)

        # 1. group verified files by point (later lines of DONE_LIST win)
        while IFS=$'\t' read -r rel size mt; do
            [[ "$rel" =~ ^(scan_[0-9]{8}_[0-9]{6})/([^/]+)/wavesave_theta(-?[0-9]+)_phi(-?[0-9]+)/wave([0-9]+)\.dat$ ]] || continue
            pk="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/theta${BASH_REMATCH[3]}_phi${BASH_REMATCH[4]}"; ch=${BASH_REMATCH[5]}
            [[ "$mt" =~ ^[0-9]+$ ]] || continue
            (( mt >= SINCE )) || continue
            [ -n "${CHMT[$pk/$ch]}" ] || PCH[$pk]+="$ch "
            CHMT[$pk/$ch]="$size:$mt"
            PT_LAST[$pk]=1
        done < "$DONE_LIST"

        # newest mtime per point and per scan/PMT; choose the profile from the channels present
        for pk in "${!PT_LAST[@]}"; do
            local newest=0 v i c ok match=() sig
            for ch in ${PCH[$pk]}; do
                v=${CHMT[$pk/$ch]}; (( ${v#*:} > newest )) && newest=${v#*:}
            done
            PT_LAST[$pk]=$newest
            local sp=${pk%/*}
            (( newest > ${SP_LAST[$sp]:-0} )) && SP_LAST[$sp]=$newest
            for i in "${!PROF_CH[@]}"; do
                ok=1
                for c in ${PROF_CH[$i]//,/ }; do [ -n "${CHMT[$pk/$c]}" ] || { ok=0; break; }; done
                (( ok )) && match+=("$i")
            done
            if (( ${#match[@]} == 1 )); then
                i=${match[0]}; sig="${PROF_CH[$i]}"
                for c in ${PROF_CH[$i]//,/ }; do sig+=",${CHMT[$pk/$c]}"; done
                PSIG[$pk]=$sig; PPROF[$pk]=$i
            elif (( ${#match[@]} > 1 )) && [ -z "${AMBIG[$ELEC/$pk]}" ]; then
                AMBIG[$ELEC/$pk]=1
                log "[AMBIG]   $ELEC/$pk – files for several profiles (wave $(echo ${PCH[$pk]} | tr ' ' ',')) -> not submitted, submit by hand"
            fi
        done

        # 2. READY points
        ST_WAITING=0
        for pk in "${!PT_LAST[@]}"; do
            key="$ELEC/$pk"
            sig=${PSIG[$pk]}
            if [ -z "$sig" ]; then ST_WAITING=$(( ST_WAITING + 1 )); continue; fi
            [ "${SUBMITTED[$key]}" = "$sig" ] && continue
            [ "${GIVEUP[$key]}" = "$sig" ] && continue
            # finished = DAQ already wrote a later point of the same scan/PMT, or old enough
            local pl=${PT_LAST[$pk]} sl=${SP_LAST[${pk%/*}]}
            if (( sl > pl || now - pl >= SETTLE )); then
                READY+=("${PT_LAST[$pk]} $pk")
            else
                ST_WAITING=$(( ST_WAITING + 1 ))
            fi
        done
        ST_READY=${#READY[@]}
        ST_LAST=$(date '+%m/%d %H:%M:%S')
        (( ${#READY[@]} )) || return
        mapfile -t READY < <(printf '%s\n' "${READY[@]}" | sort -n | cut -d' ' -f2)   # oldest first

        # 3. free slots in the queue
        ST_STATE="checking the queue (pjstat)"; write_status
        local active; active=$(count_active)
        if ! [[ "$active" =~ ^[0-9]+$ ]]; then
            log "[QUEUE]   cannot run pjstat on sukap – retry at the next cycle"; ST_ACTIVE="?"; return
        fi
        ST_ACTIVE=$active
        local free=$(( MAX_ACTIVE - active ))
        if (( free <= 0 )); then
            log "[QUEUE]   $active/$MAX_ACTIVE jobs active – ${#READY[@]} point(s) wait for the next cycle"; return
        fi
        (( ${#READY[@]} > free )) && READY=("${READY[@]:0:free}")
        log "[CYCLE]   ${ST_READY} point(s) ready, $active/$MAX_ACTIVE jobs active -> submitting ${#READY[@]}"

        # 4. submit, grouped by scan/PMT
        declare -A GROUP
        for pk in "${READY[@]}"; do GROUP[${pk%/*}|${PPROF[$pk]}]+="${pk##*/} "; done
        local gk pi
        for gk in "${!GROUP[@]}"; do
            [ -f "$STOP_FILE" ] && break
            sp=${gk%|*}; pi=${gk##*|}
            scan=${sp%%/*}; pmt=${sp#*/}
            local pts=( ${GROUP[$gk]} ) out line rc
            ST_STATE="submitting  $sp  (${#pts[@]} point(s), ${PROF_TPL[$pi]})"; write_status
            log "[GROUP]   $sp  wave{${PROF_CH[$pi]}} -> ${PROF_TPL[$pi]}  (${#pts[@]} point(s))"
            out=$(submit_points "$scan" "$pmt" "${PROF_TPL[$pi]}" "${PROF_CH[$pi]}" "${pts[@]}")
            rc=$(grep -o 'RUNNER_EXIT:.*' <<< "$out" | tail -1); rc=${rc#RUNNER_EXIT:}
            echo "$out" | grep -v '^RUNNER_EXIT:' | sed "s|^|          [$sp] |" >> "$LOG_FILE"
            for pt in "${pts[@]}"; do
                pk="$sp/$pt"; key="$ELEC/$pk"; sig=${PSIG[$pk]}
                line=$(grep -E "^\[(OK|DRY)\][[:space:]]+$pt([[:space:]]|$)" <<< "$out" | head -1)
                if [ -n "$line" ]; then
                    local job=${line#*-> }
                    SUBMITTED[$key]="$sig"; unset 'NGCNT[$key]'
                    printf '%s\t%s\t%s\t%s\n' "$key" "$sig" "$job" "$(date '+%F %T')" >> "$SUBMIT_LIST"
                    N_SUB=$(( N_SUB + 1 ))
                    log "[SUBMIT]  $key  ->  $job"
                else
                    line=$(grep -E "^\[(FAIL|SKIP)\][[:space:]]+$pt[:[:space:]]" <<< "$out" | head -1)
                    point_ng "$key" "$sig" "${line:-runner exit $rc (see the lines above)}"
                fi
            done
        done
    }

    log "[START]   watching $DONE_LIST"
    while [ ! -f "$STOP_FILE" ]; do
        local cstart; cstart=$(date +%s)
        cycle_once
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
exec 7>&-                                     # the worker keeps the instance lock

cleanup() {
    touch "$STOP_FILE"
    wait "$WPID" 2>/dev/null
    rm -f "$STOP_FILE"
    sshpass -e ssh $SUKAP_COMMON -O exit "$SUKAP_USER@$SUKAP_HOST" &>/dev/null
    unset SSHPASS
}
trap 'echo; echo "Stopping (after the current submission)..."; cleanup; echo "Stopped."; exit 0' INT TERM

cat <<EOF

AUS job submitter started  (PID $WPID)
  input  : $DONE_LIST  (files written after $SINCE_STR)
  raw    : sukap:$RAW_DIR/scan_.../<PMT>
  output : sukap:$SUKAP_OUT_BASE/scan_.../<PMT>
  profile: $PROF_STR
  job    : queue=$QUEUE  Nevent=$NEVENT  elapse=$ELAPSE  (max $MAX_ACTIVE active)
  cycle  : every $((INTERVAL/60)) min
  log    : $LOG_FILE
Commands:  status | log | jobs | quit | help
EOF

if [ -t 0 ]; then
    printf '> '
    while kill -0 "$WPID" 2>/dev/null; do
        if read -r -t 1 cmd; then
            case "$cmd" in
                status|s|st)   cat "$STATUS_FILE" 2>/dev/null || echo "starting..." ;;
                log|l)         tail -n 30 "$LOG_FILE" ;;
                jobs|j)        echo pjstat | sbash 2>&1 | tail -n 40 ;;
                quit|q|exit|stop)
                               echo "Stopping after the current submission..."
                               cleanup; echo "Stopped."; exit 0 ;;
                help|h|"?")    echo "status : show the status      log  : last 30 log lines"
                               echo "jobs   : pjstat on sukap        quit : stop (running jobs are not touched)" ;;
                "")            ;;
                *)             echo "unknown command '$cmd'  (status | log | jobs | quit | help)" ;;
            esac
            printf '> '
        fi
    done
else
    wait "$WPID"
fi
cleanup