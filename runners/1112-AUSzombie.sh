#!/bin/bash

# SSH settings 
SSH_USER="hyperkaus"
SSH_HOST="10.200.102.67"   # AUS DAQ PC (hk-precal-aus1)
SSH_PORT="22"                

# 1. Check if Zenity is installed
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

# 2. GUI for input parameters with empty fields for easy copy-pasting
INPUTS=$(zenity --forms --title="Data Integrity Verification Tool (AUS)" \
    --width=750 --height=420 \
    --text="Enter parameters (leave blank to use default values shown in brackets):" \
    --add-entry="Parent Directory [default: /home/hyperkaus/WaveDumpSaves]" \
    --add-entry="Date (yyyymmdd) [example: 20260928]" \
    --add-entry="Time (hhmmss) [example: 231031]" \
    --add-entry="PMT [1 or 2]  (PMT1: wave 0,1,3,7 / PMT2: wave 0,1,5,7)" \
    --add-entry="PMT Label [example: EM5650-H]" \
    --add-entry="Theta(deg) [default: 0,10,20,30,40,50,60,70,80]" \
    --add-entry="Phi(deg) [default: 0,90,180,270]" \
    --add-entry="Save Base Dir [default: /media/precalib/rawdata/production/aus]" \
    --add-entry="Electronics [caendigi or hkelec, default: caendigi]" \
    --separator="|")

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Processing cancelled."
    exit 0
fi

# 3. Parse inputs and set default values if fields are left empty
IFS='|' read -r PARENT_DIR DATE TIME PMT PMT_LABEL THETA PHI SAVE_DIR ELECTRONICS <<< "$INPUTS"

PARENT_DIR=${PARENT_DIR:-/home/hyperkaus/WaveDumpSaves}
DATE=${DATE:-}
TIME=${TIME:-}
PMT=${PMT:-}
THETA=${THETA:-0,10,20,30,40,50,60,70,80}
PHI=${PHI:-0,90,180,270}
SAVE_DIR=${SAVE_DIR:-/media/precalib/rawdata/production/aus}

# Construct Scan Directory Name
SCAN_DIR="scan_${DATE}_${TIME}"

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

# Parse Theta and Phi into arrays
IFS=',' read -r -a THETA_ARRAY <<< "$THETA"
IFS=',' read -r -a PHI_ARRAY <<< "$PHI"
# PMT1 -> wave 0,1,3,7 / PMT2 -> wave 0,1,5,7
PMT=$(echo "$PMT" | tr -d ' ' | tr 'A-Z' 'a-z'); PMT=${PMT#pmt}
case "$PMT" in
    1) WAVE_ARRAY=(0 1 3 7) ;;
    2) WAVE_ARRAY=(0 1 5 7) ;;
    *) zenity --error --title="Error" --text="PMT must be 1 or 2." --width=450 --height=150
       exit 1 ;;
esac
# PMT label directory (e.g. EM5650-H)
PMT_LABEL=$(echo "$PMT_LABEL" | tr -d ' ')
if [ -z "$PMT_LABEL" ] || [[ "$PMT_LABEL" == */* ]]; then
    zenity --error --title="Error" --text="PMT Label is required (e.g. EM5650-H)." --width=450 --height=150
    exit 1
fi

if [ ${#THETA_ARRAY[@]} -eq 0 ] || [ ${#PHI_ARRAY[@]} -eq 0 ]; then
    zenity --error --title="Error" --text="Theta or Phi is not specified correctly." --width=500 --height=180
    exit 1
fi

TOTAL_FILES=$(( ${#THETA_ARRAY[@]} * ${#PHI_ARRAY[@]} * ${#WAVE_ARRAY[@]} ))

# Get available disk space in the save directory (For confirmation GUI compatibility)
LOCAL_AVAIL_RAW=$(df -h "$SAVE_DIR" 2>/dev/null | tail -n 1 | awk '{print $4}')
LOCAL_AVAIL_STR=$(echo "$LOCAL_AVAIL_RAW" | sed -E 's/([0-9.]+)([A-Za-z]+)/\1 \2B/')
[ -z "$LOCAL_AVAIL_STR" ] && LOCAL_AVAIL_STR="N/A"

# List of remote paths to be transferred/verified
REMOTE_PATHS=()
for theta in "${THETA_ARRAY[@]}"; do
    for phi in "${PHI_ARRAY[@]}"; do
        for i in "${WAVE_ARRAY[@]}"; do
            REMOTE_PATHS+=("$PARENT_DIR/$SCAN_DIR/$PMT_LABEL/wavesave_theta${theta}_phi${phi}/wave${i}.dat")
        done
    done
done

# Get total size of files from the remote server
TOTAL_BYTES=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "wc -c ${REMOTE_PATHS[*]} 2>/dev/null | tail -n 1 | awk '{print \$1}'")

# Check if remote files exist
if [ -z "$TOTAL_BYTES" ] || [ "$TOTAL_BYTES" -eq 0 ]; then
    zenity --error --title="File Not Found" \
        --text="Remote files could not be found.\n\nChecked Path Example:\n${REMOTE_PATHS[0]}\n\nPlease check your input settings." \
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

CHECK_MODE="MD5 Hash Comparison + cmp (Byte-by-byte)"

# 4. Confirmation dialog with Zenity
CONFIRM_TEXT="Are you sure you want to start the data verification with the following settings?\n\n"
CONFIRM_TEXT+="・Parent Dir   : $PARENT_DIR\n"
CONFIRM_TEXT+="・Scan Dir     : $SCAN_DIR/$PMT_LABEL\n"
CONFIRM_TEXT+="・Date         : $DATE\n"
CONFIRM_TEXT+="・Time         : $TIME\n"
CONFIRM_TEXT+="・PMT          : PMT$PMT (wave ${WAVE_ARRAY[*]})\n"
CONFIRM_TEXT+="・PMT Label    : $PMT_LABEL\n"
CONFIRM_TEXT+="・Electronics  : $ELECTRONICS\n"
CONFIRM_TEXT+="・Theta        : $THETA\n"
CONFIRM_TEXT+="・Phi          : $PHI\n"
CONFIRM_TEXT+="・Local Dir    : $SAVE_DIR (available : $LOCAL_AVAIL_STR)\n"
CONFIRM_TEXT+="・Total Files  : $TOTAL_FILES files\n"
CONFIRM_TEXT+="・Total Size   : $TOTAL_SIZE_STR\n"
CONFIRM_TEXT+="・Check Mode   : $CHECK_MODE\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=600 --height=420
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# Prepare verification report header
REPORT_FILE=$(mktemp)
echo "=== Data Integrity Verification Report (AUS) ===" > "$REPORT_FILE"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "Check Mode: $CHECK_MODE" >> "$REPORT_FILE"
echo "----------------------------------------------------" >> "$REPORT_FILE"

# 5. Perform verification loop
(
    CURRENT=0
    MATCH_COUNT=0
    MISMATCH_COUNT=0
    LOCAL_MISSING_COUNT=0
    REMOTE_MISSING_COUNT=0
    CORRUPT_COUNT=0

    for theta in "${THETA_ARRAY[@]}"; do
        for phi in "${PHI_ARRAY[@]}"; do
            for i in "${WAVE_ARRAY[@]}"; do
                CURRENT=$((CURRENT + 1))
                
                REL_PATH="$SCAN_DIR/$PMT_LABEL/wavesave_theta${theta}_phi${phi}/wave${i}.dat"
                
                REMOTE_PATH="$PARENT_DIR/$REL_PATH"
                LOCAL_PATH="$SAVE_DIR/$REL_PATH"

                PCT=$((CURRENT * 100 / TOTAL_FILES))
                echo "# Verifying ($CURRENT/$TOTAL_FILES):\n Remote: $REMOTE_PATH\n Local: $LOCAL_PATH"
                echo "$PCT"

                # 1. Check if local file exists
                if [ ! -f "$LOCAL_PATH" ]; then
                    echo "[LOCAL MISSING] Local file does not exist: $LOCAL_PATH" >> "$REPORT_FILE"
                    LOCAL_MISSING_COUNT=$((LOCAL_MISSING_COUNT + 1))
                    continue
                fi

                # 2. Check if remote file exists
                REMOTE_EXISTS=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "test -f '$REMOTE_PATH' && echo 'yes' || echo 'no'")
                if [ "$REMOTE_EXISTS" != "yes" ]; then
                    echo "[REMOTE MISSING] Remote file does not exist: $REMOTE_PATH" >> "$REPORT_FILE"
                    REMOTE_MISSING_COUNT=$((REMOTE_MISSING_COUNT + 1))
                    continue
                fi

                # 3. Compute local MD5 hash
                LOCAL_MD5=$(md5sum "$LOCAL_PATH" | awk '{print $1}')

                # 4. Compute remote MD5 hash
                REMOTE_MD5=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "md5sum '$REMOTE_PATH' 2>/dev/null" | awk '{print $1}')

                # 5. Compare MD5 hashes
                if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
                    echo "[MISMATCH] MD5 mismatch on wave${i}.dat (theta${theta}_phi${phi})" >> "$REPORT_FILE"
                    echo "  Local : $LOCAL_MD5" >> "$REPORT_FILE"
                    echo "  Remote: $REMOTE_MD5" >> "$REPORT_FILE"
                    MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
                else
                    # 6. Binary check using cmp command via SSH pipe
                    # Uses '-' to compare local file with standard input coming from ssh
                    ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "cat '$REMOTE_PATH'" | cmp -s "$LOCAL_PATH" -
                    if [ $? -ne 0 ]; then
                        echo "[CORRUPT] MD5 matched but cmp (binary) test failed: $LOCAL_PATH" >> "$REPORT_FILE"
                        CORRUPT_COUNT=$((CORRUPT_COUNT + 1))
                    else
                        echo "[OK] wave${i}.dat (theta${theta}_phi${phi}) (MD5: $LOCAL_MD5)" >> "$REPORT_FILE"
                        MATCH_COUNT=$((MATCH_COUNT + 1))
                    fi
                fi
            done
        done
    done

    echo "----------------------------------------------------" >> "$REPORT_FILE"
    echo "Summary:" >> "$REPORT_FILE"
    echo " Total Verified : $TOTAL_FILES" >> "$REPORT_FILE"
    echo " Passed (OK)    : $MATCH_COUNT" >> "$REPORT_FILE"
    echo " Hash Mismatches: $MISMATCH_COUNT" >> "$REPORT_FILE"
    echo " Cmp Mismatches : $CORRUPT_COUNT" >> "$REPORT_FILE"
    echo " Local Missing  : $LOCAL_MISSING_COUNT" >> "$REPORT_FILE"
    echo " Remote Missing : $REMOTE_MISSING_COUNT" >> "$REPORT_FILE"

) | zenity --progress \
    --title="Verifying Files Progress" \
    --width=700 \
    --height=320 \
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