#!/bin/bash
# =====================================================================
#  1112-AUSbackup.sh  –  background backup of the AUS DAQ data
#  Run on : Shifter PC (precalib@10.200.102.69)
#
#  Usage :  ./1112-AUSbackup.sh [-date YYYYMMDD] [-elec caendigi|hkelec]
#           ./1112-AUSbackup.sh status      (show the status from another terminal)
#
#  Every 5 min (22:00-10:00) / every 30 min (10:00-22:00) the AUS DAQ PC is searched:
#    PARENT_DIR/scan_YYYYMMDD_HHMMSS/...  files created (modified) after
#      - the start time of this script, or
#      - YYYYMMDD 00:00:00 when -date YYYYMMDD is given
#  and every new file is handled one at a time:
#      1. writing finished?  (size & mtime unchanged for 5 s; still writing -> next scan)
#      2. rsync   AUS DAQ PC -> Shifter     (same directory structure)
#      3. verify  AUS DAQ PC <-> Shifter    (MD5 [+ cmp])
#      4. rsync   Shifter -> sukap
#      5. verify  Shifter <-> sukap         (MD5 [+ cmp])
#  Files that passed all steps are remembered (DONE_LIST) and never handled again.
#
#  While running, type in this terminal:  status | log | quit | help
#  Disk: shares the disk lock with the KOR auto script; while files are being
#  processed the KOR auto script waits (AUS has priority).
# =====================================================================

# ============================ Settings ===============================
SSH_USER="hyperkaus"
SSH_HOST="10.200.102.67"            # AUS DAQ PC (hk-precal-aus1)
SSH_PORT="22"
PARENT_DIR="/home/hyperkaus/WaveDumpSaves"

SAVE_BASE="/media/precalib/rawdata/production/aus"          # -> <base>/<electronics>/scan_.../...
SUKAP_USER="hkpd"
SUKAP_HOST="10.220.11.100"          # sukap
SUKAP_PORT="22"
SUKAP_BASE="/disk03/hk04/precalib/production/aus"           # -> <base>/<electronics>/scan_.../...
ELEC="caendigi"                     # default, change with -elec

INTERVAL_NIGHT=${INTERVAL_NIGHT:-300}     # [s] 22:00-10:00
INTERVAL_DAY=${INTERVAL_DAY:-1800}        # [s] 10:00-22:00
NIGHT_START=22; NIGHT_END=10              # night = hour >= 22 or hour < 10
STABLE_WAIT=${STABLE_WAIT:-5}             # [s] unchanged size/mtime for this long = writing finished
OLD_ENOUGH=60        # [s] files not modified for this long are already finished (no 5 s wait)
RSYNC_RETRY=3        # rsync attempts per file and per direction
MAX_NG=3             # a file that failed this many scans is given up (see log)
CMP_CHECK=1          # 1: byte-by-byte cmp after MD5 match (reads the file again over the network)

LOG_DIR="$HOME/precal_transfer_logs"
DONE_LIST="$LOG_DIR/AUSbackup_done.list"  # rel_path<TAB>size<TAB>mtime of finished files
STATUS_FILE="/tmp/precal_AUSbackup.status"
STOP_FILE="/tmp/precal_AUSbackup.stop"
INSTANCE_LOCK="/tmp/precal_AUSbackup.lock"
IO_LOCK="/tmp/precal_rawdata_io.lock"          # shared with the KOR/AUS auto scripts
AUS_ACTIVE_LOCK="/tmp/precal_aus_active.lock"  # held while files are processed -> KOR waits

SSH_CTRL="/tmp/precal-ssh-%r@%h-%p"
SSH_COMMON="-p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=600"
SUKAP_COMMON="-p $SUKAP_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=600"

# ============================ Helpers ================================
# child processes must not inherit the lock fds (7, 8, 9)
rssh() { ssh $SSH_COMMON "$SSH_USER@$SSH_HOST" "$@" 7>&- 8>&- 9>&-; }
sssh() { sshpass -e ssh $SUKAP_COMMON "$SUKAP_USER@$SUKAP_HOST" "$@" 7>&- 8>&- 9>&-; }
fmt_bytes() { awk -v b="${1:-0}" 'BEGIN{ if(b>=1099511627776)printf "%.2f TB",b/1099511627776; else if(b>=1073741824)printf "%.2f GB",b/1073741824; else if(b>=1048576)printf "%.1f MB",b/1048576; else if(b>=1024)printf "%.1f KB",b/1024; else printf "%d B",b }'; }
usage() {
    cat <<EOF
Usage:  $0 [-date YYYYMMDD] [-elec caendigi|hkelec]
        $0 status
  -date YYYYMMDD   back up all files created on/after YYYYMMDD 00:00 (default: from now)
  -elec NAME       electronics directory (default: $ELEC)
  status           print the status of the running backup
EOF
}

# ============================ Arguments ==============================
if [ "$1" = "status" ]; then
    if [ -f "$STATUS_FILE" ] && ! flock -n "$INSTANCE_LOCK" true 2>/dev/null; then cat "$STATUS_FILE"
    else echo "AUS backup is not running."; fi
    exit 0
fi
DATE_OPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -date|--date) DATE_OPT="$2"; shift 2 ;;
        -elec|--elec) ELEC=$(echo "$2" | tr 'A-Z' 'a-z'); shift 2 ;;
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
SAVE_DIR="$SAVE_BASE/$ELEC"
SUKAP_DIR="$SUKAP_BASE/$ELEC"

for c in sshpass flock rsync md5sum; do
    command -v $c &>/dev/null || { echo "$c is not installed (sudo apt install $c)"; exit 1; }
done

# only one instance at a time
exec 7>"$INSTANCE_LOCK"
flock -n 7 || { echo "1112-AUSbackup.sh is already running.  (./1112-AUSbackup.sh status)"; exit 1; }

# ============================ Connections ============================
echo "AUS backup – checking connections..."
ssh $SSH_COMMON -O check "$SSH_USER@$SSH_HOST" &>/dev/null || ssh $SSH_COMMON -fN "$SSH_USER@$SSH_HOST" &>/dev/null 7>&-
CHK=$(rssh "test -d '$PARENT_DIR' && echo DIR_OK" 2>/dev/null)
if [ "$CHK" != "DIR_OK" ]; then
    echo "ERROR: cannot reach $SSH_USER@$SSH_HOST:$PARENT_DIR without a password."
    echo "       (network?  or register the key once:  ssh-copy-id $SSH_USER@$SSH_HOST)"
    exit 1
fi
read -rsp "Password for $SUKAP_USER@$SUKAP_HOST (sukap): " SUKAP_PASS; echo
export SSHPASS="$SUKAP_PASS"
sshpass -e ssh $SUKAP_COMMON -O check "$SUKAP_USER@$SUKAP_HOST" &>/dev/null || sshpass -e ssh $SUKAP_COMMON -fN "$SUKAP_USER@$SUKAP_HOST" &>/dev/null 7>&-
CHK=$(sssh "mkdir -p '$SUKAP_DIR' && echo DIR_OK" 2>/dev/null)
if [ "$CHK" != "DIR_OK" ]; then
    echo "ERROR: cannot log in to $SUKAP_USER@$SUKAP_HOST or create $SUKAP_DIR (password / network?)"
    exit 1
fi
mkdir -p "$SAVE_DIR" "$LOG_DIR" || { echo "ERROR: cannot create $SAVE_DIR"; exit 1; }
touch "$DONE_LIST"
rm -f "$STOP_FILE"

LOG_FILE="$LOG_DIR/AUSbackup_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
START_STR=$(date '+%Y-%m-%d %H:%M:%S')
{
    echo "=== AUS background backup ==="
    echo "Started : $START_STR"
    echo "Source  : $SSH_USER@$SSH_HOST:$PARENT_DIR/scan_YYYYMMDD_HHMMSS/..."
    echo "Target  : files created after $SINCE_STR"
    echo "Shifter : $SAVE_DIR"
    echo "sukap   : $SUKAP_USER@$SUKAP_HOST:$SUKAP_DIR"
    echo "------------------------------------------------------------"
} > "$LOG_FILE"

# ============================ Worker =================================
worker() {
    exec 9>"$IO_LOCK"
    exec 8>"$AUS_ACTIVE_LOCK"
    declare -A DONE NGCNT GIVEUP LMD5C
    local rel size mt
    while IFS=$'\t' read -r rel size mt; do [ -n "$rel" ] && DONE[$rel]="$size $mt"; done < "$DONE_LIST"

    ST_STATE="idle"; ST_STEP=""; ST_FILE=""; ST_DETAIL=""; ST_LAST="-"; ST_NEXT="-"
    N_DONE=0; N_NG=0; N_WRITING=0; N_QUEUE=0; LAST_WRITE=0

    write_status() {
        {
            echo "================ AUS backup status ($(date '+%H:%M:%S')) ================"
            if [ "$ST_STATE" = "running" ]; then
                echo "State     : running   ($N_QUEUE file(s) left in this scan)"
                echo "Ongoing   : $ST_STEP"
                echo "File      : $ST_FILE"
                [ -n "$ST_DETAIL" ] && echo "            $ST_DETAIL"
            else
                echo "State     : $ST_STATE"
            fi
            echo "Target    : files created after $SINCE_STR"
            echo "            $SSH_HOST:$PARENT_DIR/scan_YYYYMMDD_HHMMSS/..."
            echo "Dest      : $SAVE_DIR  ->  sukap:$SUKAP_DIR"
            echo "Interval  : 5 min (22:00-10:00) / 30 min (10:00-22:00)"
            echo "Last scan : $ST_LAST      Next scan : $ST_NEXT"
            echo "Totals    : done $N_DONE   NG $N_NG   still being written (retry next scan) $N_WRITING"
            echo "Log       : $LOG_FILE"
            echo "Recent    :"
            tail -n 5 "$LOG_FILE" | sed 's/^/  /'
            echo "======================================================================"
        } > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
        LAST_WRITE=$SECONDS
    }

    io_acquire() {
        flock -n 9 && return 0
        local keep="$ST_DETAIL"
        while ! flock -n 9; do
            touch "$IO_LOCK.wait.AUS"
            ST_DETAIL="waiting for the disk (the KOR transfer is finishing its current file)"
            write_status; sleep 1
        done
        rm -f "$IO_LOCK.wait.AUS"; ST_DETAIL="$keep"
    }
    io_release() { flock -u 9; }

    # rsync with progress in the status; $1 total  $2 extra opts  $3 rsh  $4 src  $5 dst
    do_rsync() {
        local total=$1 opts=$2 rsh=$3 src=$4 dst=$5 attempt rc line
        for (( attempt=1; attempt<=RSYNC_RETRY; attempt++ )); do
            rc=1
            io_acquire
            while IFS= read -r line; do
                if [[ "$line" == RSYNC_EXIT:* ]]; then rc=${line#RSYNC_EXIT:}; continue; fi
                if [[ "$line" =~ ^[[:space:]]*([0-9,]+)[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+[kKMGT]?B/s)[[:space:]]+([0-9:]+) ]]; then
                    ST_DETAIL="$(fmt_bytes "${BASH_REMATCH[1]//,/}") / $(fmt_bytes "$total")  (${BASH_REMATCH[2]}%)  ${BASH_REMATCH[3]}  ETA ${BASH_REMATCH[4]}"
                    (( SECONDS != LAST_WRITE )) && write_status
                fi
            done < <( { rsync -a $opts -R --progress -e "$rsh" "$src" "$dst" 2>&1 7>&- 8>&- 9>&-; echo "RSYNC_EXIT:$?"; } | stdbuf -oL tr '\r' '\n' )
            io_release
            ST_DETAIL=""
            [ "$rc" = "0" ] && return 0
            log "  rsync attempt $attempt failed (exit $rc): $src -> $dst"
            (( attempt < RSYNC_RETRY )) && sleep 10
        done
        return 1
    }

    remote_exec() { local w=$1; shift; if [ "$w" = "daq" ]; then rssh "$@"; else sssh "$@"; fi; }
    # $1 daq|sukap  $2 remote path  $3 local path  -> 0 identical; message in VMSG (caller holds the disk lock)
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
            remote_exec "$w" "cat '$rp'" 2>/dev/null | cmp -s "$lp" - || { VMSG="cmp failed although MD5 matched"; return 1; }
        fi
        VMSG="MD5 $lmd5"; return 0
    }

    file_ng() {   # $1 rel  $2 size mtime  $3 message
        N_NG=$(( N_NG + 1 ))
        NGCNT[$1]=$(( ${NGCNT[$1]:-0} + 1 ))
        log "[NG]      $1 – $3   (attempt ${NGCNT[$1]}/$MAX_NG)"
        if (( NGCNT[$1] >= MAX_NG )); then
            GIVEUP[$1]="$2"; log "[GAVE UP] $1 – failed $MAX_NG times, not retried any more (check by hand)"
        fi
    }

    process_file() {   # $1 rel  $2 size  $3 mtime
        local rel=$1 size=$2 mt=$3 RP LP SP s2 vr opts=""
        RP="$PARENT_DIR/$rel"; LP="$SAVE_DIR/$rel"; SP="$SUKAP_DIR/$rel"
        ST_FILE="$rel"
        [ -n "${NGCNT[$rel]}" ] && opts="-c"       # after an NG: compare by checksum, re-transfer

        # 1. writing finished?
        if (( $(date +%s) - mt < OLD_ENOUGH )); then
            ST_STEP="write check (size/mtime unchanged for ${STABLE_WAIT} s?)"; write_status
            sleep "$STABLE_WAIT"
            s2=$(rssh "stat -c '%s %Y' '$RP' 2>/dev/null" 2>/dev/null)
            if [ "$s2" != "$size $mt" ]; then
                N_WRITING=$(( N_WRITING + 1 ))
                log "[WRITING] $rel – still being written, retry at the next scan"
                return
            fi
        fi

        # 2. AUS DAQ -> Shifter
        ST_STEP="rsync  AUS DAQ -> Shifter  ongoing"; write_status
        if ! do_rsync "$size" "$opts" "ssh $SSH_COMMON" "$SSH_USER@$SSH_HOST:$PARENT_DIR/./$rel" "$SAVE_DIR/"; then
            file_ng "$rel" "$size $mt" "rsync AUS DAQ -> Shifter failed"; return
        fi
        # 3. verify AUS DAQ <-> Shifter
        ST_STEP="zombie check  AUS DAQ <-> Shifter  ongoing"; write_status
        io_acquire; verify_file daq "$RP" "$LP"; vr=$?; io_release
        if [ $vr -ne 0 ]; then file_ng "$rel" "$size $mt" "AUS DAQ <-> Shifter: $VMSG"; return; fi
        # 4. Shifter -> sukap
        ST_STEP="rsync  Shifter -> sukap  ongoing"; write_status
        if ! do_rsync "$size" "$opts" "sshpass -e ssh $SUKAP_COMMON" "$SAVE_DIR/./$rel" "$SUKAP_USER@$SUKAP_HOST:$SUKAP_DIR/"; then
            file_ng "$rel" "$size $mt" "rsync Shifter -> sukap failed"; return
        fi
        # 5. verify Shifter <-> sukap
        ST_STEP="zombie check  Shifter <-> sukap  ongoing"; write_status
        io_acquire; verify_file sukap "$SP" "$LP"; vr=$?; io_release
        if [ $vr -ne 0 ]; then file_ng "$rel" "$size $mt" "Shifter <-> sukap: $VMSG"; return; fi

        DONE[$rel]="$size $mt"
        printf '%s\t%s\t%s\n' "$rel" "$size" "$mt" >> "$DONE_LIST"
        N_DONE=$(( N_DONE + 1 ))
        log "[DONE]    $rel ($(fmt_bytes "$size"))  DAQ -> Shifter -> sukap verified ($VMSG)"
    }

    scan_once() {
        local list rc line mtf rel size mt
        local -a Q=()
        ST_STATE="scanning the AUS DAQ PC"; write_status
        list=$(rssh "cd '$PARENT_DIR' 2>/dev/null && find scan_[0-9]*_[0-9]* -type f -newermt '@$SINCE' -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -n" 2>/dev/null)
        rc=$?
        ST_LAST=$(date '+%m/%d %H:%M:%S')
        if [ $rc -eq 255 ]; then log "[SCAN]    cannot reach the AUS DAQ PC – retry at the next scan"; return; fi
        while IFS=$'\t' read -r mtf size rel; do
            [[ "$rel" =~ ^scan_[0-9]{8}_[0-9]{6}/ ]] || continue
            mt=${mtf%.*}
            [ "${DONE[$rel]}" = "$size $mt" ] && continue
            [ "${GIVEUP[$rel]}" = "$size $mt" ] && continue
            Q+=("$rel"$'\t'"$size"$'\t'"$mt")
        done <<< "$list"
        if [ ${#Q[@]} -eq 0 ]; then return; fi
        log "[SCAN]    ${#Q[@]} new file(s)"

        flock -n 8 || true            # AUS is busy -> the KOR auto script waits
        ST_STATE="running"; N_QUEUE=${#Q[@]}
        for line in "${Q[@]}"; do
            [ -f "$STOP_FILE" ] && break
            IFS=$'\t' read -r rel size mt <<< "$line"
            process_file "$rel" "$size" "$mt"
            N_QUEUE=$(( N_QUEUE - 1 ))
        done
        flock -u 8
        ST_STEP=""; ST_FILE=""; ST_DETAIL=""
    }

    interval_now() {
        local h=$((10#$(date +%H)))
        if (( h >= NIGHT_START || h < NIGHT_END )); then echo "$INTERVAL_NIGHT"; else echo "$INTERVAL_DAY"; fi
    }

    log "[START]   watching for new files"
    while [ ! -f "$STOP_FILE" ]; do
        local cstart; cstart=$(date +%s)
        scan_once
        ST_STATE="idle"
        while [ ! -f "$STOP_FILE" ]; do
            local next=$(( cstart + $(interval_now) ))
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
    rm -f "$STOP_FILE" "$IO_LOCK.wait.AUS"
    ssh $SSH_COMMON -O exit "$SSH_USER@$SSH_HOST" &>/dev/null
    sshpass -e ssh $SUKAP_COMMON -O exit "$SUKAP_USER@$SUKAP_HOST" &>/dev/null
    unset SSHPASS
}
trap 'echo; echo "Stopping (after the current step)..."; kill "$WPID" 2>/dev/null; cleanup; echo "Stopped."; exit 0' INT TERM

cat <<EOF

AUS backup started  (PID $WPID)
  target : files created after $SINCE_STR  in  $SSH_HOST:$PARENT_DIR/scan_YYYYMMDD_*
  dest   : $SAVE_DIR  ->  sukap:$SUKAP_DIR
  scan   : every 5 min (22:00-10:00) / 30 min (10:00-22:00)
  log    : $LOG_FILE
Commands:  status | log | quit | help
EOF

if [ -t 0 ]; then
    printf '> '
    while kill -0 "$WPID" 2>/dev/null; do
        if read -r -t 1 cmd; then
            case "$cmd" in
                status|s|st)   cat "$STATUS_FILE" 2>/dev/null || echo "starting..." ;;
                log|l)         tail -n 20 "$LOG_FILE" ;;
                quit|q|exit|stop)
                               echo "Stopping after the current step..."
                               cleanup; echo "Stopped."; exit 0 ;;
                help|h|"?")    echo "status : show the status      log  : last 20 log lines"
                               echo "quit   : stop the backup (finishes the current step)" ;;
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