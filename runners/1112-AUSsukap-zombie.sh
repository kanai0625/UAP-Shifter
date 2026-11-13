#!/bin/bash

# SSH settings for remote target (sukap / hkpd)
SSH_USER="hkpd"
SSH_HOST="10.220.11.100" 
SSH_PORT="22"

# 1. Check if required commands are installed
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    zenity --error --title="Missing Dependency" \
        --text="sshpass is not installed.\nPlease install it using: sudo apt install sshpass" \
        --width=500 --height=180
    exit 1
fi

# 2. GUI for input parameters with empty fields and password entry
INPUTS=$(zenity --forms --title="Data Integrity Verification Tool (To sukap)" \
    --width=750 --height=580 \
    --text="Enter parameters (leave blank to use default values shown in brackets):" \
    --add-entry="Source Base Directory [default: /media/precalib/rawdata/production/aus]" \
    --add-entry="Date (yyyymmdd) [example: 20260928]" \
    --add-entry="Time (hhmmss) [example: 231031]" \
    --add-entry="PMT [1 or 2]  (PMT1: wave 0,1,3,7 / PMT2: wave 0,1,5,7)" \
    --add-entry="PMT Label [example: EM5650-H]" \
    --add-entry="Theta(deg) [default: 0,10,20,30,40,50,60,70,80]" \
    --add-entry="Phi(deg) [default: 0,90,180,270]" \
    --add-entry="Target Base Directory [default: /disk03/hk04/precalib/production/aus]" \
    --add-entry="Digitizer [caendigi or hkelec, default: caendigi]" \
    --add-password="Password for ${SSH_USER}@${SSH_HOST}" \
    --separator="|")

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Verification cancelled."
    exit 0
fi

# 3. Parse inputs and set default values if fields are left empty
IFS='|' read -r SRC_DIR DATE TIME PMT PMT_LABEL THETA PHI TARGET_BASE_DIR Digitizer SSH_PASS <<< "$INPUTS"

SRC_DIR=${SRC_DIR:-/media/precalib/rawdata/production/aus}
DATE=${DATE:-}
TIME=${TIME:-}
PMT=${PMT:-}
THETA=${THETA:-0,10,20,30,40,50,60,70,80}
PHI=${PHI:-0,90,180,270}
TARGET_BASE_DIR=${TARGET_BASE_DIR:-/disk03/hk04/precalib/production/aus}
Digitizer=${Digitizer:-caendigi}

# Check if password was entered
if [ -z "$SSH_PASS" ]; then
    zenity --error --title="Error" --text="Password cannot be empty." --width=400 --height=150
    exit 1
fi

# Remove trailing/leading slashes and build final target directory
SRC_DIR=$(echo "$SRC_DIR" | sed 's|/$||')
TARGET_BASE_DIR=$(echo "$TARGET_BASE_DIR" | sed 's|/$||')

# Digitizer (electronics) -> local: <source base>/<digitizer>, remote: <target base>/<digitizer>
Digitizer=$(echo "${Digitizer:-caendigi}" | tr -d ' /' | tr 'A-Z' 'a-z')
if [ "$Digitizer" != "caendigi" ] && [ "$Digitizer" != "hkelec" ]; then
    zenity --error --title="Error" --text="Digitizer must be caendigi or hkelec." --width=450 --height=150
    exit 1
fi
SRC_DIR="$SRC_DIR/$Digitizer"

TARGET_DIR="${TARGET_BASE_DIR}/${Digitizer}"

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

# Test SSH connection and password
export SSHPASS="$SSH_PASS"
sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "exit" 2>/dev/null
if [ $? -ne 0 ]; then
    zenity --error --title="SSH Connection Error" \
        --text="Failed to connect to remote server ($SSH_USER@$SSH_HOST).\nPlease check your password and network connection." \
        --width=550 --height=200
    unset SSHPASS
    exit 1
fi

CHECK_MODE="MD5 Hash Comparison + Remote cmp (Byte-by-byte)"

# 4. Confirmation dialog
CONFIRM_TEXT="Are you sure you want to start the data verification with the following settings?\n\n"
CONFIRM_TEXT+="・Local Dir     : $SRC_DIR\n"
CONFIRM_TEXT+="・Date          : $DATE\n"
CONFIRM_TEXT+="・Time          : $TIME\n"
CONFIRM_TEXT+="・PMT           : PMT$PMT (wave ${WAVE_ARRAY[*]})\n"
CONFIRM_TEXT+="・PMT Label     : $PMT_LABEL\n"
CONFIRM_TEXT+="・Theta         : $THETA\n"
CONFIRM_TEXT+="・Phi           : $PHI\n"
CONFIRM_TEXT+="・Digitizer     : $Digitizer\n"
CONFIRM_TEXT+="・Remote Dir    : sukap:$TARGET_DIR\n"
CONFIRM_TEXT+="・Total Files   : $TOTAL_FILES files\n"
CONFIRM_TEXT+="・Check Mode    : $CHECK_MODE\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=680 --height=430
if [ $? -ne 0 ]; then
    echo "Verification cancelled by user."
    unset SSHPASS
    exit 0
fi

# Prepare verification report header
REPORT_FILE=$(mktemp)
echo "=== Data Integrity Verification Report (To sukap) ===" > "$REPORT_FILE"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "Target: $SSH_USER@$SSH_HOST:$TARGET_DIR" >> "$REPORT_FILE"
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

    for theta in "${THETA_ARRAY[@]}"; do
        for phi in "${PHI_ARRAY[@]}"; do
            for i in "${WAVE_ARRAY[@]}"; do
                CURRENT=$((CURRENT + 1))
                
                REL_PATH="scan_${DATE}_${TIME}/$PMT_LABEL/wavesave_theta${theta}_phi${phi}/wave${i}.dat"
                
                LOCAL_FILE="$SRC_DIR/$REL_PATH"
                REMOTE_FILE="$TARGET_DIR/$REL_PATH"

                PCT=$((CURRENT * 100 / TOTAL_FILES))
                echo "# Verifying ($CURRENT/$TOTAL_FILES):\n Local: $LOCAL_FILE\n Remote: $REMOTE_FILE"
                echo "$PCT"

                # 1. Check if local file exists
                if [ ! -f "$LOCAL_FILE" ]; then
                    echo "[LOCAL MISSING] Local file does not exist: $LOCAL_FILE" >> "$REPORT_FILE"
                    LOCAL_MISSING_COUNT=$((LOCAL_MISSING_COUNT + 1))
                    continue
                fi

                # 2. Check if remote file exists
                REMOTE_EXISTS=$(sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "test -f '$REMOTE_FILE' && echo 'yes' || echo 'no'" 2>/dev/null)
                if [ "$REMOTE_EXISTS" != "yes" ]; then
                    echo "[REMOTE MISSING] Remote file does not exist: $REMOTE_FILE" >> "$REPORT_FILE"
                    REMOTE_MISSING_COUNT=$((REMOTE_MISSING_COUNT + 1))
                    continue
                fi

                # 3. Compute local MD5 hash
                LOCAL_MD5=$(md5sum "$LOCAL_FILE" | awk '{print $1}')

                # 4. Compute remote MD5 hash
                REMOTE_MD5=$(sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "md5sum '$REMOTE_FILE' 2>/dev/null" | awk '{print $1}')

                # 5. Compare MD5 hashes
                if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
                    echo "[MISMATCH] MD5 mismatch on wave${i}.dat (theta${theta}_phi${phi})" >> "$REPORT_FILE"
                    echo "  Local : $LOCAL_MD5" >> "$REPORT_FILE"
                    echo "  Remote: $REMOTE_MD5" >> "$REPORT_FILE"
                    MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
                else
                    # 6. Binary check using cmp command via SSH pipe
                    sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "cat '$REMOTE_FILE'" 2>/dev/null | cmp -s "$LOCAL_FILE" -
                    if [ $? -ne 0 ]; then
                        echo "[CORRUPT] MD5 matched but cmp (binary) test failed: $LOCAL_FILE" >> "$REPORT_FILE"
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
    --title="Verifying Files Progress (To sukap)" \
    --width=700 \
    --height=320 \
    --percentage=0 \
    --auto-close \
    --no-cancel

# Clear password environment variable
unset SSHPASS

# 6. Display report in Zenity text-info dialog
zenity --text-info \
    --title="File Verification Result" \
    --filename="$REPORT_FILE" \
    --width=700 \
    --height=450

rm -f "$REPORT_FILE"