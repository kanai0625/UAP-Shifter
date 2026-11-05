# UAP on sukap 
```
/disk03/usr8/kanai062/UAP-Shifter
```

# environment setting before running UAP fixed
## 0.1 : Move to the directory of UAP

```
cd /disk03/usr8/kanai062/UAP-Shifter
source env.sh
```

## 0.2 : Input environment paths and activate the virtual environment (all paths are fixed)
```
export PYRATE_HOME=/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61
export KOR_NTP_HOME=/disk03/usr8/kanai062/UAP-Shifter/kor_ntp
export UAP_ROOT_THISROOT=/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/thisroot.sh
source /disk03/usr8/kanai062/UAP-Shifter/miniforge3/etc/profile.d/conda.sh
conda activate /disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap
```

## 0.3 : Confirmation of the environment
```
command -v python
python --version
root-config --version
command -v pyrate
python -c 'import ROOT, hydra, omegaconf, uproot, numpy, scipy, iminuit, uap; print("[OK] Python imports")'
```

(1 line version) 
```
command -v python python --version root-config --version command -v pyrate python -c 'import ROOT, hydra, omegaconf, uproot, numpy, scipy, iminuit, uap; print("[OK] Python imports")'
```
# Main Analysis
FLOW : rawroot or dat2root, root2csv(charge, timing), csv2plot(charge, timing)

# KOR flow 
raw2root, root2csv(charge, timing) for 2PMTs, csv2plot(charge, timing) for 2PMTs.

## KOR1 : raw2root
Anyway activate the library path.
'''
export LD_LIBRARY_PATH=/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib:/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib/root:$LD_LIBRARY_PATH
'''

### KOR 1.1.1 : Quick 1 file version
Process time : 20 sec/file
```
python3 runners/kor_runner.py \
  --raw-dir /disk03/hk04/precalib/commissioning/kor/caendigi \
  --out-dir /disk03/usr8/kanai062/UAP-Shifter/outputs/kor-ntp-20260928-000 \
  --files precal_raw_kor_run_20260928_000.root
```

### KOR 1.1.2 : 1 scan(46 points) version 
Process time : 20 sec/file * 46 = 15 min 20 sec
```
python3 runners/kor_runner.py \
  --raw-dir /disk03/hk04/precalib/commissioning/kor/caendigi \
  --out-dir /disk03/usr8/kanai062/UAP-Shifter/outputs/kor-ntp-20260928-000-045 \
  --files precal_raw_kor_run_20260928_{000..045}.root
```

### KOR 1.2 : Process Confirmation checking file existence

```
find kor_outputs/kor-ntp-20261013-000-045/outputs \
  -maxdepth 1 -type f -name 'prd_precal_raw_kor_run_20261013_*.root' | wc -l
```

## KOR2 : root2csv

### KOR2.1 : Select the input and output folder
Before Runnning set the data path and output path temporary.

Quick Version : 1 file version 
```
PROCESSED_ROOT="$PWD/outputs/kor-ntp-20260928-000/outputs/prd_precal_raw_kor_run_20260928_000.root"
ANALYSIS_OUT="$PWD/outputs/$(date +%Y%m%d-%H%M%S)"
```

Long Version : 46 files(1 scan) version 
```
PROCESSED_ROOT="$PWD/outputs/kor-ntp-20260928-000-045/outputs"
ANALYSIS_OUT="$PWD/outputs/$(date +%Y%m%d-%H%M%S)"
```

### KOR2.2 : charge fit
Process time : 1 min per 46 root files
"serial" is the main name of PMT1 and 2 e.g. EM6400 in EM6400-H case.
This prompt is common for 1 file and 46 files versions.
```
python3 main.py root2csv --config-name charge_default \
  --input-dir "$PROCESSED_ROOT" \
  --serial EM6400 \
  hydra.run.dir="$ANALYSIS_OUT/charge-EM6400-H"
```

### KOR2.3 : timing fit
Process time : 1 min per 46 root files

```
python3 main.py root2csv --config-name kor_root2csv_timing_binned \
  --input-dir "$PROCESSED_ROOT" \
  --serial EM6400 \
  hydra.run.dir="$ANALYSIS_OUT/timing-EM6400-H"
```

### KOR2.4 : Check the output files
```
find "$ANALYSIS_OUT/charge-EM6400/figures" -type f
find "$ANALYSIS_OUT/timing-EM6400/figures" -type f
```

## KOR3 :  csv2plot
Export relative gain vs angle plot and csv file.

## KOR3.1 : Charge Plot
### KOR3.1.1 : Set the paths to use temporary before executing specific PMT analysis.

Charge EM6400-H
```
ANALYSIS_OUT="$PWD/outputs/20261031-135618"
CHARGE_CSV="$ANALYSIS_OUT/charge-EM6400-H/csv/kor_charge_results.csv"
```

Charge EL7370-A
```
ANALYSIS_OUT="$PWD/outputs/20261031-135618"
CHARGE_CSV="$ANALYSIS_OUT/charge-EL7370-A/csv/kor_charge_results.csv"
```


### KOR 3.1.2 : plot relative gain vs angle
EM6400-H case : phi=45,135
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-gain/figures" \
  --out-name EM6400-H_relative_gain.png \
  --points-csv EM6400-H_relative_gain_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'Relative gain' \
  --title 'EM6400-H: charge fit' \
  --hline 1 \
  --series-json "[
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':45,
      'y_col':'relative_gain', 'yerr_col':'relative_gain_err',
      'label':'phi = 45 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':135,
      'y_col':'relative_gain', 'yerr_col':'relative_gain_err',
      'label':'phi = 135 deg', 'line_color':'C1'}
  ]"
```

EL7370-A case : phi=0,90
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-gain/figures" \
  --out-name EL7370-A_relative_gain.png \
  --points-csv EL7370-A_relative_gain_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'Relative gain' \
  --title 'EL7370-A: charge fit' \
  --hline 1 \
  --series-json "[
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':0,
      'y_col':'relative_gain', 'yerr_col':'relative_gain_err',
      'label':'phi = 0 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':90,
      'y_col':'relative_gain', 'yerr_col':'relative_gain_err',
      'label':'phi = 90 deg', 'line_color':'C1'}
  ]"
```

### KOR3.1.3 plot gain vs angle
EM6400-H case : phi=45,135
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-gain/figures" \
  --out-name EM6400-H_gain.png \
  --points-csv EM6400-H_gain_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'Gain' \
  --title 'EM6400-H: charge fit' \
  --hline 1 \
  --series-json "[
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':45,
      'y_col':'gain', 'yerr_col':'gain_err',
      'label':'phi = 45 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':135,
      'y_col':'gain', 'yerr_col':'gain_err',
      'label':'phi = 135 deg', 'line_color':'C1'}
  ]"
```

EL7370-A case : phi=0,90
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-gain/figures" \
  --out-name EL7370-A_gain.png \
  --points-csv EL7370-A_gain_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'Gain' \
  --title 'EL7370-A: charge fit' \
  --hline 1 \
  --series-json "[
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':0,
      'y_col':'gain', 'yerr_col':'gain_err',
      'label':'phi = 0 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$CHARGE_CSV', 'mode':'single_phi',
      'phi_col':'phi_raw', 'theta_col':'theta_raw', 'phi':90,
      'y_col':'gain', 'yerr_col':'gain_err',
      'label':'phi = 90 deg', 'line_color':'C1'}
  ]"
```



## KOR3.2 : Timing Plot
Export timing vs angle plot and csv. 

### KOR3.2.1 : Set the paths to use temporary before executing specific PMT analysis.
Timing EM6400-H
```
ANALYSIS_OUT="$PWD/outputs/20261031-140318"
TIMING_CSV="$ANALYSIS_OUT/timing-EM6400-H/csv/kor_results.csv"
```

Timing EL7370-A
```
ANALYSIS_OUT="$PWD/outputs/20261031-140318
TIMING_CSV="$ANALYSIS_OUT/timing-EL7370-A/csv/kor_results.csv"
```

### KOR3.2.2 : plot timing vs angle
EM6400-H case : phi=45,135
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-timing/figures" \
  --out-name EM6400-H_timing_mu.png \
  --points-csv EM6400-H_timing_mu_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'EMG location mu (ns)' \
  --title 'EM5730: timing fit' \
  --series-json "[
    {'system':'kor', 'csv':'$TIMING_CSV', 'mode':'single_phi',
     'phi':45, 'y_col':'mu', 'yerr_col':'mu_err',
     'label':'phi = 45 deg', 'line_color':'C0'},
    {'system':'kor', 'csv':'$TIMING_CSV', 'mode':'single_phi',
     'phi':135, 'y_col':'mu', 'yerr_col':'mu_err',
     'label':'phi = 135 deg', 'line_color':'C1'}
  ]"
```

EL7370-A case : phi=0,90
```
python3 main.py csv2plot \
  --out-dir "$ANALYSIS_OUT/plot-timing/figures" \
  --out-name EL7370-AH_timing_mu.png \
  --points-csv EL7370-A_timing_mu_points.csv \
  --x-label 'Raw tilt angle (deg)' \
  --y-label 'EMG location mu (ns)' \
  --title 'EL7370-A: timing fit' \
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
python3 runners/aus_runner-dat.py --raw-dir /disk03/hk04/precalib/commissioning/aus/caendigi/scan_YYYYMMDD_HHMMSS/PMT_label --template R12860_config_dat.yaml --channels 0,1,3,7 --theta 0 10 20 30 40 50 60 70 80 --phi 0 90 180 270 --Nevent 600000 --out-dir /disk03/usr8/kanai0625/UAP-Shifter/aus_outputs/YYYYMMDD_HHMMSS_PMT_label
```

(full option version)
```
python3 runners/aus_runner-dat.py \
  --raw-dir /disk03/hk04/precalib/commissioning/aus/caendigi/scan_20261014_165159/EL7370-A \
  --template R12860_config_dat.yaml \
  --channels 0,1,3,7 \
  --theta 0 10 20 30 40 50 60 70 80 \
  --phi 0 90 180 270 \
  --Nevent 20000 \
  --out-dir /disk03/usr8/kanai062/UAP-Shifter/aus_outputs/scan_20261014_165159_EL7370-A \
  --pyrate-cwd /disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61 \
  --pyrate-cmd $PWD/run_pyrate.sh
```
`Nevent(nevent)` is the number of events to be processed. `theta` and `phi` are the angle value to be processed; all possible combinations of `(theta,phi)` are processed.

## AUS2: root2csv charge
```
python3 main.py root2csv --config-name aus_root2csv_charge_default --input-dir /disk03/usr8/kanai062/UAP-Shifter/aus_outputs/scan_20261014_165159_EL7370-A/outputs --serial EL7370-A pmt_ch=3
```

## AUS3 : root2csv time
```
python3 main.py root2csv --config-name aus_root2csv_emg_default --input-dir /disk03/usr8/kanai062/UAP-Shifter/aus_outputs/scan_20261014_165159_EL7370-A/outputs --serial EL7370-A pmt_ch=3
```

## AUS4 : csv2plot
gain and timing plot vs angle

### AUS4.1 : gain vs angle plot
```
python3 main.py csv2plot --config-name csv2plot_default-aus input_dir=/disk03/usr8/kanai062/UAP-Shifter/outputs/2026-10-30/17-30-03-root2csv-aus-charge/csv
```

### AUS4.2 : time vs angle plot
```
python3 main.py csv2plot --config-name csv2plot_default-aus input_dir=/disk03/usr8/kanai062/UAP-Shifter/outputs/2026-10-30/17-32-34-root2csv-aus/csv
```



## AUS job submission of raw2root
1000 event test. "--elapse" is the maximum run time hh:mm:ss, "--Nevent" is the number of events to be converted.
```
python3 runners/aus_cluster_runner-dat.py \
  --raw-dir /disk03/hk04/precalib/commissioning/aus/caendigi/scan_20261014_165159/EL7370-A \
  --out-dir /disk03/usr8/kanai062/UAP-Shifter/aus_cluster_test \
  --template R12860_config_dat.yaml \
  --queue all \
  --elapse "1:00:00" \
  --Nevent 1000
```

60k events version
```
python3 runners/aus_cluster_runner-dat.py \
  --raw-dir /disk03/hk04/precalib/commissioning/aus/caendigi/scan_20261014_165159/EL7370-A \
  --out-dir /disk03/usr8/kanai062/UAP-Shifter/jobtest-1104 \
  --template R12860_config_dat.yaml \
  --queue hk \
  --elapse "4:00:00" 
```

Job status check
```
pjstat
```
"RST" -> running, "QUE" -> quene, no appearence -> finished

Check the number of root files to be exported
```
ls -1 /disk03/usr8/kanai062/UAP-Shifter/aus_cluster_test/scan_20261014_165159/EL7370-A/outputs/*.root 2>/dev/null | wc -l
```