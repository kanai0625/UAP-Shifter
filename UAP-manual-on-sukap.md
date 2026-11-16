__UAP Manual on sukap 1116ver__
updates from 1106ver : AUS flow without pyrate (aus_raw2root.py, 4-step charge fit, fixed-threshold timing with a late-pulse EMG, new automation).
updates from 1105ver : revising the job submission part and environment.

You can see the latest version on `https://github.com/kanai0625/UAP-Shifter.git` branches
If you want to create your own environment, you may copy environments to your working directory 
e.g.
```
rsync -r /disk03/usr8/kanai062/UAP-Shifter/miniforge3 /your/working/dir
```
```
rsync -r disk03/usr8/kanai062/UAP-Shifter/aus_pyrate /your/pyrate/dir
```
```
rsync -r /disk03/usr8/kanai062/UAP-Shifter/kor_ntp /your/kor_ntp
```

Here you use following commands with changing paths to your counterparts; PMT data path, environment, output, UAP directory, etc.


# UAP on sukap 
```
/disk03/usr8/kanai062/UAP-Shifter
```

# environment setting before running UAP fixed
## 0.1 : Move to the directory of UAP

```
cd /disk03/usr8/kanai062/UAP-Shifter
```

## 0.2 : Input environment paths and activate the virtual environment (all paths are fixed)
```
export PYRATE_HOME=/disk03/usr8/kanai062/UAP-Shifter/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61
export KOR_NTP_HOME=/disk03/usr8/kanai062/UAP-Shifter/kor_ntp
export UAP_ROOT_THISROOT=/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/thisroot.sh
export PYTHONPATH=/disk03/usr8/kanai062/UAP-Shifter/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61:$PYTHONPATH
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
(1116ver: pyrate is no longer used for AUS. Everything runs with the conda environment of 0.2.)

FLOW : raw2root (`runners/aus_raw2root.py`, one job per point) → point analysis (`runners/aus_run_point.sh`: charge fit, timing fit, plots, SiPM) → PMT plots (`runners/aus_merge_plot.py`).
The same commands are used by the automation on the Shifter PC (AUS5).

## AUS0 : definitions
| step | definition |
|---|---|
| baseline | ch0 (laser trigger): mean of the **last 30** samples; other channels: mean of the **first 40** samples. σ = their standard deviation |
| waveform | V [mV] = polarity × (ADC − baseline) × 2000/16384 (DT5730S, 14 bit, 2 Vpp); polarity + for ch0/ch1, − for the PMTs (ch3/5/7) |
| PulseStart (charge) | first sample after the baseline window with V > NSIGMA × σ (NSIGMA = 2.2) |
| charge | Σ V in [PulseStart − 10, PulseStart + 50) × 2 ns / 50 Ω [pC] |
| PulseStart (timing) | second ROOT file (`outputs_vcut<V>mV`): PMT events whose largest pulse is above **V = 2.0 mV**; PulseStart = rising edge (first sample above V going back from the maximum). Trigger and SiPM as above |
| charge fit | 4 steps: 1 pedestal (Gaussian, ±2σ) → 2 SPE start = most populated 0.05 pC bin above pedestal + 3σ; SPE + 2PE (+ pedestal tail) fitted in 1–5 pC with N_2PE/N_SPE = occupancy/2 (occupancy = −ln(N_ped/N)) → 3 pedestal + SPE + 2PE over the whole range with Poisson weights (SPE kept in step-2 mean ± 1 pC, no SPE prior) → 4 + backscatter (SPE free within the step-2 window). Every fit parameter is written in the legend of the figure |
| timing fit | Δt = PulseStart(PMT) − PulseStart(ch0); window = peak of the −520..520 ns histogram (2 ns bins) ± 50 ns (PMT, 100 ns), ± 30 ns (SiPM). PMT: prompt EMG (data in peak −10..+6 ns) → late-pulse EMG (data after the prompt) → linear background → all free (extended unbinned NLL). μ and FWHM of the prompt EMG are marked in the figure |
| results | gain = (μ_SPE − μ_ped)/e (`gain_pedestal_subtracted`); arrival time = μ of the prompt EMG; TTS = FWHM of the prompt EMG (`FWHM_signal`); relative QE = (N_prompt / N_SiPM) relative to θ=0, φ=0; late fraction = N_late / (N_prompt + N_late) |

## AUS1 : one point, everything (quick check)
raw2root + charge + timing + plots + SiPM plots of one point (no job):
```
runners/aus_run_point.sh \
  -raw /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B \
  -point theta0_phi0 -nevent 300000
```
Output: `aus_point_outputs/scan_20261108_135057_EM5370-B_theta0_phi0_n300000/`
```
root/ root_vcut2.0mV/   ROOT files (main / fixed 2.0 mV PMT threshold)
charge/                 csv/aus_charge_results.csv, figures/*_log.png (step 4), *_step2_spe_log.png (step 3)
time/                   csv/aus_results.csv, figures/theta0_phi0.png (PMT), sipm_theta0_phi0.png
plots/                  pulsestart_chN.png, delta_t.png, charge_peakheight.png, summary.txt
sipm/                   sipm_waveforms_grid/overlay.png (100 waveforms), sipm_wfdist_10pct/100pct/vthr100mV.png
logs/                   raw2root.log, charge.log ([STEP1..4]), time.log ([STEP1..4]), ...
```
Main options (all: `runners/aus_run_point.sh -h`)

| option | meaning | default |
|---|---|---|
| `-nevent N` | events of raw2root (0 = all) | 300000 |
| `-nsigma S` | PulseStart threshold for the charge [σ] | 2.2 |
| `-vcut V` / `-vcut-edge max\|first` | fixed PMT threshold [mV] for the timing / rising edge of the largest pulse or first crossing | 2.0 / max |
| `-twin T` / `-sipm-twin T` | timing window width [ns] PMT / SiPM | 100 / 60 |
| `-prompt-range L,H` | timing step 1: prompt EMG fitted in peak+L..peak+H ns | -10,6 |
| `-no-late` (`-tbkg const\|linear\|none`) | timing without the late-pulse EMG | – |
| `-spe-range L,H` / `-spe-gap N` / `-spe-min Q` | charge step 2: SPE + 2PE fit range [pC] / SPE start above pedestal + Nσ / or above Q pC | 1,5 / 3 / – |
| `-spe-hw W` / `-spe-bound N` | charge: step 2/3 SPE in start / step-2 mean ± W pC / step 4 SPE = step 3 ± N × error (0 = free in the step-2 window) | 1.0 / 0 |
| `-pe2-free` | charge: 2PE yield free (default: Poisson, N_2PE/N_SPE = occupancy/2) | – |
| `-set KEY=VALUE` | charge config override, e.g. `-set charge_fit_range=[-1,8]` | – |
| `-root F -vroot F` | use existing ROOT files (e.g. of a job) → no raw2root | – |
| `-out DIR` | output directory | see above |
| `-skip-sipm`, `-wf-nevent N`, `-vthr V` | SiPM plots off / events of the distributions (0 = all) / threshold of the 3rd distribution [mV] | – / 0 / 100 |

## AUS2 : raw2root job submission (one job per point, hk queue)
PMT channel 3 (wave0,1,3,7):
```
python3 runners/aus_cluster_runner-raw2root-hk.py \
  --raw-dir /disk03/hk04/precalib/production/aus/caendigi/scan_YYYYMMDD_HHMMSS/PMT_label \
  --out-dir /disk03/hk04/precalib/production/aus/processed/scan_YYYYMMDD_HHMMSS/PMT_label \
  --channels 0,1,3,7 --queue hk --Nevent 300000 --nsigma 2.2 --vcut-mv 2.0 --elapse 1:00:00
```
PMT channel 5 (wave0,1,5,7): `--channels 0,1,5,7`.
Only some points: `--points theta0_phi0 theta10_phi90`, or `--theta 0 10 --phi 0 90`. Test without submitting: `--dry-run`.

One line per point is printed:
```
[OK]   theta0_phi0 -> [INFO] PJM 0000 pjsub Job 198813375 submitted.
```
Output (`--out-dir`):
```
outputs/output_thetaX_phiY.root              main ROOT file (charge)
outputs_vcut2.0mV/output_thetaX_phiY.root    fixed-threshold ROOT file (timing)
configs/thetaX_phiY_raw2root.yaml            channels, pmt_ch, nevent, ... of the point
jobs/job_thetaX_phiY.sh   logs/thetaX_phiY.log   scheduler/thetaX_phiY.out/.err
```
Job status: `pjstat` ("RST" running, "QUE" queued, not shown = finished).
Number of finished points:
```
ls -1 /disk03/hk04/precalib/production/aus/processed/scan_YYYYMMDD_HHMMSS/PMT_label/outputs/*.root | wc -l
```

## AUS3 : point analysis from the job outputs
```
P=/disk03/hk04/precalib/production/aus/processed/scan_YYYYMMDD_HHMMSS/PMT_label
R=/disk03/hk04/precalib/production/aus/caendigi/scan_YYYYMMDD_HHMMSS/PMT_label
pt=theta0_phi0
runners/aus_run_point.sh -raw $R -point $pt -pmt-ch 5 \
  -root $P/outputs/output_$pt.root -vroot $P/outputs_vcut2.0mV/output_$pt.root \
  -out $P/$pt -wf-out $P/waveformdist -wf-prefix ${pt}_
```
All points of a PMT (one after the other):
```
for f in $P/outputs/output_theta*_phi*.root; do
  pt=$(basename $f .root); pt=${pt#output_}
  runners/aus_run_point.sh -raw $R -point $pt -pmt-ch 5 -root $f -vroot $P/outputs_vcut2.0mV/output_$pt.root \
    -out $P/$pt -wf-out $P/waveformdist -wf-prefix ${pt}_ > $P/$pt.log 2>&1
done
```
Single steps (normally not needed; `runners/aus_run_point.sh` calls them):
```
python3 runners/aus_root2csv.py --kind charge --root <main ROOT file> --serial PMT_label --pmt-ch 5 --out <dir>/charge
python3 runners/aus_root2csv.py --kind timing --root <vcut ROOT file> --serial PMT_label --pmt-ch 5 --pmt-twin 100 --out <dir>/time
python3 runners/aus_point_plots.py --out <dir>/plots --root <main> --vroot <vcut> --pmt-ch 5 \
  --charge-csv <dir>/charge/csv/aus_charge_results.csv --timing-csv <dir>/time/csv/aus_results.csv
python3 runners/aus_sipm_waveforms.py --input-dir $R/wavesave_$pt --out-dir <dir>/sipm
python3 runners/aus_sipm_wfdist.py    --input-dir $R/wavesave_$pt --out-dir <dir>/sipm
```

## AUS4 : csv2plot (whole PMT)
Merges `$P/thetaX_phiY/{charge,time}/csv/*.csv`, recomputes the values relative to θ=0, φ=0 and plots them vs θ (one line per φ):

```
python3 runners/aus_merge_plot.py $P PMT_label
```
| file | content |
|---|---|
| `$P/charge/aus_charge_results.csv`, `gain_<PMT>.png`, `relative_gain_<PMT>.png` | gain (pedestal subtracted), relative gain |
| `$P/time/aus_results.csv`, `relative_QE_<PMT>.png` | relative QE (SiPM normalised) |
| `$P/time/arrival_time_<PMT>.png`, `TTS_<PMT>.png`, `late_fraction_<PMT>.png` | arrival time (μ), TTS (FWHM of the prompt EMG), late-pulse fraction |

## AUS5 : automation on the Shifter PC
Run on the Shifter PC (precalib@10.200.102.69) in this order, each in its own terminal (commands: `status | log | quit | help`):
```
./1112-AUSbackup.sh          # AUS DAQ -> Shifter -> sukap, every 5 min
./1113-AUSjobsubmission.sh   # AUS2 for every new point (hk queue, max 100 jobs), every 5 min
./1113-AUSUAP-auto.sh        # AUS3 + AUS4 + web copy, every 5 min
```
* `1113-AUSjobsubmission.sh` : `-date YYYYMMDD` (points written on/after that day), `-elec caendigi|hkelec`, `-dry`.
  Env: `NEVENT` (300000), `NSIGMA` (2.2), `VCUT` (2.0), `ELAPSE` (1:00:00), `MAX_ACTIVE` (100).
  Submitted points: `~/precal_transfer_logs/AUSjobs_raw2root_submitted.list` (new name: points of the pyrate era are submitted again).
* `1113-AUSUAP-auto.sh` : `-date YYYYMMDD`, `-replot`, `-publish`.
  Env: `VCUT` (2.0, same as the jobs), `POINT_OPTS` (extra options of `aus_run_point.sh`, default `-twin 100`).
  Analysed points: `~/precal_transfer_logs/AUSana_raw2root_done.list`.
* Web (`/home/hkpd/public_html/precalib/aus_daily_check/scan_.../<PMT>/`):
  `charge/` (charge fits + gain, relative gain), `timing/` (timing fits + relative QE, arrival time, TTS, late fraction),
  `waveformdist/` (waveform 2D plots of every channel + `thetaX_phiY_sipm_*.png`), `plots/` (`thetaX_phiY_delta_t.png`, ...).

## AUS6 : files of the AUS flow (UAP-Shifter 1116)
| file | role |
|---|---|
| `runners/aus_raw2root.py` | WaveDump .dat → ROOT (main + fixed-threshold file) |
| `runners/aus_cluster_runner-raw2root-hk.py` | raw2root jobs (pjsub, hk queue) |
| `runners/aus_run_point.sh` | analysis of one point (calls the scripts below) |
| `runners/aus_root2csv.py` | UAP root2csv engine + the AUS charge / timing fits |
| `uap/fit/aus_charge_steps.py`, `aus_timing_late.py`, `aus_plot_style.py` | 4-step charge fit, late-pulse timing fit, figures |
| `runners/aus_point_plots.py`, `aus_sipm_waveforms.py`, `aus_sipm_wfdist.py` | point plots, SiPM plots |
| `runners/aus_merge_plot.py` | whole-PMT CSVs and plots |
| `runners/1113-AUSjobsubmission.sh`, `runners/1113-AUSUAP-auto.sh` | automation (Shifter PC) |

The previous pyrate-based commands (`runners/aus_runner-dat.py`, `runners/aus_cluster_runner-dat-hk.py`, `R12860_config_dat*.yaml`) are kept but no longer used by the automation.
