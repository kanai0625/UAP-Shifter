UAP on Shifter PC /home/precalib/shiftertool/UAP/hkprecal-uap

# environment setting before running UAP fixed
## 0.1 : Move to the directory of UAP

```
cd /home/precalib/shiftertool/UAP/hkprecal-uap
```

## 0.2 : Input environment paths and activate the virtual environment (all paths are fixed)
```
export PYRATE_HOME=/media/precalib/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61
export KOR_NTP_HOME=/media/precalib/waveformreader/kor_ntp
export UAP_ROOT_THISROOT=/home/shuoyu/.local/miniforge3/envs/hkprecal-uap/bin/thisroot.sh
source /home/shuoyu/.local/miniforge3/etc/profile.d/conda.sh
conda activate /home/shuoyu/.local/miniforge3/envs/hkprecal-uap
```

## 0.3 : Confirmation of the environment
```
command -v python
python --version
root-config --version
command -v pyrate
python -c 'import ROOT, hydra, omegaconf, uproot, numpy, scipy, iminuit, uap; print("[OK] Python imports")'
```

# Main Analysis
FLOW : rawroot or dat2root, root2csv(charge, timing), csv2plot(charge, timing)

# KOR flow 

## KOR1 : raw2root

### KOR 1.1.1 : 1 file version
```
python3 runners/kor_runner.py \
  --raw-dir /media/precalib/rawdata/kor/commissioning \
  --out-dir outputs/kor-ntp-20261013-000 \
  --files precal_raw_kor_run_20261013_000.root
```

### KOR 1.1.2 : 1 scan(46 points) version 

```
python3 runners/kor_runner.py \
  --raw-dir /media/precalib/rawdata/kor/commissioning \
  --out-dir outputs/kor-ntp-20261013-000-045 \
  --files precal_raw_kor_run_20261013_{000..045}.root
```

### KOR 1.2 : Process Confirmation checking file existence
```
find outputs/kor-ntp-20261013-000-045/outputs \
  -maxdepth 1 -type f -name 'prd_precal_raw_kor_run_20261013_*.root' | wc -l
```

## KOR2 : root2csv

### KOR2.1 : Select the input and output folder
```
PROCESSED_ROOT="$PWD/outputs/kor-ntp-20261013-000/outputs/prd_precal_raw_kor_run_20261013_000.root"
ANALYSIS_OUT="$PWD/outputs/tutorial-$(date +%Y%m%d-%H%M%S)"
```

### KOR2.2 : charge fit
```
python3 main.py root2csv --config-name charge_default \
  --input-dir "$PROCESSED_ROOT" \
  --serial EM5730 \
  hydra.run.dir="$ANALYSIS_OUT/charge-EM5730"
```

### KOR2.3 : timing fit
```
python3 main.py root2csv --config-name kor_root2csv_timing_binned \
  --input-dir "$PROCESSED_ROOT" \
  --serial EM5730 \
  hydra.run.dir="$ANALYSIS_OUT/charge-EM5730"
```

### KOR2.4 : Check the output files
```
find "$ANALYSIS_OUT/charge-EM5730/figures" -type f
find "$ANALYSIS_OUT/timing-EM5730/figures" -type f
```

## KOR3 :  csv2plot
charge and timing plot vs angle

## KOR3.1 : Set the paths to use temporary
```
CHARGE_CSV="$ANALYSIS_OUT/scan-charge-EM5730/csv/kor_charge_results.csv"
TIMING_CSV="$ANALYSIS_OUT/scan-timing-EM5730/csv/kor_results.csv"
```

## KOR3.2 : plot relative gain vs angle
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-gain/figures" \
  --out-name EM5730_relative_gain.png \
  --points-csv EM5730_relative_gain_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'Relative gain' \
  --title 'EM5730: charge fit' \
  --hline 1 \
  --series-json "[
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
     'phi':0, 'y_col':'relative_gain', 'yerr_col':'relative_gain_err',
     'label':'phi = 0 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
     'phi':90, 'y_col':'relative_gain', 'yerr_col':'relative_gain_err',
     'label':'phi = 90 deg', 'line_color':'C1'}
  ]"
```

## KOR3.3 : plot timing vs angle
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-timing/figures" \
  --out-name EM5730_timing_mu.png \
  --points-csv EM5730_timing_mu_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'EMG location mu (ns)' \
  --title 'EM5730: timing fit' \
  --series-json "[
    {'system':'kor', 'csv':'$TIMING_CSV', 'mode':'single_phi',
     'phi':0, 'y_col':'mu', 'yerr_col':'mu_err',
     'label':'phi = 0 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$TIMING_CSV', 'mode':'single_phi',
     'phi':90, 'y_col':'mu', 'yerr_col':'mu_err',
     'label':'phi = 90 deg', 'line_color':'C1'}
  ]"
```

# AUS flow

## AUS1 : dat2root
```
python3 runners/aus_runner-dat.py --raw-dir /media/precalib/rawdata/aus/commissioning/scan_20261023_143138/EM6190-C --template R12860_config_dat.yaml --channels 0,1,3,7 --theta 0 10 20 30 40 50 60 70 80 --phi 0 90 180 270 --Nevent 600000 --out-dir /media/precalib/rawdata/aus/UAP-out/scan_20261023_143138/EM6190-C
```

(full option version)
```
python3 runners/aus_runner-dat.py \
  --raw-dir /media/precalib/rawdata/aus/commissioning/scan_20261023_143138/EM6190-C \
  --template /home/precalib/shiftertool/UAP/hkprecal-uap/R12860_config_dat.yaml \
  --channels 0,1,3,7 \
  --points theta0_phi0 theta10_phi90 \
  --theta 0 10 20 30 40 50 60 70 80 \
  --phi 0 90 180 270 \
  --Nevent 20000 \
  --max-points 10 \
  --out-root-base /home/precalib/shiftertool/UAP/datastorage/aus/root \
  --out-dir /home/precalib/shiftertool/UAP/outputs/custom_run_01 \
```
`Nevent(nevent)` is the number of events to be processed. `theta` and `phi` are the angle value to be processed; all possible combinations of `(theta,phi)` are processed.

## AUS2: root2csv charge
```
python3 main.py root2csv --config-name aus_root2csv_charge_default --input-dir /media/precalib/rawdata/aus/UAP-out/scan_20261023_143138/EM6190-C/outputs --serial EM6190-C pmt_ch=3
```

## AUS3 : root2csv time
```
python3 main.py root2csv --config-name aus_root2csv_emg_default --input-dir /home/precalib/shiftertool/UAP/datastorage/aus/root/scan_20261023_143138/EM6190-C/outputs --serial EM6190-C pmt_ch=3
```

## AUS4 : csv2plot
gain and timing plot vs angle

### AUS4.1 : gain vs angle plot
```
python3 main.py csv2plot --config-name csv2plot_default-aus input_dir=/home/precalib/shiftertool/UAP/hkprecal-uap/outputs/2026-10-29/16-43-58-root2csv-aus-charge/csv
```

### AUS4.2 : time vs angle plot
```
python3 main.py csv2plot --config-name csv2plot_default-aus input_dir=/home/precalib/shiftertool/UAP/hkprecal-uap/outputs/2026-10-29/16-43-58-root2csv-aus-emg/csv
```