#!/bin/bash

# SSH settings (precalkor)
SSH_USER="precalkor"
SSH_HOST="10.200.102.65"   # KOR DAQ PC (hk-precal-kor)
SSH_PORT="4280"

# 1. Check if Zenity is installed
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

# 2. GUI for input parameters with Zenity forms
INPUTS=$(zenity --forms --title="ROOT File Integrity Verification Tool (precalkor)" \
    --width=750 --height=450 \
    --text="Enter parameters (leave blank to use default values shown in brackets):" \
    --add-entry="Parent Directory [default: /media/precalkor/HD-EDS-E/Data_Backup/RAW/Laser]" \
    --add-entry="Date (yyyymmdd) [example: 20260928]" \
    --add-entry="Run Min [example: 0]" \
    --add-entry="Run Max [example: 3]" \
    --add-entry="Save Base Dir [default: /media/precalib/rawdata/production/kor]" \
    --add-entry="Electronics [caendigi or hkelec, default: caendigi]" \
    --separator="|" 2>/dev/null)

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Verification cancelled."
    exit 0
fi

# 3. Parse inputs and fill default values
IFS='|' read -r PARENT_DIR DATE RUN_MIN RUN_MAX SAVE_DIR ELECTRONICS <<< "$INPUTS"

PARENT_DIR=${PARENT_DIR:-/media/precalkor/HD-EDS-E/Data_Backup/RAW/Laser}
DATE=${DATE:-}
RUN_MIN=${RUN_MIN:-}
RUN_MAX=${RUN_MAX:-}
SAVE_DIR=${SAVE_DIR:-/media/precalib/rawdata/production/kor}

# Validate that Run Min and Run Max are non-negative integers
if ! [[ "$RUN_MIN" =~ ^[0-9]+$ ]] || ! [[ "$RUN_MAX" =~ ^[0-9]+$ ]]; then
    zenity --error --title="Error" --text="Run Min and Run Max must be integer values." --width=450 --height=150 2>/dev/null
    exit 1
fi

# Convert relative path to absolute path if necessary and remove trailing slash
CLEAN_FOLDER=$(echo "$PARENT_DIR" | sed 's|/$||')
if [[ "$CLEAN_FOLDER" != /* ]]; then
    REMOTE_DIR="/home/$SSH_USER/$CLEAN_FOLDER"
else
    REMOTE_DIR="$CLEAN_FOLDER"
fi

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
    zenity --error --title="Error" --text="No valid run numbers in the specified range." --width=500 --height=180 2>/dev/null
    exit 1
fi

TOTAL_FILES=${#RUN_ARRAY[@]}
HAS_ROOT_CMD=$(command -v root &> /dev/null && echo "yes" || echo "no")

# Determine verification mode text
CHECK_MODE="MD5 Hash Comparison"
if [ "$HAS_ROOT_CMD" = "yes" ]; then
    CHECK_MODE="$CHECK_MODE + ROOT Zombie Check"
fi

# 4. Confirmation dialog with Zenity
CONFIRM_TEXT="Are you sure you want to start the file verification with the following settings?\n\n"
CONFIRM_TEXT+="・Remote Dir   : $REMOTE_DIR\n"
CONFIRM_TEXT+="・Date         : $DATE\n"
CONFIRM_TEXT+="・Run Range    : $RUN_MIN to $RUN_MAX (${RUN_ARRAY[*]})\n"
CONFIRM_TEXT+="・Electronics  : $ELECTRONICS\n"
CONFIRM_TEXT+="・Local Dir    : $SAVE_DIR\n"
CONFIRM_TEXT+="・Total Files  : $TOTAL_FILES files\n"
CONFIRM_TEXT+="・Check Mode   : $CHECK_MODE\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=600 --height=380 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Verification cancelled by user."
    exit 0
fi

# Prepare verification report header
REPORT_FILE=$(mktemp)
echo "=== ROOT File Verification Report (precalkor) ===" > "$REPORT_FILE"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "Check Mode: $CHECK_MODE" >> "$REPORT_FILE"
echo "----------------------------------------------------" >> "$REPORT_FILE"

# 5. Perform file integrity verification loop
(
    CURRENT=0
    MATCH_COUNT=0
    MISMATCH_COUNT=0
    LOCAL_MISSING_COUNT=0
    REMOTE_MISSING_COUNT=0
    CORRUPT_COUNT=0

    for j in "${RUN_ARRAY[@]}"; do
        CURRENT=$((CURRENT + 1))
        RUN_PADDED=$(printf "%03d" "$j")
        FILE_NAME="precal_raw_kor_run_${DATE}_${RUN_PADDED}.root"
        
        LOCAL_FILE="$SAVE_DIR/$FILE_NAME"
        REMOTE_FILE="$REMOTE_DIR/$FILE_NAME"

        PCT=$((CURRENT * 100 / TOTAL_FILES))
        echo "# Verifying ($CURRENT/$TOTAL_FILES): $FILE_NAME"
        echo "$PCT"

        # 1. Check if local file exists
        if [ ! -f "$LOCAL_FILE" ]; then
            echo "[LOCAL MISSING] Local file does not exist: $LOCAL_FILE" >> "$REPORT_FILE"
            LOCAL_MISSING_COUNT=$((LOCAL_MISSING_COUNT + 1))
            continue
        fi

        # 2. Check if remote file exists
        REMOTE_EXISTS=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "test -f '$REMOTE_FILE' && echo 'yes' || echo 'no'")
        if [ "$REMOTE_EXISTS" != "yes" ]; then
            echo "[REMOTE MISSING] Remote file does not exist: $REMOTE_FILE" >> "$REPORT_FILE"
            REMOTE_MISSING_COUNT=$((REMOTE_MISSING_COUNT + 1))
            continue
        fi

        # 3. Compute local MD5 hash
        LOCAL_MD5=$(md5sum "$LOCAL_FILE" | awk '{print $1}')

        # 4. Compute remote MD5 hash
        REMOTE_MD5=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "md5sum '$REMOTE_FILE' 2>/dev/null" | awk '{print $1}')

        # 5. Compare MD5 hashes
        if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
            echo "[MISMATCH] MD5 mismatch on $FILE_NAME" >> "$REPORT_FILE"
            echo "  Local : $LOCAL_MD5" >> "$REPORT_FILE"
            echo "  Remote: $REMOTE_MD5" >> "$REPORT_FILE"
            MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
        else
            # 6. Optional: ROOT Zombie Check (if root command is available locally)
            IS_ZOMBIE=0
            if [ "$HAS_ROOT_CMD" = "yes" ]; then
                root -l -b -q -e "TFile f(\"$LOCAL_FILE\"); if (f.IsZombie()) gSystem->Exit(1); else gSystem->Exit(0);" &>/dev/null
                if [ $? -ne 0 ]; then
                    IS_ZOMBIE=1
                fi
            fi

            if [ $IS_ZOMBIE -eq 1 ]; then
                echo "[CORRUPT] MD5 matched but ROOT Zombie test failed: $LOCAL_FILE" >> "$REPORT_FILE"
                CORRUPT_COUNT=$((CORRUPT_COUNT + 1))
            else
                echo "[OK] $FILE_NAME (MD5: $LOCAL_MD5)" >> "$REPORT_FILE"
                MATCH_COUNT=$((MATCH_COUNT + 1))
            fi
        fi
    done

    echo "----------------------------------------------------" >> "$REPORT_FILE"
    echo "Summary:" >> "$REPORT_FILE"
    echo " Total Verified : $TOTAL_FILES" >> "$REPORT_FILE"
    echo " Passed (OK)    : $MATCH_COUNT" >> "$REPORT_FILE"
    echo " Hash Mismatches: $MISMATCH_COUNT" >> "$REPORT_FILE"
    echo " Corrupt ROOT   : $CORRUPT_COUNT" >> "$REPORT_FILE"
    echo " Local Missing  : $LOCAL_MISSING_COUNT" >> "$REPORT_FILE"
    echo " Remote Missing : $REMOTE_MISSING_COUNT" >> "$REPORT_FILE"

) | zenity --progress \
    --title="Verifying Files (precalkor)..." \
    --width=600 \
    --height=200 \
    --percentage=0 \
    --auto-close \
    --no-cancel 2>/dev/null

# 6. Display report in Zenity text-info dialog
zenity --text-info \
    --title="File Verification Result" \
    --filename="$REPORT_FILE" \
    --width=650 \
    --height=450 2>/dev/null

rm -f "$REPORT_FILE"