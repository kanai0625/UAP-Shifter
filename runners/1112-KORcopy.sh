#!/bin/bash

# ======================================================
# ROOT File rsync Transfer Tool (KOR -> precalib)
# ======================================================

# SSH settings for KOR server
SSH_USER="precalkor"
SSH_HOST="10.200.102.65"   # KOR DAQ PC (hk-precal-kor)
SSH_PORT="4280"

# 1. Check if Zenity is installed
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

# 2. GUI for input parameters with empty fields for easy copy-pasting
INPUTS=$(zenity --forms --title="ROOT File rsync Transfer Tool (KOR -> precalib)" \
    --width=750 --height=450 \
    --text="Enter parameters (leave blank to use default values shown in brackets):" \
    --add-entry="Parent Directory [default: /media/precalkor/HD-EDS-E/Data_Backup/RAW/Laser]" \
    --add-entry="Date (yyyymmdd) [example: 20260928]" \
    --add-entry="Run Min [example: 0]" \
    --add-entry="Run Max [example: 45]" \
    --add-entry="Save Base Dir [default: /media/precalib/rawdata/production/kor]" \
    --add-entry="Electronics [caendigi or hkelec, default: caendigi]" \
    --separator="|")

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Processing cancelled."
    exit 0
fi

# 3. Parse inputs and set default values if fields are left empty
IFS='|' read -r PARENT_DIR DATE RUN_MIN RUN_MAX SAVE_DIR ELECTRONICS <<< "$INPUTS"

PARENT_DIR=${PARENT_DIR:-/media/precalkor/HD-EDS-E/Data_Backup/RAW/Laser}
DATE=${DATE:-}
RUN_MIN=${RUN_MIN:-}
RUN_MAX=${RUN_MAX:-}
SAVE_DIR=${SAVE_DIR:-/media/precalib/rawdata/production/kor}

# Validate that Run Min and Run Max are non-negative integers
if ! [[ "$RUN_MIN" =~ ^[0-9]+$ ]] || ! [[ "$RUN_MAX" =~ ^[0-9]+$ ]]; then
    zenity --error --title="Error" --text="Run Min and Run Max must be integer values." --width=450 --height=150
    exit 1
fi

# Remove trailing slash
PARENT_DIR=$(echo "$PARENT_DIR" | sed 's|/$||')
SAVE_DIR=$(echo "$SAVE_DIR" | sed 's|/$||')

# Electronics -> directory: <base>/<electronics>
ELECTRONICS=$(echo "${ELECTRONICS:-caendigi}" | tr -d ' /' | tr 'A-Z' 'a-z')
if [ "$ELECTRONICS" != "caendigi" ] && [ "$ELECTRONICS" != "hkelec" ]; then
    zenity --error --title="Error" --text="Electronics must be caendigi or hkelec." --width=450 --height=150
    exit 1
fi
SAVE_DIR="$SAVE_DIR/$ELECTRONICS"

# Generate Run Numbers array from min to max range
RUN_ARRAY=()
if [ "$RUN_MIN" -le "$RUN_MAX" ]; then
    for (( r=RUN_MIN; r<=RUN_MAX; r++ )); do RUN_ARRAY+=("$r"); done
else
    for (( r=RUN_MIN; r>=RUN_MAX; r-- )); do RUN_ARRAY+=("$r"); done
fi

# Remove duplicates and sort numerically
RUN_ARRAY=($(printf "%s\n" "${RUN_ARRAY[@]}" | sort -nu))

if [ ${#RUN_ARRAY[@]} -eq 0 ]; then
    zenity --error --title="Error" --text="No valid run numbers in the specified range." --width=500 --height=180
    exit 1
fi

TOTAL_FILES=${#RUN_ARRAY[@]}

mkdir -p "$SAVE_DIR"

# Get available disk space in the save directory
LOCAL_AVAIL_RAW=$(df -h "$SAVE_DIR" | tail -n 1 | awk '{print $4}')
LOCAL_AVAIL_STR=$(echo "$LOCAL_AVAIL_RAW" | sed -E 's/([0-9.]+)([A-Za-z]+)/\1 \2B/')

# List of remote paths to be transferred (apply 3-digit zero padding)
REMOTE_PATHS=()
for j in "${RUN_ARRAY[@]}"; do
    RUN_PADDED=$(printf "%03d" "$j")
    REMOTE_PATHS+=("$PARENT_DIR/precal_raw_kor_run_${DATE}_${RUN_PADDED}.root")
done

# Get total size of files to be transferred from the remote server
TOTAL_BYTES=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "wc -c ${REMOTE_PATHS[*]} 2>/dev/null | tail -n 1 | awk '{print \$1}'")

# Check if remote files exist
if [ -z "$TOTAL_BYTES" ] || [ "$TOTAL_BYTES" -eq 0 ]; then
    RUN_EXAMPLE=$(printf "%03d" "${RUN_ARRAY[0]}")
    zenity --error --title="File Not Found" \
        --text="Remote files could not be found.\n\nChecked Path Example:\n$PARENT_DIR/precal_raw_kor_run_${DATE}_${RUN_EXAMPLE}.root\n\nPlease check your input settings." \
        --width=600 --height=250
    exit 1
fi

# Display total size in a human-readable format
TOTAL_SIZE_STR=$(awk -v b="$TOTAL_BYTES" '
    BEGIN {
        if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
        else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
        else if (b >= 1048576) printf "%.1f MB", b / 1048576;
        else if (b >= 1024) printf "%.1f KB", b / 1024;
        else printf "%d B", b;
    }
')

# 4. Confirmation dialog with Zenity
CONFIRM_TEXT="Are you sure you want to start the rsync transfer with the following settings?\n\n"
CONFIRM_TEXT+="・Parent Dir   : $PARENT_DIR\n"
CONFIRM_TEXT+="・Date         : $DATE\n"
CONFIRM_TEXT+="・Run Range    : $RUN_MIN to $RUN_MAX (${RUN_ARRAY[*]})\n"
CONFIRM_TEXT+="・Electronics  : $ELECTRONICS\n"
CONFIRM_TEXT+="・Save Dir     : $SAVE_DIR (available : $LOCAL_AVAIL_STR)\n"
CONFIRM_TEXT+="・Total Files  : $TOTAL_FILES files\n"
CONFIRM_TEXT+="・Total Size   : $TOTAL_SIZE_STR\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=600 --height=380
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# 5. Perform rsync transfer with real-time progress bar
(
    CURRENT=0
    SUCCESS=0
    FAIL=0
    PREV_BYTES=0

    for j in "${RUN_ARRAY[@]}"; do
        CURRENT=$((CURRENT + 1))
        RUN_PADDED=$(printf "%03d" "$j")
        FILE_NAME="precal_raw_kor_run_${DATE}_${RUN_PADDED}.root"
        REMOTE_PATH="$PARENT_DIR/$FILE_NAME"

        INIT_COMP_STR=$(awk -v b="$PREV_BYTES" 'BEGIN {
            if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
            else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
            else if (b >= 1048576) printf "%.1f MB", b / 1048576;
            else if (b >= 1024) printf "%.1f KB", b / 1024;
            else printf "%d B", b;
        }')
        INIT_PCT=$((TOTAL_BYTES > 0 ? PREV_BYTES * 100 / TOTAL_BYTES : 0))

        echo "# Transferring ($CURRENT/$TOTAL_FILES):\n Remote: $REMOTE_PATH\n Local: $SAVE_DIR/ (available : $LOCAL_AVAIL_STR)\n completed $INIT_COMP_STR / total $TOTAL_SIZE_STR\n transfer speed 0.0 MB/s\n estimated remaining time : --h --m --sec"
        echo "$INIT_PCT"

        # Execute rsync and parse real-time progress
        rsync --progress -e "ssh -p $SSH_PORT -o BatchMode=yes" "$SSH_USER@$SSH_HOST:$REMOTE_PATH" "$SAVE_DIR/" 2>&1 \
        | stdbuf -oL tr '\r' '\n' \
        | stdbuf -oL awk \
              -v current_idx="$CURRENT" \
              -v total_files="$TOTAL_FILES" \
              -v remote_path="$REMOTE_PATH" \
              -v target_dir="$SAVE_DIR" \
              -v avail_space="$LOCAL_AVAIL_STR" \
              -v prev_bytes="$PREV_BYTES" \
              -v total_bytes="$TOTAL_BYTES" \
              -v total_size_str="$TOTAL_SIZE_STR" '
            function format_bytes(b) {
                if (b >= 1099511627776) return sprintf("%.1f TB", b / 1099511627776);
                if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824);
                if (b >= 1048576) return sprintf("%.1f MB", b / 1048576);
                if (b >= 1024) return sprintf("%.1f KB", b / 1024);
                return sprintf("%d B", b);
            }
            function parse_speed_bytes(s,   num, unit, val) {
                num = s; gsub(/[^0-9.]/, "", num);
                unit = tolower(s); gsub(/[^a-z\/]/, "", unit);
                val = num + 0;
                if (unit ~ /g/) return val * 1073741824;
                if (unit ~ /m/) return val * 1048576;
                if (unit ~ /k/) return val * 1024;
                if (unit ~ /b/) return val;
                return 0;
            }
            function format_speed(speed_bytes) {
                if (speed_bytes <= 0) return "0.0 MB/s";
                if (speed_bytes >= 1073741824) return sprintf("%.1f GB/s", speed_bytes / 1073741824);
                if (speed_bytes >= 1048576) return sprintf("%.1f MB/s", speed_bytes / 1048576);
                if (speed_bytes >= 1024) return sprintf("%.1f KB/s", speed_bytes / 1024);
                return sprintf("%d B/s", speed_bytes);
            }
            function calc_eta(rem_bytes, speed_bytes,   sec, h, m, s) {
                if (speed_bytes <= 0) return "--h --m --sec";
                sec = int(rem_bytes / speed_bytes);
                h = int(sec / 3600);
                m = int((sec % 3600) / 60);
                s = sec % 60;
                return sprintf("%02dh %02dm %02dsec", h, m, s);
            }
            /\%/ {
                p_idx = 0;
                for (k = 1; k <= NF; k++) {
                    if ($k ~ /\%$/) {
                        p_idx = k;
                        break;
                    }
                }
                if (p_idx > 1) {
                    b_str = $(p_idx - 1);
                    gsub(/,/, "", b_str);
                    bytes_curr = b_str + 0;
                    speed_raw = $(p_idx + 1);

                    total_curr = prev_bytes + bytes_curr;
                    rem_bytes = total_bytes - total_curr;
                    if (rem_bytes < 0) rem_bytes = 0;

                    pct = (total_bytes > 0) ? int(total_curr * 100 / total_bytes) : int(current_idx * 100 / total_files);
                    if (pct > 100) pct = 100;

                    speed_b = parse_speed_bytes(speed_raw);
                    speed_str = (speed_b > 0) ? format_speed(speed_b) : speed_raw;
                    eta_str = calc_eta(rem_bytes, speed_b);
                    comp_str = format_bytes(total_curr);

                    print "# Transferring (" current_idx "/" total_files "):\n" \
                          " Remote: " remote_path "\n" \
                          " Local: " target_dir "/ (available : " avail_space ")\n" \
                          " completed " comp_str " / total " total_size_str "\n" \
                          " transfer speed " speed_str "\n" \
                          " estimated remaining time : " eta_str;
                    print pct;
                    fflush();
                }
            }
        '
        RSYNC_STATUS=${PIPESTATUS[0]}

        if [ $RSYNC_STATUS -eq 0 ]; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAIL=$((FAIL + 1))
        fi

        # Update PREV_BYTES for the next file
        XFER_SIZE=$(wc -c < "$SAVE_DIR/$FILE_NAME" 2>/dev/null | tr -d ' ')
        if [[ "$XFER_SIZE" =~ ^[0-9]+$ ]]; then
            PREV_BYTES=$((PREV_BYTES + XFER_SIZE))
        fi
    done

    echo "# Processing Completed: Success $SUCCESS / Failure $FAIL"
    echo "100"
    sleep 1

) | zenity --progress \
    --title="rsync Transfer Progress (KOR -> precalib)" \
    --width=700 \
    --height=320 \
    --percentage=0 \
    --auto-close \
    --no-cancel

# 6. Completion notification
zenity --info --title="Processing Completed" \
    --text="rsync transfer completed.\nSuccess: $SUCCESS files\nFailure: $FAIL files\n\nSave directory: $SAVE_DIR" \
    --width=500 --height=180