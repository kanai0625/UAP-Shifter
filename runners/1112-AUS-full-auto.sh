#!/bin/bash
# =====================================================================
#  Reserved Auto Copy & Verification Tool   (AUS DAQ PC -> Shifter PC)
#  Run on : Shifter PC (precalib@10.200.102.69)
#
#  Flow (one file at a time, the RAID on the Shifter PC does one job at a time):
#    for res = 1..4, for (theta,phi) in all points, for waveN in PMT channels:
#      1. rsync  AUS DAQ PC -> Shifter HDD
#           - already on both sides            -> skip
#           - otherwise wait until the DAQ file exists and its size/mtime are
#             unchanged for STABLE_WAIT s (= write finished), then rsync
#      2. verify AUS DAQ PC <-> Shifter      (MD5 + cmp)
#      3. rsync  Shifter HDD -> sukap
#      4. verify Shifter <-> sukap           (MD5 + cmp)
#  Time input: HHMMSS -> exactly scan_YYYYMMDD_HHMMSS
#              HH     -> the scan dir (with the PMT label) whose start time is closest to
#                        YYYYMMDD HH:00:00 within ±30 min (also across midnight)
#  Priority  : while this script runs, the KOR auto script does no disk work
#              (it waits until all AUS reservations are finished).
#  The progress window stays open until ALL reservations are finished.
#  A log is kept in ~/precal_transfer_logs/.
# =====================================================================

# ============================ Settings ===============================
SSH_USER="hyperkaus"
SSH_HOST="10.200.102.67"            # AUS DAQ PC (hk-precal-aus1)
SSH_PORT="22"

DEFAULT_PARENT_DIR="/home/hyperkaus/WaveDumpSaves"
DEFAULT_SAVE_BASE="/media/precalib/rawdata/production/aus"   # -> <base>/<electronics>/

SUKAP_USER="hkpd"
SUKAP_HOST="10.220.11.100"         # sukap
SUKAP_PORT="22"
DEFAULT_SUKAP_BASE="/disk03/hk04/precalib/production/aus"     # -> <base>/<electronics>/
DEFAULT_ELEC="caendigi"
DEFAULT_THETA="0,10,20,30,40,50,60,70,80"
DEFAULT_PHI="0,90,180,270"
WAVES_PMT1="0 1 3 7"     # waveN.dat channels for PMT1
WAVES_PMT2="0 1 5 7"     # waveN.dat channels for PMT2

NUM_RES=4            # number of reservation slots
STABLE_WAIT=5        # [s] file is complete when size & mtime are unchanged for this long
POLL_INTERVAL=5      # [s] polling interval while waiting for the DAQ to create a file
RSYNC_RETRY=3        # rsync attempts per file
TIME_WINDOW=1800     # [s] HH mode: take scan_YYYYMMDD_HHMMSS within ±30 min of YYYYMMDD HH:00:00
GIVE_UP_GRACE=600    # [s] HH mode: give up if nothing matched by (HH:00 + 30 min + this)
CMP_CHECK=1          # 1: byte-by-byte cmp after MD5 match (DAQ and sukap; reads every file again over the network)
LOG_DIR="$HOME/precal_transfer_logs"
IO_LOCK="/tmp/precal_rawdata_io.lock"   # shared with the KOR auto script: one heavy disk job at a time
IO_NAME="AUS"
AUS_ACTIVE_LOCK="/tmp/precal_aus_active.lock"   # held while AUS runs -> KOR auto script waits
TITLE="AUS Auto Transfer"

SSH_CTRL="/tmp/precal-ssh-%r@%h-%p"
SUKAP_COMMON="-p $SUKAP_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=/tmp/precal-ssh-%r@%h-%p -o ControlPersist=600"
SSH_COMMON="-p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=600"

# ============================ Helpers ================================
rssh()      { ssh $SSH_COMMON "$SSH_USER@$SSH_HOST" "$@" 8>&- 9>&-; }
sssh()      { sshpass -e ssh $SUKAP_COMMON "$SUKAP_USER@$SUKAP_HOST" "$@" 8>&- 9>&-; }
fmt_bytes() { awk -v b="${1:-0}" 'BEGIN{ if(b>=1099511627776)printf "%.2f TB",b/1099511627776; else if(b>=1073741824)printf "%.2f GB",b/1073741824; else if(b>=1048576)printf "%.1f MB",b/1048576; else if(b>=1024)printf "%.1f KB",b/1024; else printf "%d B",b }'; }
fmt_dur()   { local s=${1:-0}; printf "%02d:%02d:%02d" $((s/3600)) $((s%3600/60)) $((s%60)); }
trim()      { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
esc()       { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi
if ! command -v sshpass &> /dev/null; then
    zenity --error --title="Missing Dependency" --width=500 \
        --text="sshpass is not installed.\nPlease install it using: sudo apt install sshpass" 2>/dev/null
    exit 1
fi

# ============================ 1. Input forms =========================
# (a) global settings – one small window
INPUTS=$(zenity --forms --title="$TITLE – Global Settings" --width=720 --separator="|" \
    --text="Global settings (leave blank to use the default)." \
    --add-entry="Remote Parent Dir   [default: $DEFAULT_PARENT_DIR]" \
    --add-entry="Local Save Base Dir   [default: $DEFAULT_SAVE_BASE]" \
    --add-entry="Theta (deg)   [default: $DEFAULT_THETA]" \
    --add-entry="Phi (deg)   [default: $DEFAULT_PHI]" \
    --add-entry="sukap Target Base Dir   [default: $DEFAULT_SUKAP_BASE]" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "Processing cancelled."
    exit 0
fi
# (b) reservations – one small window each; blank Date or Cancel = no more reservations
for (( i=1; i<=NUM_RES; i++ )); do
    R=$(zenity --forms --title="$TITLE – Reservation $i / $NUM_RES" --width=720 --separator="|" \
        --text="Reservation $i of $NUM_RES\nLeave Date blank (or press Cancel) when there are no more reservations." \
        --add-entry="Date (yyyymmdd)" \
        --add-entry="Time   [HHMMSS = exact,  HH = closest scan within ±30 min of HH:00]" \
        --add-entry="PMT   [1 or 2]  (PMT1: wave 0,1,3,7 / PMT2: wave 0,1,5,7)" \
        --add-entry="PMT Label   [e.g. EM5650-H]" \
        --add-entry="Electronics   [caendigi / hkelec, default: $DEFAULT_ELEC]" 2>/dev/null) || R=""
    [ -z "$(trim "${R%%|*}")" ] && R=""
    if [ -z "$R" ]; then
        for (( j=i; j<=NUM_RES; j++ )); do INPUTS+="|||||"; done
        break
    fi
    INPUTS+="|$R"
done

# ============================ 2. Parse & validate ====================
IFS='|' read -r -a F <<< "$INPUTS"

PARENT_DIR=$(trim "${F[0]}"); PARENT_DIR=${PARENT_DIR:-$DEFAULT_PARENT_DIR}; PARENT_DIR=${PARENT_DIR%/}
SAVE_BASE=$(trim "${F[1]}");  SAVE_BASE=${SAVE_BASE:-$DEFAULT_SAVE_BASE};    SAVE_BASE=${SAVE_BASE%/}
THETA=$(trim "${F[2]}" | tr -d ' '); THETA=${THETA:-$DEFAULT_THETA}
PHI=$(trim "${F[3]}" | tr -d ' ');   PHI=${PHI:-$DEFAULT_PHI}
SUKAP_BASE=$(trim "${F[4]}"); SUKAP_BASE=${SUKAP_BASE:-$DEFAULT_SUKAP_BASE}; SUKAP_BASE=${SUKAP_BASE%/}

if ! [[ "$THETA" =~ ^[0-9]+(,[0-9]+)*$ ]] || ! [[ "$PHI" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    zenity --error --title="$TITLE" --width=500 \
        --text="Theta / Phi must be comma-separated integers.\n\nTheta: $(esc "$THETA")\nPhi: $(esc "$PHI")" 2>/dev/null
    exit 1
fi
IFS=',' read -r -a THETA_ARRAY <<< "$THETA"
IFS=',' read -r -a PHI_ARRAY <<< "$PHI"
N_ANGLES=$(( ${#THETA_ARRAY[@]} * ${#PHI_ARRAY[@]} ))

declare -a R_TMODE R_TARGET R_HH R_DATE R_TIME R_PMT R_PLABEL R_WAVES R_NFILES R_ELEC R_SCAN R_STATE R_REASON R_SAVE R_SUKAP R_LABEL
N_ACTIVE=0
for (( i=1; i<=NUM_RES; i++ )); do
    k=$(( 5 + (i-1)*5 ))
    d=$(trim "${F[k]}"); t=$(trim "${F[k+1]}"); pmt=$(trim "${F[k+2]}" | tr -d ' ' | tr 'A-Z' 'a-z'); pmt=${pmt#pmt}
    lab=$(trim "${F[k+3]}" | tr -d ' ')
    el=$(trim "${F[k+4]}" | tr 'A-Z' 'a-z'); el=${el:-$DEFAULT_ELEC}

    if [ -z "$d$t" ]; then R_STATE[i]="empty"; continue; fi

    reason=""
    [[ "$d" =~ ^[0-9]{8}$ ]]                       || reason+="Date must be yyyymmdd. "
    if [[ "$t" =~ ^[0-9]{6}$ ]]; then tmode="exact"
    elif [[ "$t" =~ ^[0-9]{1,2}$ ]] && (( 10#$t <= 23 )); then tmode="hour"
    else tmode=""; reason+="Time must be HHMMSS or HH (00-23). "; fi
    [[ "$pmt" == "1" || "$pmt" == "2" ]]           || reason+="PMT must be 1 or 2. "
    [[ -n "$lab" && "$lab" != */* ]]               || reason+="PMT Label is required (e.g. EM5650-H). "
    [[ "$el" == "caendigi" || "$el" == "hkelec" ]] || reason+="Electronics must be caendigi or hkelec. "

    R_DATE[i]=$d; R_TIME[i]=$t; R_PMT[i]=$pmt; R_PLABEL[i]=$lab; R_ELEC[i]=$el
    if [ -n "$reason" ]; then R_STATE[i]="invalid"; R_REASON[i]=$reason; continue; fi

    R_TMODE[i]=$tmode
    if [ "$tmode" = "exact" ]; then
        R_SCAN[i]="scan_${d}_${t}"; SCANTXT="${R_SCAN[i]}"
    else
        R_HH[i]=$(printf "%02d" $((10#$t)))
        R_TARGET[i]=$(date -d "$d ${R_HH[i]}:00:00" +%s)
        R_SCAN[i]=""; SCANTXT="scan near $d ${R_HH[i]}:00 (±$((TIME_WINDOW/60)) min)"
    fi
    if [ "$pmt" = "1" ]; then R_WAVES[i]=$WAVES_PMT1; else R_WAVES[i]=$WAVES_PMT2; fi
    R_NFILES[i]=$(( N_ANGLES * 4 ))
    R_SAVE[i]="$SAVE_BASE/$el"
    R_SUKAP[i]="$SUKAP_BASE/$el"
    R_LABEL[i]="$SCANTXT / $lab  ·  PMT$pmt (wave ${R_WAVES[i]// /,})  ·  $el  (${R_NFILES[i]} files)"
    R_STATE[i]="active"
    N_ACTIVE=$(( N_ACTIVE + 1 ))
done

if [ "$N_ACTIVE" -eq 0 ]; then
    zenity --error --title="$TITLE" --width=500 --text="No valid reservation was entered." 2>/dev/null
    exit 1
fi

# list of relative paths of reservation $1 (order: theta -> phi -> wave)
rel_paths() {
    local th ph w
    for th in "${THETA_ARRAY[@]}"; do for ph in "${PHI_ARRAY[@]}"; do for w in ${R_WAVES[$1]}; do
        printf '%s\n' "${R_SCAN[$1]}/${R_PLABEL[$1]}/wavesave_theta${th}_phi${ph}/wave${w}.dat"
    done; done; done
}

# HH mode: closest scan dir (that contains the PMT label dir) within ±TIME_WINDOW of the target
#   prints "<scan_dir> <|diff| s> <number of candidates>", nothing if none
find_scan() {
    local tgt=${R_TARGET[$1]} lab=${R_PLABEL[$1]} dp dc dn line d t e diff best="" bestd=999999 nc=0
    dp=$(date -d "@$(( tgt - 86400 ))" +%Y%m%d); dc=$(date -d "@$tgt" +%Y%m%d); dn=$(date -d "@$(( tgt + 86400 ))" +%Y%m%d)
    while IFS= read -r line; do
        line=${line%%/*}
        [[ "$line" =~ ^scan_([0-9]{8})_([0-9]{6})$ ]] || continue
        d=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
        e=$(date -d "$d ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null) || continue
        diff=$(( e - tgt )); diff=${diff#-}
        (( diff <= TIME_WINDOW )) || continue
        nc=$(( nc + 1 ))
        (( diff < bestd )) && { best=$line; bestd=$diff; }
    done < <(rssh "cd '$PARENT_DIR' 2>/dev/null && ls -1d scan_${dp}_*/'$lab' scan_${dc}_*/'$lab' scan_${dn}_*/'$lab' 2>/dev/null" 2>/dev/null)
    [ -n "$best" ] && echo "$best $bestd $nc"
}
fmt_diff() { local s=$1; printf "%dm%02ds" $((s/60)) $((s%60)); }

# ============================ 3. Connection check ====================
ssh $SSH_COMMON -O check "$SSH_USER@$SSH_HOST" &>/dev/null || ssh $SSH_COMMON -fN "$SSH_USER@$SSH_HOST" &>/dev/null
CHK=$(rssh "test -d '$PARENT_DIR' && echo DIR_OK || echo DIR_NG" 2>/dev/null); RC=$?
if [ $RC -eq 255 ]; then
    zenity --error --title="SSH Connection Error" --width=600 \
        --text="Cannot connect to $SSH_USER@$SSH_HOST (port $SSH_PORT) without a password.\n\nCheck the network, or register the SSH key once on this PC:\n    ssh-copy-id -p $SSH_PORT $SSH_USER@$SSH_HOST" 2>/dev/null
    exit 1
fi
if [ "$CHK" != "DIR_OK" ]; then
    zenity --error --title="Remote Directory Not Found" --width=600 \
        --text="Remote directory does not exist on $SSH_HOST:\n$(esc "$PARENT_DIR")" 2>/dev/null
    exit 1
fi

SUKAP_PASS=$(zenity --entry --hide-text --title="$TITLE – sukap" --width=450 \
    --text="Password for $SUKAP_USER@$SUKAP_HOST (sukap)" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$SUKAP_PASS" ]; then
    echo "Processing cancelled."
    exit 0
fi
export SSHPASS="$SUKAP_PASS"
sshpass -e ssh $SUKAP_COMMON -O check "$SUKAP_USER@$SUKAP_HOST" &>/dev/null || sshpass -e ssh $SUKAP_COMMON -fN "$SUKAP_USER@$SUKAP_HOST" &>/dev/null
SUKAP_AVAIL=$(sssh "mkdir -p '$SUKAP_BASE/caendigi' '$SUKAP_BASE/hkelec' && df -h '$SUKAP_BASE' | tail -n 1 | awk '{print \$4}'" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$SUKAP_AVAIL" ]; then
    zenity --error --title="sukap Connection Error" --width=600 \
        --text="Failed to connect to $SUKAP_USER@$SUKAP_HOST or to create\n$(esc "$SUKAP_BASE")\n\nPlease check the password and the network." 2>/dev/null
    unset SSHPASS
    exit 1
fi

# ============================ 4. Pre-scan & confirmation =============
CHECK_MODE="MD5 hash comparison"
[ "$CMP_CHECK" = "1" ] && CHECK_MODE+=" + cmp (byte-by-byte)"

CT="<b><big>$(esc "$TITLE")</big></b>\n\n"
CT+="<tt>Source : $(esc "$SSH_USER@$SSH_HOST:$PARENT_DIR")\n"
CT+="Dest   : $(esc "$SAVE_BASE")/&lt;electronics&gt;/\n"
CT+="Upload : $(esc "$SUKAP_USER@$SUKAP_HOST:$SUKAP_BASE")/&lt;electronics&gt;/   (free $SUKAP_AVAIL)\n"
CT+="Flow   : per file  DAQ→Shifter → verify → Shifter→sukap → verify\n"
CT+="Angles : theta $(esc "$THETA")  /  phi $(esc "$PHI")\n"
CT+="Check  : $(esc "$CHECK_MODE")\n"
CT+="Disk   : one disk job at a time; KOR auto transfer waits until all AUS reservations are done\n"
CT+="Time   : HHMMSS = exact scan dir,  HH = closest scan within ±$((TIME_WINDOW/60)) min of HH:00</tt>\n\n"

for (( i=1; i<=NUM_RES; i++ )); do
    case "${R_STATE[i]}" in
    empty)
        CT+="<b>[Res $i]</b>  <span foreground='gray'>empty</span>\n" ;;
    invalid)
        CT+="<b>[Res $i]</b>  <span foreground='red'><b>INVALID – skipped:</b> $(esc "${R_REASON[i]}")</span>\n" ;;
    active)
        if ! mkdir -p "${R_SAVE[i]}" 2>/dev/null; then
            R_STATE[i]="invalid"; R_REASON[i]="Cannot create save dir ${R_SAVE[i]}"
            CT+="<b>[Res $i]</b>  <span foreground='red'><b>INVALID – skipped:</b> $(esc "${R_REASON[i]}")</span>\n"
            N_ACTIVE=$(( N_ACTIVE - 1 )); continue
        fi
        MATCHTXT=""
        if [ "${R_TMODE[i]}" = "hour" ]; then
            res=$(find_scan "$i")
            if [ -n "$res" ]; then
                read -r R_SCAN[i] bd nc <<< "$res"
                MATCHTXT="   match now: ${R_SCAN[i]} (Δ $(fmt_diff "$bd"))"
                (( nc > 1 )) && MATCHTXT+=" <span foreground='#e65100'>[$nc candidates – closest taken]</span>"
            else
                dl=$(( R_TARGET[i] + TIME_WINDOW + GIVE_UP_GRACE ))
                if (( $(date +%s) > dl )); then
                    MATCHTXT="   <span foreground='red'>match now: none, and the ±$((TIME_WINDOW/60)) min window is already over – will be skipped</span>"
                else
                    MATCHTXT="   match now: none yet – will wait until $(date -d "@$dl" '+%m/%d %H:%M')"
                fi
            fi
        fi
        mapfile -t RELS < <( [ -n "${R_SCAN[i]}" ] && rel_paths "$i" )
        lcount=0
        for rel in "${RELS[@]}"; do [ -f "${R_SAVE[i]}/$rel" ] && lcount=$(( lcount + 1 )); done
        rcount=0; [ ${#RELS[@]} -gt 0 ] && rcount=$(printf '%s\n' "${RELS[@]}" | rssh "cd '$PARENT_DIR' && n=0; while IFS= read -r f; do [ -f \"\$f\" ] && n=\$((n+1)); done; echo \$n" 2>/dev/null)
        avail=$(df -h --output=avail "${R_SAVE[i]}" 2>/dev/null | tail -n 1 | tr -d ' ')
        CT+="<b>[Res $i]</b>  <span foreground='#2e7d32'><b>will run</b></span>   $(esc "${R_LABEL[i]%%  ·*}")   PMT${R_PMT[i]} (wave ${R_WAVES[i]// /,})   ${R_ELEC[i]}\n"
        CT+="<tt>   save: $(esc "${R_SAVE[i]}") (free ${avail:-N/A})   present: remote ${rcount:-?}/${R_NFILES[i]}, local ${lcount}/${R_NFILES[i]}$MATCHTXT</tt>\n"
        [ "${R_TMODE[i]}" = "hour" ] && R_SCAN[i]=""      # re-resolved when the reservation starts
        ;;
    esac
done

if [ "$N_ACTIVE" -le 0 ]; then
    zenity --error --title="$TITLE" --width=500 --text="No valid reservation was entered." 2>/dev/null
    exit 1
fi
CT+="\nProcessed in order; files not yet created are waited for (unchanged ${STABLE_WAIT}s = done).\nFiles already on both sides are skipped. The window stays open until all are finished."

zenity --question --title="$TITLE – Confirmation" --width=820 --ok-label="Start" --cancel-label="Cancel" --text="$CT" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# ============================ 5. Log =================================
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/AUS_auto_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
{
    echo "=== AUS Auto Transfer Report ==="
    echo "Started    : $(date)"
    echo "Source     : $SSH_USER@$SSH_HOST:$PARENT_DIR"
    echo "Save base  : $SAVE_BASE"
    echo "Theta/Phi  : $THETA / $PHI   (PMT1 wave ${WAVES_PMT1// /,} / PMT2 wave ${WAVES_PMT2// /,})"
    echo "Upload     : $SUKAP_USER@$SUKAP_HOST:$SUKAP_BASE"
    echo "Check mode : $CHECK_MODE"
    for (( i=1; i<=NUM_RES; i++ )); do
        case "${R_STATE[i]}" in
            empty)   echo "Res $i     : empty" ;;
            invalid) echo "Res $i     : INVALID (${R_REASON[i]}) Date=${R_DATE[i]} Time=${R_TIME[i]} PMT=${R_PMT[i]} Label=${R_PLABEL[i]} Elec=${R_ELEC[i]}" ;;
            active)  echo "Res $i     : ${R_LABEL[i]} -> ${R_SAVE[i]}" ;;
        esac
    done
    echo "----------------------------------------------------"
} > "$LOG_FILE"

START_TS=$(date '+%H:%M:%S')

# ============================ 6. Main loop ===========================
(
    trap '' PIPE                     # keep working even if the progress window is closed
    exec 9>"$IO_LOCK"
    exec 8>"$AUS_ACTIVE_LOCK"; flock -n 8      # tells the KOR auto script to wait
    trap 'rm -f "$IO_LOCK.wait.$IO_NAME"' EXIT
    SECONDS=0

    TOTAL_STEPS=0
    declare -a R_STATUS
    for (( i=1; i<=NUM_RES; i++ )); do
        case "${R_STATE[i]}" in
            empty)   R_STATUS[i]="—  empty" ;;
            invalid) R_STATUS[i]="✖  invalid input (skipped)" ;;
            active)  R_STATUS[i]="⏸  pending"; TOTAL_STEPS=$(( TOTAL_STEPS + 4 * R_NFILES[i] )) ;;
        esac
    done
    DONE_STEPS=0
    CUR="Starting..."; DETAIL=""; LAST_RENDER=-1

    render() {
        local NL='\n' msg pct j
        msg="$TITLE      started $START_TS      elapsed $(fmt_dur $SECONDS)${NL}"
        msg+="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NL}"
        for (( j=1; j<=NUM_RES; j++ )); do
            if [ "${R_STATE[j]}" = "active" ]; then
                msg+="Res $j   ${R_LABEL[j]}${NL}        ${R_STATUS[j]}${NL}"
            else
                msg+="Res $j   ${R_STATUS[j]}${NL}"
            fi
        done
        msg+="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NL}"
        msg+="${CUR}${NL}    ${DETAIL}${NL}${NL}"
        pct=$(( TOTAL_STEPS > 0 ? DONE_STEPS * 100 / TOTAL_STEPS : 0 )); (( pct > 99 )) && pct=99
        msg+="Overall : $DONE_STEPS / $TOTAL_STEPS steps  (4 per file: DAQ→Shifter, verify, →sukap, verify)"
        { printf '# %s\n' "$msg"; printf '%s\n' "$pct"; } 2>/dev/null
    }
    sleep_render() { local s; for (( s=0; s<$1; s++ )); do sleep 1; render; done; }

    # ---- shared disk lock (see header) ----
    io_acquire() {
        local since owner
        flock -n 9 && { echo "$IO_NAME: $CUR" > "$IO_LOCK.owner"; return 0; }
        since=$(date '+%H:%M:%S')
        while true; do
            touch "$IO_LOCK.wait.$IO_NAME"            # tells the other script that we are waiting
            flock -n 9 && break
            owner=$(cat "$IO_LOCK.owner" 2>/dev/null)
            DETAIL="⏸  Disk busy – waiting for the other transfer   [${owner:-?}]   (since $since)"
            sleep_render 1
        done
        rm -f "$IO_LOCK.wait.$IO_NAME"
        echo "$IO_NAME: $CUR" > "$IO_LOCK.owner"
    }
    io_release() {
        : > "$IO_LOCK.owner" 2>/dev/null
        flock -u 9
        :   # AUS has priority: no yielding to KOR
    }

    # wait until the remote file exists and its size/mtime stop changing -> STABLE_SIZE
    wait_stable() {
        local rp="$1" s1 s2 rc since; since=$(date '+%H:%M:%S')
        while true; do
            s1=$(rssh "stat -c '%s %Y' '$rp' 2>/dev/null"); rc=$?
            if [ $rc -eq 255 ]; then
                DETAIL="⚠  Cannot reach the DAQ PC – retrying   (waiting since $since)"
                sleep_render "$POLL_INTERVAL"; continue
            fi
            if [ -z "$s1" ]; then
                DETAIL="⏳  Waiting for the DAQ to create this file   (waiting since $since)"
                sleep_render "$POLL_INTERVAL"; continue
            fi
            DETAIL="⏳  File found ($(fmt_bytes "${s1%% *}")) – checking that writing has finished (${STABLE_WAIT} s)"
            sleep_render "$STABLE_WAIT"
            s2=$(rssh "stat -c '%s %Y' '$rp' 2>/dev/null")
            if [ -n "$s2" ] && [ "$s1" = "$s2" ] && [ "${s2%% *}" -gt 0 ]; then
                STABLE_SIZE=${s2%% *}; return 0
            fi
            DETAIL="✎  DAQ is still writing ($(fmt_bytes "${s2%% *}"))   (waiting since $since)"
            render
        done
    }

    # rsync one file with live progress; the disk lock is taken per attempt -> 0 on success
    #   $1 total bytes  $2 arrow text  $3 ssh command for -e  $4 source (with /./)  $5 destination
    do_rsync() {
        local total="$1" arrow="$2" rsh="$3" src="$4" dst="$5" attempt rc line b p sp eta
        for (( attempt=1; attempt<=RSYNC_RETRY; attempt++ )); do
            rc=1
            io_acquire
            DETAIL="$arrow   starting rsync ($(fmt_bytes "$total"))"; render
            while IFS= read -r line; do
                if [[ "$line" == RSYNC_EXIT:* ]]; then rc=${line#RSYNC_EXIT:}; continue; fi
                if [[ "$line" =~ ^[[:space:]]*([0-9,]+)[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+[kKMGT]?B/s)[[:space:]]+([0-9:]+) ]]; then
                    (( SECONDS == LAST_RENDER )) && continue
                    LAST_RENDER=$SECONDS
                    b=${BASH_REMATCH[1]//,/}; p=${BASH_REMATCH[2]}; sp=${BASH_REMATCH[3]}; eta=${BASH_REMATCH[4]}
                    DETAIL="$arrow   $(fmt_bytes "$b") / $(fmt_bytes "$total")  ($p%)    $sp    ETA $eta"
                    (( attempt > 1 )) && DETAIL+="    [retry $attempt/$RSYNC_RETRY]"
                    render
                fi
            done < <( { rsync -a -R --progress -e "$rsh" "$src" "$dst" 2>&1 8>&- 9>&-; echo "RSYNC_EXIT:$?"; } | stdbuf -oL tr '\r' '\n' )
            io_release
            [ "$rc" = "0" ] && return 0
            log "  rsync attempt $attempt failed (exit $rc): $src -> $dst"
            if (( attempt < RSYNC_RETRY )); then
                DETAIL="⚠  rsync failed (exit $rc) – retrying in 10 s   [$attempt/$RSYNC_RETRY]"
                sleep_render 10
            fi
        done
        return 1
    }

    # verify local file against a remote copy:  $1 daq|sukap  $2 remote path  $3 local path
    #   -> 0 if identical; message in VMSG.  Caller holds the disk lock.
    declare -A LMD5C
    remote_exec() { local w=$1; shift; if [ "$w" = "daq" ]; then rssh "$@"; else sssh "$@"; fi; }
    verify_file() {
        local w=$1 rp=$2 lp=$3 rmd5 lmd5 key
        [ -f "$lp" ] || { VMSG="local file missing"; return 1; }
        rmd5=$(remote_exec "$w" "md5sum '$rp' 2>/dev/null" 2>/dev/null | awk '{print $1}')
        [ -n "$rmd5" ] || { VMSG="remote file missing"; return 1; }
        key="$lp|$(stat -c '%s %Y' "$lp")"
        lmd5=${LMD5C[$key]}
        [ -n "$lmd5" ] || { lmd5=$(md5sum "$lp" | awk '{print $1}'); LMD5C[$key]=$lmd5; }
        [ "$lmd5" = "$rmd5" ] || { VMSG="MD5 mismatch  local=$lmd5 remote=$rmd5"; return 1; }
        if [ "$CMP_CHECK" = "1" ]; then
            DETAIL="${DETAIL%% *}  MD5 OK – byte-by-byte comparison (cmp)..."; render
            remote_exec "$w" "cat '$rp'" 2>/dev/null | cmp -s "$lp" - || { VMSG="cmp failed although MD5 matched"; return 1; }
        fi
        VMSG="MD5 $lmd5"; return 0
    }

    res_status() {
        R_STATUS[i]="▶  file $n/$N    DAQ→Shifter ✔$(( c_cp + c_sk ))   verify ✔$c_dok   →sukap ✔$c_up   verify ✔$c_sok   NG $c_ng"
    }

    for (( i=1; i<=NUM_RES; i++ )); do
        [ "${R_STATE[i]}" = "active" ] || continue
        SAVE_DIR=${R_SAVE[i]}; SUKAP_DIR=${R_SUKAP[i]}; N=${R_NFILES[i]}
        log "=== Reservation $i : ${R_LABEL[i]} -> $SAVE_DIR -> sukap:$SUKAP_DIR"

        # ---------------- HH mode : find the scan directory ----------------
        if [ "${R_TMODE[i]}" = "hour" ]; then
            since=$(date '+%H:%M:%S'); deadline=$(( R_TARGET[i] + TIME_WINDOW + GIVE_UP_GRACE ))
            FOUND=0
            while true; do
                res=$(find_scan "$i")
                if [ -n "$res" ]; then
                    read -r R_SCAN[i] bd nc <<< "$res"; FOUND=1; break
                fi
                if (( $(date +%s) > deadline )); then break; fi
                R_STATUS[i]="⏳  searching for the scan directory..."
                CUR="▶  Res $i   looking for scan_* / ${R_PLABEL[i]} near ${R_DATE[i]} ${R_HH[i]}:00 (±$((TIME_WINDOW/60)) min)"
                DETAIL="⏳  Waiting for the DAQ to export it   (since $since, give up after $(date -d "@$deadline" '+%m/%d %H:%M'))"
                sleep_render "$POLL_INTERVAL"
            done
            if [ $FOUND -eq 0 ]; then
                R_STATUS[i]="✖  no scan found within ±$((TIME_WINDOW/60)) min of ${R_DATE[i]} ${R_HH[i]}:00 – skipped"
                log "[NO MATCH] no scan_*/${R_PLABEL[i]} within ±$((TIME_WINDOW/60)) min of ${R_DATE[i]} ${R_HH[i]}:00 – reservation skipped"
                echo "" >> "$LOG_FILE"
                DONE_STEPS=$(( DONE_STEPS + 4 * N )); render
                continue
            fi
            log "[MATCH] ${R_SCAN[i]}/${R_PLABEL[i]}  (Δ $(fmt_diff "$bd") from ${R_DATE[i]} ${R_HH[i]}:00, $nc candidate(s))"
            R_LABEL[i]="${R_SCAN[i]} / ${R_LABEL[i]#* / }"
        fi
        mapfile -t RELS < <(rel_paths "$i")

        n=0; c_cp=0; c_sk=0; c_dok=0; c_up=0; c_sok=0; c_ng=0
        for REL in "${RELS[@]}"; do
            n=$(( n + 1 ))
            RP="$PARENT_DIR/$REL"; LP="$SAVE_DIR/$REL"; SP="$SUKAP_DIR/$REL"
            SHORT=${REL#*/*/}                       # wavesave_thetaX_phiY/waveN.dat
            res_status

            # ---- 1/4  AUS DAQ PC -> Shifter ----
            CUR="▶  Res $i   $n/$N   $SHORT     [1/4  DAQ → Shifter]"
            DETAIL="Checking..."; render
            if [ -f "$LP" ] && rssh "test -f '$RP'" 2>/dev/null; then
                c_sk=$(( c_sk + 1 ))
                log "[SKIP]     $REL – already on DAQ and Shifter"
            else
                wait_stable "$RP"
                if do_rsync "$STABLE_SIZE" "⇣  DAQ → Shifter" "ssh $SSH_COMMON" "$SSH_USER@$SSH_HOST:$PARENT_DIR/./$REL" "$SAVE_DIR/"; then
                    c_cp=$(( c_cp + 1 ))
                    log "[COPIED]   $REL ($(fmt_bytes "$STABLE_SIZE"))"
                else
                    c_ng=$(( c_ng + 1 )); log "[NG]       $REL – rsync DAQ → Shifter failed"
                    DONE_STEPS=$(( DONE_STEPS + 4 )); res_status; render; continue
                fi
            fi
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status

            # ---- 2/4  verify DAQ <-> Shifter ----
            CUR="▶  Res $i   $n/$N   $SHORT     [2/4  verify DAQ ↔ Shifter]"
            io_acquire
            DETAIL="🔎  MD5 (DAQ & Shifter)..."; render
            verify_file daq "$RP" "$LP"; vr=$?
            io_release
            if [ $vr -ne 0 ]; then
                c_ng=$(( c_ng + 1 )); log "[NG]       $REL – DAQ ↔ Shifter: $VMSG (not uploaded to sukap)"
                DONE_STEPS=$(( DONE_STEPS + 3 )); res_status; render; continue
            fi
            c_dok=$(( c_dok + 1 )); log "[OK]       $REL – DAQ ↔ Shifter ($VMSG)"
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status

            # ---- 3/4  Shifter -> sukap ----
            CUR="▶  Res $i   $n/$N   $SHORT     [3/4  Shifter → sukap]"
            if do_rsync "$(stat -c %s "$LP")" "⇡  Shifter → sukap" "sshpass -e ssh $SUKAP_COMMON" "$SAVE_DIR/./$REL" "$SUKAP_USER@$SUKAP_HOST:$SUKAP_DIR/"; then
                c_up=$(( c_up + 1 )); log "[UPLOADED] $REL -> sukap"
            else
                c_ng=$(( c_ng + 1 )); log "[NG]       $REL – rsync Shifter → sukap failed"
                DONE_STEPS=$(( DONE_STEPS + 2 )); res_status; render; continue
            fi
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status

            # ---- 4/4  verify Shifter <-> sukap ----
            CUR="▶  Res $i   $n/$N   $SHORT     [4/4  verify Shifter ↔ sukap]"
            io_acquire
            DETAIL="🔎  MD5 (Shifter & sukap)..."; render
            verify_file sukap "$SP" "$LP"; vr=$?
            io_release
            if [ $vr -ne 0 ]; then
                c_ng=$(( c_ng + 1 )); log "[NG]       $REL – Shifter ↔ sukap: $VMSG"
            else
                c_sok=$(( c_sok + 1 )); log "[OK]       $REL – Shifter ↔ sukap ($VMSG)"
            fi
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status; render
        done

        if [ $c_ng -eq 0 ] && [ $c_sok -eq $N ]; then
            R_STATUS[i]="✔  finished – all $N files on Shifter & sukap verified    (copied $c_cp, skipped $c_sk)"
            log "-> Result: all completed ($c_sok/$N verified on Shifter and sukap)"
        else
            R_STATUS[i]="✖  finished with problems – NG $c_ng/$N    (sukap verified $c_sok/$N)"
            log "-> Result: something broken (NG $c_ng/$N, sukap verified $c_sok/$N)"
        fi
        echo "" >> "$LOG_FILE"
        render
    done
    flock -u 8                                   # AUS finished -> KOR may start

    {
        echo "----------------------------------------------------"
        echo "Finished : $(date)   (elapsed $(fmt_dur $SECONDS))"
        echo "=== Final status ==="
        for (( i=1; i<=NUM_RES; i++ )); do echo "Res $i : ${R_STATUS[i]}"; done
    } >> "$LOG_FILE"

    DONE_STEPS=$TOTAL_STEPS
    CUR="✔  All reservations finished"
    DETAIL="Press OK to open the report.    Log: $LOG_FILE"
    render
    echo "100" 2>/dev/null
) | zenity --progress \
        --title="$TITLE – Status" \
        --width=780 \
        --height=380 \
        --percentage=0 \
        --no-cancel 2>/dev/null

# ============================ 7. Report ==============================
zenity --text-info --title="$TITLE – Report" --filename="$LOG_FILE" --width=850 --height=600 2>/dev/null
ssh $SSH_COMMON -O exit "$SSH_USER@$SSH_HOST" &>/dev/null
sshpass -e ssh $SUKAP_COMMON -O exit "$SUKAP_USER@$SUKAP_HOST" &>/dev/null
unset SSHPASS