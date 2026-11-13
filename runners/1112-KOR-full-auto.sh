#!/bin/bash
# =====================================================================
#  Reserved Auto Copy & Verification Tool   (KOR DAQ PC -> Shifter PC)
#  Run on : Shifter PC (precalib@10.200.102.69)
#
#  Flow (one file at a time, the RAID on the Shifter PC does one job at a time):
#    for res = 1..4, for run = Run Min..Run Max  (precal_raw_kor_run_YYYYMMDD_rrr.root):
#      1. rsync  KOR DAQ PC -> Shifter HDD
#           - already on both sides            -> skip
#           - otherwise wait until the DAQ file exists and its size/mtime are
#             unchanged for STABLE_WAIT s (= write finished), then rsync
#      2. verify KOR DAQ PC <-> Shifter      (MD5 + ROOT zombie/recovery check)
#      3. rsync  Shifter HDD -> sukap
#      4. verify Shifter <-> sukap           (MD5)
#  Priority : while the AUS auto script is running (all its reservations),
#             this script does no disk work – it waits and resumes afterwards.
#  Disk lock: the KOR and AUS auto scripts share IO_LOCK, so only one of them
#  reads/writes the RAID at a time (rsync of one file, or verification of one
#  file). Waiting for the DAQ does not hold the lock. They take turns per file.
# =====================================================================

# ============================ Settings ===============================
SSH_USER="precalkor"
SSH_HOST="10.200.102.65"            # KOR DAQ PC (hk-precal-kor)
SSH_PORT="4280"

DEFAULT_PARENT_DIR="/media/precalkor/HD-EDS-E/Data_Backup/RAW/Laser"
DEFAULT_SAVE_BASE="/media/precalib/rawdata/production/kor"   # -> <base>/<electronics>/

SUKAP_USER="hkpd"
SUKAP_HOST="10.220.11.100"         # sukap
SUKAP_PORT="22"
DEFAULT_SUKAP_BASE="/disk03/hk04/precalib/production/kor"     # -> <base>/<electronics>/
DEFAULT_ELEC="caendigi"

NUM_RES=4            # number of reservation slots
STABLE_WAIT=5        # [s] file is complete when size & mtime are unchanged for this long
POLL_INTERVAL=5      # [s] polling interval while waiting for the DAQ to create a file
RSYNC_RETRY=3        # rsync attempts per file
LOG_DIR="$HOME/precal_transfer_logs"
IO_LOCK="/tmp/precal_rawdata_io.lock"   # shared with the AUS auto script: one heavy disk job at a time
IO_NAME="KOR"
AUS_ACTIVE_LOCK="/tmp/precal_aus_active.lock"   # held by the AUS auto script while it runs
TITLE="KOR Auto Transfer"

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
file_name() { printf "precal_raw_kor_run_%s_%03d.root" "$1" "$2"; }

if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi
if ! command -v sshpass &> /dev/null; then
    zenity --error --title="Missing Dependency" --width=500 \
        --text="sshpass is not installed.\nPlease install it using: sudo apt install sshpass" 2>/dev/null
    exit 1
fi

# ============================ 1. Input form ==========================
FORM=( --forms --title="$TITLE – Input" --width=820 --height=760 --separator="|"
       --text="Global settings and up to $NUM_RES reservations.\nLeave Date / Run fields blank to skip a reservation."
       --add-entry="[Global] Remote Parent Dir   [default: $DEFAULT_PARENT_DIR]"
       --add-entry="[Global] Local Save Base Dir   [default: $DEFAULT_SAVE_BASE]"
       --add-entry="[Global] sukap Target Base Dir   [default: $DEFAULT_SUKAP_BASE]" )
for (( i=1; i<=NUM_RES; i++ )); do
    FORM+=( --add-entry="[Reservation $i] Date (yyyymmdd)"
            --add-entry="[Reservation $i] Run Min"
            --add-entry="[Reservation $i] Run Max"
            --add-entry="[Reservation $i] Electronics   [caendigi / hkelec, default: $DEFAULT_ELEC]" )
done

INPUTS=$(zenity "${FORM[@]}" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Processing cancelled."
    exit 0
fi

# ============================ 2. Parse & validate ====================
IFS='|' read -r -a F <<< "$INPUTS"

PARENT_DIR=$(trim "${F[0]}"); PARENT_DIR=${PARENT_DIR:-$DEFAULT_PARENT_DIR}; PARENT_DIR=${PARENT_DIR%/}
SAVE_BASE=$(trim "${F[1]}");  SAVE_BASE=${SAVE_BASE:-$DEFAULT_SAVE_BASE};    SAVE_BASE=${SAVE_BASE%/}
SUKAP_BASE=$(trim "${F[2]}"); SUKAP_BASE=${SUKAP_BASE:-$DEFAULT_SUKAP_BASE}; SUKAP_BASE=${SUKAP_BASE%/}

declare -a R_DATE R_MIN R_MAX R_ELEC R_STATE R_REASON R_RUNS R_NFILES R_SAVE R_SUKAP R_LABEL
N_ACTIVE=0
for (( i=1; i<=NUM_RES; i++ )); do
    k=$(( 3 + (i-1)*4 ))
    d=$(trim "${F[k]}"); mn=$(trim "${F[k+1]}"); mx=$(trim "${F[k+2]}")
    el=$(trim "${F[k+3]}" | tr 'A-Z' 'a-z'); el=${el:-$DEFAULT_ELEC}

    if [ -z "$d$mn$mx" ]; then R_STATE[i]="empty"; continue; fi

    reason=""
    [[ "$d" =~ ^[0-9]{8}$ ]]                       || reason+="Date must be yyyymmdd. "
    [[ "$mn" =~ ^[0-9]+$ && "$mx" =~ ^[0-9]+$ ]]   || reason+="Run Min/Max must be integers. "
    [[ "$el" == "caendigi" || "$el" == "hkelec" ]] || reason+="Electronics must be caendigi or hkelec. "

    R_DATE[i]=$d; R_MIN[i]=$mn; R_MAX[i]=$mx; R_ELEC[i]=$el
    if [ -n "$reason" ]; then R_STATE[i]="invalid"; R_REASON[i]=$reason; continue; fi

    lo=$((10#$mn)); hi=$((10#$mx)); (( lo > hi )) && { t=$lo; lo=$hi; hi=$t; }
    R_RUNS[i]=$(seq "$lo" "$hi" | tr '\n' ' ')
    R_NFILES[i]=$(( hi - lo + 1 ))
    R_SAVE[i]="$SAVE_BASE/$el"
    R_SUKAP[i]="$SUKAP_BASE/$el"
    R_LABEL[i]="$d  run $lo–$hi (${R_NFILES[i]} files)  ·  $el"
    R_STATE[i]="active"
    N_ACTIVE=$(( N_ACTIVE + 1 ))
done

if [ "$N_ACTIVE" -eq 0 ]; then
    zenity --error --title="$TITLE" --width=500 --text="No valid reservation was entered." 2>/dev/null
    exit 1
fi

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
        --text="Remote directory does not exist on $SSH_HOST:\n$(esc "$PARENT_DIR")\n\n(Is the external disk mounted on the DAQ PC?)" 2>/dev/null
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
HAS_ROOT_CMD=$(command -v root &> /dev/null && echo "yes" || echo "no")
CHECK_MODE="MD5 hash comparison (DAQ↔Shifter, Shifter↔sukap)"
[ "$HAS_ROOT_CMD" = "yes" ] && CHECK_MODE+=" + ROOT zombie/recovery check"

CT="<b><big>$(esc "$TITLE")</big></b>\n\n"
CT+="<tt>Source : $(esc "$SSH_USER@$SSH_HOST:$PARENT_DIR")\n"
CT+="Dest   : $(esc "$SAVE_BASE")/&lt;electronics&gt;/\n"
CT+="Upload : $(esc "$SUKAP_USER@$SUKAP_HOST:$SUKAP_BASE")/&lt;electronics&gt;/   (free $SUKAP_AVAIL)\n"
CT+="Flow   : per run  DAQ→Shifter → verify → Shifter→sukap → verify\n"
CT+="Check  : $(esc "$CHECK_MODE")\n"
CT+="Disk   : one disk job at a time; waits while the AUS auto transfer is running (AUS first)\n"
CT+="Rule   : on both sides -&gt; skip  /  otherwise wait until unchanged for ${STABLE_WAIT}s -&gt; rsync</tt>\n\n"

for (( i=1; i<=NUM_RES; i++ )); do
    case "${R_STATE[i]}" in
    empty)
        CT+="<b>[Reservation $i]</b>  <span foreground='gray'>empty (skipped)</span>\n\n" ;;
    invalid)
        CT+="<b>[Reservation $i]</b>  <span foreground='red'><b>INVALID – will be skipped</b></span>\n"
        CT+="<tt>  Input  : Date='$(esc "${R_DATE[i]}")'  Run=$(esc "${R_MIN[i]}")–$(esc "${R_MAX[i]}")  Elec=$(esc "${R_ELEC[i]}")\n"
        CT+="  Reason : $(esc "${R_REASON[i]}")</tt>\n\n" ;;
    active)
        if ! mkdir -p "${R_SAVE[i]}" 2>/dev/null; then
            R_STATE[i]="invalid"; R_REASON[i]="Cannot create save dir ${R_SAVE[i]}"
            CT+="<b>[Reservation $i]</b>  <span foreground='red'><b>INVALID – will be skipped</b></span>\n<tt>  Reason : $(esc "${R_REASON[i]}")</tt>\n\n"
            N_ACTIVE=$(( N_ACTIVE - 1 )); continue
        fi
        names=(); lcount=0
        for r in ${R_RUNS[i]}; do
            fn=$(file_name "${R_DATE[i]}" "$r"); names+=("$fn")
            [ -f "${R_SAVE[i]}/$fn" ] && lcount=$(( lcount + 1 ))
        done
        rcount=$(rssh "cd '$PARENT_DIR' && ls -1 ${names[*]} 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
        avail=$(df -h --output=avail "${R_SAVE[i]}" 2>/dev/null | tail -n 1 | tr -d ' ')
        CT+="<b>[Reservation $i]</b>  <span foreground='#2e7d32'><b>will run</b></span>\n"
        CT+="<tt>  Date        : ${R_DATE[i]}\n"
        CT+="  Runs        : ${R_MIN[i]} – ${R_MAX[i]}   (${R_NFILES[i]} files)\n"
        CT+="  Electronics : ${R_ELEC[i]}\n"
        CT+="  Save Dir    : $(esc "${R_SAVE[i]}")   (free: ${avail:-N/A})\n"
        CT+="  sukap Dir   : $(esc "${R_SUKAP[i]}")\n"
        CT+="  Present now : remote ${rcount:-?}/${R_NFILES[i]},  local ${lcount}/${R_NFILES[i]}</tt>\n\n" ;;
    esac
done

if [ "$N_ACTIVE" -le 0 ]; then
    zenity --error --title="$TITLE" --width=500 --text="No valid reservation was entered." 2>/dev/null
    exit 1
fi
CT+="Reservations are processed in order. Files not created yet are waited for.\nThe window stays open until all reservations are finished."

zenity --question --title="$TITLE – Confirmation" --width=760 --height=600 \
    --ok-label="Start" --cancel-label="Cancel" --text="$CT" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# ============================ 5. Log =================================
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/KOR_auto_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
{
    echo "=== KOR Auto Transfer Report ==="
    echo "Started    : $(date)"
    echo "Source     : $SSH_USER@$SSH_HOST:$PARENT_DIR"
    echo "Save base  : $SAVE_BASE"
    echo "Upload     : $SUKAP_USER@$SUKAP_HOST:$SUKAP_BASE"
    echo "Check mode : $CHECK_MODE"
    for (( i=1; i<=NUM_RES; i++ )); do
        case "${R_STATE[i]}" in
            empty)   echo "Res $i     : empty" ;;
            invalid) echo "Res $i     : INVALID (${R_REASON[i]}) Date=${R_DATE[i]} Run=${R_MIN[i]}-${R_MAX[i]} Elec=${R_ELEC[i]}" ;;
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
        msg+="Overall : $DONE_STEPS / $TOTAL_STEPS steps  (4 per run: DAQ→Shifter, verify, →sukap, verify)"
        { printf '# %s\n' "$msg"; printf '%s\n' "$pct"; } 2>/dev/null
    }
    sleep_render() { local s; for (( s=0; s<$1; s++ )); do sleep 1; render; done; }

    # ---- shared disk lock (see header) ----
    # true while the AUS auto script holds its "active" lock
    aus_active() { ! ( flock -n 7 ) 7>"$AUS_ACTIVE_LOCK" 2>/dev/null; }

    io_acquire() {
        local since owner
        if aus_active; then
            since=$(date '+%H:%M:%S')
            local keep="$DETAIL" st="${R_STATUS[i]}"
            R_STATUS[i]="⏸  paused – AUS auto transfer has priority"
            while aus_active; do
                DETAIL="⏸  AUS auto transfer is running – KOR waits until all AUS reservations are finished   (since $since)"
                sleep_render 5
            done
            R_STATUS[i]="$st"; DETAIL="$keep"
        fi
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
        # if the other script is waiting (wait file touched within 5 s), give it the turn
        if [ -n "$(find "$(dirname "$IO_LOCK")" -maxdepth 1 -name "$(basename "$IO_LOCK").wait.*" ! -name "*.wait.$IO_NAME" -newermt '-5 seconds' 2>/dev/null)" ]; then
            sleep 3
        fi
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

    # verify local file against a remote copy (MD5):  $1 daq|sukap  $2 remote path  $3 local path
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
        VMSG="MD5 $lmd5"; return 0
    }
    # ROOT zombie / recovery check of the local file -> 0 OK; message in VMSG
    root_check() {
        [ "$HAS_ROOT_CMD" = "yes" ] || return 0
        timeout 300 root -l -b -q -e "TFile f(\"$1\"); if (f.IsZombie()) gSystem->Exit(1); if (f.TestBit(TFile::kRecovered)) gSystem->Exit(2); gSystem->Exit(0);" &>/dev/null 8>&- 9>&-
        case $? in
            0) return 0 ;;
            2) VMSG="ROOT: file was not closed properly (recovered)"; return 1 ;;
            *) VMSG="ROOT: zombie – cannot open the file"; return 1 ;;
        esac
    }

    res_status() {
        R_STATUS[i]="▶  run $n/$N    DAQ→Shifter ✔$(( c_cp + c_sk ))   verify ✔$c_dok   →sukap ✔$c_up   verify ✔$c_sok   NG $c_ng"
    }

    for (( i=1; i<=NUM_RES; i++ )); do
        [ "${R_STATE[i]}" = "active" ] || continue
        DATE=${R_DATE[i]}; SAVE_DIR=${R_SAVE[i]}; SUKAP_DIR=${R_SUKAP[i]}; N=${R_NFILES[i]}
        log "=== Reservation $i : ${R_LABEL[i]} -> $SAVE_DIR -> sukap:$SUKAP_DIR"

        n=0; c_cp=0; c_sk=0; c_dok=0; c_up=0; c_sok=0; c_ng=0
        for r in ${R_RUNS[i]}; do
            n=$(( n + 1 ))
            FN=$(file_name "$DATE" "$r")
            RP="$PARENT_DIR/$FN"; LP="$SAVE_DIR/$FN"; SP="$SUKAP_DIR/$FN"
            res_status

            # ---- 1/4  KOR DAQ PC -> Shifter ----
            CUR="▶  Res $i   run $n/$N   $FN     [1/4  DAQ → Shifter]"
            DETAIL="Checking..."; render
            if [ -f "$LP" ] && rssh "test -f '$RP'" 2>/dev/null; then
                c_sk=$(( c_sk + 1 ))
                log "[SKIP]     $FN – already on DAQ and Shifter"
            else
                wait_stable "$RP"
                if do_rsync "$STABLE_SIZE" "⇣  DAQ → Shifter" "ssh $SSH_COMMON" "$SSH_USER@$SSH_HOST:$PARENT_DIR/./$FN" "$SAVE_DIR/"; then
                    c_cp=$(( c_cp + 1 ))
                    log "[COPIED]   $FN ($(fmt_bytes "$STABLE_SIZE"))"
                else
                    c_ng=$(( c_ng + 1 )); log "[NG]       $FN – rsync DAQ → Shifter failed"
                    DONE_STEPS=$(( DONE_STEPS + 4 )); res_status; render; continue
                fi
            fi
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status

            # ---- 2/4  verify DAQ <-> Shifter (+ ROOT check) ----
            CUR="▶  Res $i   run $n/$N   $FN     [2/4  verify DAQ ↔ Shifter]"
            io_acquire
            DETAIL="🔎  MD5 (DAQ & Shifter)..."; render
            verify_file daq "$RP" "$LP"; vr=$?
            if [ $vr -eq 0 ]; then
                DETAIL="🔎  MD5 OK – ROOT zombie / recovery check..."; render
                MSG_MD5=$VMSG; root_check "$LP"; vr=$?
                [ $vr -eq 0 ] && VMSG="$MSG_MD5"
            fi
            io_release
            if [ $vr -ne 0 ]; then
                c_ng=$(( c_ng + 1 )); log "[NG]       $FN – DAQ ↔ Shifter: $VMSG (not uploaded to sukap)"
                DONE_STEPS=$(( DONE_STEPS + 3 )); res_status; render; continue
            fi
            c_dok=$(( c_dok + 1 )); log "[OK]       $FN – DAQ ↔ Shifter ($VMSG)"
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status

            # ---- 3/4  Shifter -> sukap ----
            CUR="▶  Res $i   run $n/$N   $FN     [3/4  Shifter → sukap]"
            if do_rsync "$(stat -c %s "$LP")" "⇡  Shifter → sukap" "sshpass -e ssh $SUKAP_COMMON" "$SAVE_DIR/./$FN" "$SUKAP_USER@$SUKAP_HOST:$SUKAP_DIR/"; then
                c_up=$(( c_up + 1 )); log "[UPLOADED] $FN -> sukap"
            else
                c_ng=$(( c_ng + 1 )); log "[NG]       $FN – rsync Shifter → sukap failed"
                DONE_STEPS=$(( DONE_STEPS + 2 )); res_status; render; continue
            fi
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status

            # ---- 4/4  verify Shifter <-> sukap ----
            CUR="▶  Res $i   run $n/$N   $FN     [4/4  verify Shifter ↔ sukap]"
            io_acquire
            DETAIL="🔎  MD5 (Shifter & sukap)..."; render
            verify_file sukap "$SP" "$LP"; vr=$?
            io_release
            if [ $vr -ne 0 ]; then
                c_ng=$(( c_ng + 1 )); log "[NG]       $FN – Shifter ↔ sukap: $VMSG"
            else
                c_sok=$(( c_sok + 1 )); log "[OK]       $FN – Shifter ↔ sukap ($VMSG)"
            fi
            DONE_STEPS=$(( DONE_STEPS + 1 )); res_status; render
        done

        if [ $c_ng -eq 0 ] && [ $c_sok -eq $N ]; then
            R_STATUS[i]="✔  finished – all $N runs on Shifter & sukap verified    (copied $c_cp, skipped $c_sk)"
            log "-> Result: all completed ($c_sok/$N verified on Shifter and sukap)"
        else
            R_STATUS[i]="✖  finished with problems – NG $c_ng/$N    (sukap verified $c_sok/$N)"
            log "-> Result: something broken (NG $c_ng/$N, sukap verified $c_sok/$N)"
        fi
        echo "" >> "$LOG_FILE"
        render
    done

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
        --height=440 \
        --percentage=0 \
        --no-cancel 2>/dev/null

# ============================ 7. Report ==============================
zenity --text-info --title="$TITLE – Report" --filename="$LOG_FILE" --width=850 --height=600 2>/dev/null
ssh $SSH_COMMON -O exit "$SSH_USER@$SSH_HOST" &>/dev/null
sshpass -e ssh $SUKAP_COMMON -O exit "$SUKAP_USER@$SUKAP_HOST" &>/dev/null
unset SSHPASS