#!/bin/bash
# =====================================================================
#  runners/aus_run_point.sh  –  AUS analysis of ONE point (thetaX_phiY)
#
#    raw2root  runners/aus_raw2root.py   (skipped when -root/-vroot are given, e.g. from a job)
#                ch0 pedestal = last 30 samples, others = first 40;  PulseStart = first sample > NSIGMA*sigma
#                charge = sum(V - baseline) in [PS-10, PS+50) x 2 ns / 50 Ohm  [pC]  (DT5730S)
#                + second file with a FIXED PMT threshold of VCUT mV (rising edge of the largest pulse)
#    charge    runners/aus_root2csv.py --kind charge   (main ROOT file)
#                4 steps: 1 pedestal  2 SPE start = most populated 0.05 pC bin above the pedestal (ped + 3 sigma),
#                         SPE + 2PE fitted in 1 .. 5 pC  3 pedestal + SPE + 2PE  4 + backscatter
#                         (2PE / SPE fixed by Poisson statistics: occupancy from the pedestal fraction)
#    timing    runners/aus_root2csv.py --kind timing   (fixed-threshold ROOT file)
#                window = peak of the -520..520 ns histogram (2 ns bins) +- TWIN/2 (PMT), SiPM 60 ns
#                PMT: prompt EMG -> late-pulse EMG -> linear background -> all free  (unbinned NLL)
#    plots     runners/aus_point_plots.py   PulseStart / delta t / charge / PeakHeight + summary.txt
#    SiPM      runners/aus_sipm_waveforms.py (100 waveforms, every 100th)
#              runners/aus_sipm_wfdist.py    (waveform distributions: 10 % / 100 % / max > 100 mV)
#
#  Usage (sukap, UAP-Shifter):
#    runners/aus_run_point.sh -raw /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B \
#                             -point theta0_phi0
#    # from the ROOT files of a job (no raw2root):
#    runners/aus_run_point.sh -raw <...>/EM5370-B -point theta0_phi0 -pmt-ch 5 \
#        -root  <processed>/scan_.../EM5370-B/outputs/output_theta0_phi0.root \
#        -vroot <processed>/scan_.../EM5370-B/outputs_vcut2.0mV/output_theta0_phi0.root \
#        -out   <processed>/scan_.../EM5370-B/theta0_phi0
#  Options:
#    -raw DIR          PMT directory with wavesave_thetaX_phiY/  (needed for raw2root and the SiPM plots)
#    -point P          thetaX_phiY                                                (default theta0_phi0)
#    -root F / -vroot F  existing main / fixed-threshold ROOT files -> raw2root skipped
#    -out DIR          output directory   (default: $UAP_HOME/aus_point_outputs/<scan>_<PMT>_<point>_n<N>)
#    -serial S         PMT serial for titles / CSV                          (default: name of -raw)
#    -pmt-ch C         PMT channel 3|5          (default: 5 if wave5.dat exists, else 3)
#    -nevent N         raw2root events (0 = all)                                  (default 300000)
#    -nsigma S         PulseStart threshold in baseline sigma                     (default 2.2)
#    -nconsec K        consecutive samples above threshold                        (default 1)
#    -vcut V           fixed PMT pulse-height threshold for the timing [mV]       (default 2.0, 0 = off)
#    -vcut-edge E      max: rising edge of the largest pulse (default) | first: first crossing
#    -twin T           PMT timing window width [ns]                               (default 100)
#    -sipm-twin T      SiPM timing window width [ns]                              (default 60)
#    -prompt-range L,H timing step 1: prompt EMG fitted in peak+L .. peak+H ns    (default -10,6)
#    -no-late          PMT timing without the late-pulse EMG (one EMG + -tbkg background)
#    -tbkg B           with -no-late: const (default) | linear | none
#    -spe-range L,H    charge step 2: SPE + 2PE fit range [pC]                    (default 1,5)
#    -spe-gap N        charge step 2: SPE start searched above pedestal + N sigma (default 3)
#    -spe-min Q        charge step 2: SPE start searched above Q pC instead       (default: -spe-gap)
#    -spe-hw W         charge step 2/3: SPE mean kept in start / step-2 mean +- W pC (default 1.0)
#    -pe2-free         charge: 2PE yield free (default: Poisson, N_2PE/N_SPE = occupancy/2)
#    -spe-bound N      charge step 4: SPE = step 3 +- N x fit error               (default 10)
#    -set KEY=VALUE    charge config override (repeatable)
#    -single-fit / -three-step   original one-step / previous three-step charge fit
#    -time-nsigma      also the timing fit of the main ROOT file (NSIGMA PulseStart) -> time_nsigma/
#    -uap-plots        original UAP figures
#    -wf-out DIR       directory of the SiPM plots (default <out>/sipm);  -wf-prefix P  file name prefix
#    -wf-nevent N      SiPM waveform distributions: events (0 = all in the file)  (default 0)
#    -vthr V           SiPM waveform distribution of events with max > V mV       (default 100)
#    -skip-sipm        no SiPM waveforms / distributions
#    -no-conda         do not activate the conda environment (already active)
#  Output (<out>): root/ root_vcut<V>mV/ (only when raw2root ran here), charge/, time/, [time_nsigma/],
#                  plots/, sipm/, logs/
# =====================================================================
set -u
RUN_DIR="$(cd "$(dirname "$0")" && pwd)"
UAP_DIR="${UAP_HOME:-$(cd "$RUN_DIR/.." && pwd)}"
CONDA_SH="$UAP_DIR/miniforge3/etc/profile.d/conda.sh"
CONDA_ENV="$UAP_DIR/miniforge3/envs/hkprecal-uap"

RAW=""; POINT="theta0_phi0"; ROOTF=""; VROOTF=""; OUT=""; SERIAL=""; PMT_CH=""
NEVENT=300000; NSIGMA=2.2; NCONSEC=1; VCUT=2.0; VEDGE=max; TWIN=100; SIPM_TWIN=60
CSET=(); TOPT=(); PREFIT=""; TNSIG=0; WF_OUT=""; WF_PREFIX=""; WF_NEVENT=0; VTHR=100; SIPM=1; CONDA=1
while [ $# -gt 0 ]; do
    case "$1" in
        -raw) RAW="$2"; shift 2 ;;
        -point) POINT="$2"; shift 2 ;;
        -root) ROOTF="$2"; shift 2 ;;
        -vroot) VROOTF="$2"; shift 2 ;;
        -out) OUT="$2"; shift 2 ;;
        -serial) SERIAL="$2"; shift 2 ;;
        -pmt-ch) PMT_CH="$2"; shift 2 ;;
        -nevent) NEVENT="$2"; shift 2 ;;
        -nsigma) NSIGMA="$2"; shift 2 ;;
        -nconsec) NCONSEC="$2"; shift 2 ;;
        -vcut) VCUT="$2"; shift 2 ;;
        -vcut-edge) VEDGE="$2"; shift 2 ;;
        -twin) TWIN="$2"; shift 2 ;;
        -sipm-twin) SIPM_TWIN="$2"; shift 2 ;;
        -prompt-range) TOPT+=(--prompt-range "$2"); shift 2 ;;
        -no-late) TOPT+=(--no-late); shift ;;
        -tbkg) TOPT+=(--tbkg "$2"); shift 2 ;;
        -spe-min) CSET+=(--spe-search-min "$2"); shift 2 ;;
        -spe-range) CSET+=(--spe-range "$2"); shift 2 ;;
        -spe-gap) CSET+=(--spe-ped-gap "$2"); shift 2 ;;
        -pe2-free) CSET+=(--pe2-free); shift ;;
        -spe-hw) CSET+=(--spe-halfwidth "$2"); shift 2 ;;
        -spe-bound) CSET+=(--spe-bound "$2"); shift 2 ;;
        -set) CSET+=(--set "$2"); shift 2 ;;
        -single-fit) PREFIT="--no-ped-prefit"; shift ;;
        -three-step) CSET+=(--three-step); shift ;;
        -time-nsigma) TNSIG=1; shift ;;
        -uap-plots) CSET+=(--uap-plots); TOPT+=(--uap-plots); shift ;;
        -wf-out) WF_OUT="$2"; shift 2 ;;
        -wf-prefix) WF_PREFIX="$2"; shift 2 ;;
        -wf-nevent) WF_NEVENT="$2"; shift 2 ;;
        -vthr) VTHR="$2"; shift 2 ;;
        -skip-sipm) SIPM=0; shift ;;
        -no-conda) CONDA=0; shift ;;
        -h|--help) sed -n '2,/^# =====/p' "$0"; exit 0 ;;
        *) echo "unknown option $1  (-h for help)"; exit 1 ;;
    esac
done
WS=""; [ -n "$RAW" ] && WS="$RAW/wavesave_$POINT"
if [ -z "$ROOTF" ]; then
    [ -n "$RAW" ] || { echo "-raw <.../scan_X/PMT> is required (or -root/-vroot)"; exit 1; }
    [ -d "$WS" ] || { echo "not found: $WS"; exit 1; }
fi
PMT=${SERIAL:-$(basename "${RAW:-PMT}")}
SCAN=$( [ -n "$RAW" ] && basename "$(dirname "$RAW")" || echo scan)
if [ -z "$PMT_CH" ]; then
    if [ -n "$WS" ] && [ -f "$WS/wave5.dat" ]; then PMT_CH=5; else PMT_CH=3; fi
fi
VON=$(awk -v v="$VCUT" 'BEGIN{print (v > 0) ? 1 : 0}')
[ -n "$OUT" ] || OUT="$UAP_DIR/aus_point_outputs/${SCAN}_${PMT}_${POINT}_n${NEVENT}"
mkdir -p "$OUT/logs" || exit 1
OUT=$(cd "$OUT" && pwd)

if [ "$CONDA" = 1 ]; then
    set +u
    source "$CONDA_SH" && conda activate "$CONDA_ENV" || { echo "conda activate failed"; exit 1; }
    set -u
fi
export UAP_HOME="$UAP_DIR" PYTHONPATH="$UAP_DIR:${PYTHONPATH:-}" MPLBACKEND=Agg
echo "== $SCAN / $PMT / $POINT   pmt_ch=$PMT_CH  nsigma=$NSIGMA  vcut=${VCUT} mV  twin=${TWIN} ns"
echo "== output: $OUT"

# ---- 1. raw2root (only without -root)
if [ -z "$ROOTF" ]; then
    ROOTF="$OUT/root/output_${POINT}.root"
    VOPT=()
    if [ "$VON" = 1 ]; then
        VROOTF="$OUT/root_vcut${VCUT}mV/output_${POINT}.root"
        VOPT=(--vcut-mv "$VCUT" --vcut-out "$VROOTF" --vcut-edge "$VEDGE")
    fi
    echo "[1/5] raw2root"
    python3 "$RUN_DIR/aus_raw2root.py" --input-dir "$WS" --out "$ROOTF" --nevent "$NEVENT" \
        --nsigma "$NSIGMA" --nconsec "$NCONSEC" ${VOPT[@]+"${VOPT[@]}"} > "$OUT/logs/raw2root.log" 2>&1 \
        || { echo "      FAILED (see logs/raw2root.log)"; exit 1; }
else
    echo "[1/5] raw2root skipped: $ROOTF${VROOTF:+ , $VROOTF}"
fi
[ -s "$ROOTF" ] || { echo "ROOT file missing: $ROOTF"; exit 1; }
TROOT="$ROOTF"
if [ "$VON" = 1 ]; then
    if [ -n "$VROOTF" ] && [ -s "$VROOTF" ]; then TROOT="$VROOTF"
    else echo "      NOTE: fixed-threshold ROOT file missing -> timing from the main ROOT file"; fi
fi

# ---- 2. charge
echo "[2/5] charge fit"
python3 "$RUN_DIR/aus_root2csv.py" --kind charge --root "$ROOTF" --serial "$PMT" --pmt-ch "$PMT_CH" \
    --out "$OUT/charge" $PREFIT ${CSET[@]+"${CSET[@]}"} > "$OUT/logs/charge.log" 2>&1 \
    && echo "      -> $OUT/charge/csv/aus_charge_results.csv" || echo "      FAILED (see logs/charge.log)"

# ---- 3. timing (fixed threshold)
echo "[3/5] timing fit ($( [ "$TROOT" = "$ROOTF" ] && echo "${NSIGMA} sigma PulseStart" || echo "fixed ${VCUT} mV"), PMT window ${TWIN} ns)"
python3 "$RUN_DIR/aus_root2csv.py" --kind timing --root "$TROOT" --serial "$PMT" --pmt-ch "$PMT_CH" \
    --pmt-twin "$TWIN" --sipm-twin "$SIPM_TWIN" ${TOPT[@]+"${TOPT[@]}"} --out "$OUT/time" \
    > "$OUT/logs/time.log" 2>&1 \
    && echo "      -> $OUT/time/csv/aus_results.csv" || echo "      FAILED (see logs/time.log)"
if [ "$TNSIG" = 1 ] && [ "$TROOT" != "$ROOTF" ]; then
    python3 "$RUN_DIR/aus_root2csv.py" --kind timing --root "$ROOTF" --serial "$PMT" --pmt-ch "$PMT_CH" \
        --pmt-twin "$TWIN" --sipm-twin "$SIPM_TWIN" ${TOPT[@]+"${TOPT[@]}"} --out "$OUT/time_nsigma" \
        > "$OUT/logs/time_nsigma.log" 2>&1 \
        && echo "      -> $OUT/time_nsigma/csv/aus_results.csv" || echo "      FAILED (see logs/time_nsigma.log)"
fi

# ---- 4. plots
echo "[4/5] plots"
VR=(); [ "$TROOT" != "$ROOTF" ] && VR=(--vroot "$TROOT" --vlabel "fixed ${VCUT} mV")
python3 "$RUN_DIR/aus_point_plots.py" --out "$OUT/plots" --root "$ROOTF" ${VR[@]+"${VR[@]}"} --pmt-ch "$PMT_CH" \
    --charge-csv "$OUT/charge/csv/aus_charge_results.csv" --timing-csv "$OUT/time/csv/aus_results.csv" \
    > "$OUT/logs/plots.log" 2>&1 && echo "      -> $OUT/plots" || echo "      FAILED (see logs/plots.log)"

# ---- 5. SiPM
if [ "$SIPM" = 1 ] && [ -n "$WS" ] && [ -f "$WS/wave1.dat" ]; then
    WD=${WF_OUT:-$OUT/sipm}
    echo "[5/5] SiPM waveforms + distributions (10 % / 100 % / max > ${VTHR} mV) -> $WD"
    python3 "$RUN_DIR/aus_sipm_waveforms.py" --input-dir "$WS" --ch 1 --n 100 --step 100 --nsigma "$NSIGMA" \
        --nconsec "$NCONSEC" --out-dir "$WD" --prefix "$WF_PREFIX" > "$OUT/logs/sipm_waveforms.log" 2>&1 \
        || echo "      waveforms FAILED (see logs/sipm_waveforms.log)"
    python3 "$RUN_DIR/aus_sipm_wfdist.py" --input-dir "$WS" --ch 1 --nevent "$WF_NEVENT" --vthr "$VTHR" \
        --out-dir "$WD" --prefix "$WF_PREFIX" > "$OUT/logs/sipm_wfdist.log" 2>&1 \
        || echo "      distributions FAILED (see logs/sipm_wfdist.log)"
else
    echo "[5/5] SiPM plots skipped"
fi
[ -s "$OUT/charge/csv/aus_charge_results.csv" ] && [ -s "$OUT/time/csv/aus_results.csv" ] \
    && { echo "== done: $OUT"; echo "AUS_POINT_OK"; } || { echo "== finished with errors: $OUT"; echo "AUS_POINT_NG"; }
