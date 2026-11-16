# HKPrecal UAP  (branch 1116)

HKPrecal UAP is the unified analysis pipeline for the PMT pre-calibration (AUS and KOR stands).

The workflow is:
1. `raw -> root`  waveform processing
   - AUS: `runners/aus_raw2root.py` (WaveDump `.dat`, **no pyrate** since 1116)
   - KOR: KOR NTP macros (`runners/kor_*runner*.py`)
2. `root -> csv`  charge (gain) and timing fits per angle point (`uap/`)
3. `csv -> plot`  values vs angle

On sukap the repository lives in `/disk03/usr8/kanai062/UAP-Shifter` (default branch on GitHub: `1116`).
Step-by-step commands: `UAP-manual-on-sukap.md` / `.pdf`.

## What is new in 1116 (AUS)

| step | 1107 (pyrate) | 1116 |
|---|---|---|
| raw → root | pyrate + `R12860_config_dat*.yaml` | `runners/aus_raw2root.py`: ch0 pedestal = last 30 samples, others first 40; PulseStart = first sample > 2.2 σ; charge = Σ(V − baseline) in [PS − 10, PS + 50) × 2 ns / 50 Ω (DT5730S); second ROOT file with a fixed PMT threshold (2.0 mV, rising edge of the largest pulse) for the timing |
| jobs | `aus_cluster_runner-dat-hk.py` | `aus_cluster_runner-raw2root-hk.py` (same options and output lines) |
| charge fit | one step | 4 steps: pedestal → SPE start (most populated 0.05 pC bin above pedestal + 3σ), SPE + 2PE fitted in 1–5 pC → pedestal + SPE + 2PE → + backscatter (SPE free within the step-2 window); 2PE/SPE fixed by Poisson statistics (occupancy from the pedestal fraction); every parameter in the figure legend |
| timing fit | EMG + linear background, 2.2 σ PulseStart | fixed-threshold PulseStart, PMT window 100 ns: prompt EMG → late-pulse EMG → linear background → all free (unbinned); μ and FWHM marked in the figure |
| per point | `main.py root2csv` (charge, time) | `runners/aus_run_point.sh` (charge, timing, plots, SiPM waveforms / distributions) |
| whole PMT | csv2plot | `runners/aus_merge_plot.py`: gain (pedestal subtracted), relative gain, relative QE (SiPM normalised), arrival time, TTS (FWHM of the prompt EMG), late-pulse fraction |

The AUS fit code (`uap/fit/aus_*.py`) is installed on top of the UAP fitters at run time;
the UAP modules themselves (`charge_spectrum_fit.py`, `emg_timing_offset_fit.py`, ...) are unchanged, so KOR is not affected.
The pyrate-based AUS runners are kept (legacy) but not used by the automation.

## Project Structure

```text
UAP-Shifter/
  main.py                      Hydra entry (root2csv / csv2plot), used for KOR and the legacy AUS flow
  env.sh  install_hkprecal_env.sh  requirements.txt
  UAP-manual-on-sukap.md/.pdf  step-by-step manual (KOR + AUS)
  config/
    aus_root2csv_charge_default.yaml   aus_root2csv_emg_default.yaml      (AUS fit settings)
    kor_root2csv_*.yaml  charge_default.yaml  timing_default.yaml  csv2plot_default*.yaml
  runners/
    aus_raw2root.py                    AUS  .dat -> ROOT
    aus_cluster_runner-raw2root-hk.py  AUS  raw2root jobs (pjsub, hk queue)
    aus_run_point.sh                   AUS  analysis of one point (calls the scripts below)
    aus_root2csv.py                    AUS  UAP root2csv engine + AUS charge / timing fits
    aus_point_plots.py                 AUS  PulseStart / delta t / charge / PeakHeight of one point
    aus_sipm_waveforms.py  aus_sipm_wfdist.py   AUS  SiPM waveforms (100) / waveform distributions
    aus_merge_plot.py                  AUS  whole-PMT CSVs and plots vs angle
    AUSwaveform-2Dplot.py              AUS  waveform 2D plots of every channel
    1112-AUSbackup.sh  1113-AUSjobsubmission.sh  1113-AUSUAP-auto.sh   automation (run on the Shifter PC)
    kor_*runner*.py                    KOR  raw -> root
    aus_runner*.py  aus_cluster_runner*.py (except raw2root)   AUS legacy (pyrate)
  uap/
    engine/      root2csv.py  csv2plot.py
    fit/         fitter_interface.py  charge_spectrum_fit.py  emg_timing_offset_fit.py
                 kor_relative_qe_fit.py  fit_config.py  common_math.py  plot_utils.py
                 aus_charge_steps.py  aus_timing_late.py  aus_plot_style.py     (AUS, 1116)
    scan_reader/ aus_reader.py  kor_reader.py
    tool/        root_io.py  scan_prepare.py  window.py  draw.py
```

## Architecture (uap/)

### 1) `uap.engine`: pipeline entry
- `root2csv.py`: builds the fitter, resolves the output layout (`csv/` + `figures/`), runs the fits, writes logs / CSV
- `csv2plot.py`: loads line configs, builds each line from CSV + angle selection rule, produces one figure (+ selected points CSV)

### 2) `uap.fit`: fit pipeline + methods
- `fitter_interface.py`: common scan workflow (`BaseScanFitter`), point format, fit loop, status logging, CSV writing
- `charge_spectrum_fit.py`: charge spectrum (pedestal, SPE, 2PE, backscatter), gain, resolution, P/V
- `emg_timing_offset_fit.py`: EMG timing fit (+ linear background), AUS SiPM auxiliary fit, relative quantities
- `common_math.py`: extended unbinned NLL, iminuit wrapper, errors, fit quality
- AUS (1116):
  - `aus_charge_steps.py`: 4-step charge fit (and the previous 3-step version)
  - `aus_timing_late.py`: PMT timing = prompt EMG + late-pulse EMG + linear background, fitted in this order, then all free
  - `aus_plot_style.py`: charge figure with every fit parameter in the legend; timing figure with data per 2 ns sample,
    continuous model, μ / FWHM marked; timing background options (linear / const / none)

### 3) `uap.scan_reader`: data-source parsing
- `aus_reader.py`: `output_theta*_phi*.root`, AUS branches and channel resolution
- `kor_reader.py`: KOR serial / angle from the `prd_*.root` file name, branch helpers, channel mapping

### 4) `uap.tool`: shared utilities
- `root_io.py` ROOT branch readers, `window.py` window selection, `scan_prepare.py` point / row builders,
  `draw.py` CSV point selection + plotting + Hamamatsu angle transform

## Data File Structures

### AUS System

#### Raw files: `scan_YYYYMMDD_HHMMSS/<PMT>/wavesave_theta{θ}_phi{φ}/wave{N}.dat`

CAEN DT5730S (14 bit, 2 Vpp, 500 MS/s), WaveDump binary, one file per channel and angle point.
Each event = 24-byte header (6 × uint32, the first word = event size in bytes) + 260 × uint16 ADC samples (520 ns).

| channel | role | polarity |
|---|---|---|
| ch0 | laser trigger | + |
| ch1 | SiPM (normalisation) | + |
| ch3 or ch5 | PMT under test (`wave0,1,3,7` or `wave0,1,5,7`) | − |
| ch7 | (recorded, not analysed) | − |

#### Processed ROOT files (`runners/aus_raw2root.py`)

`outputs/output_theta{θ}_phi{φ}.root` (main) and `outputs_vcut{V}mV/output_theta{θ}_phi{φ}.root`
(PMT trees with the fixed threshold V, other trees identical). One TTree `Tree_CH{N}` per channel, one entry per event:

| Branch | Unit | Description |
|---|---|---|
| `PulseStart` | samples (× 2 ns) | first sample above the threshold (NaN: none); vcut file: rising edge of the largest pulse above V |
| `PulseStartInterp` | samples | the same crossing, linearly interpolated between samples |
| `PeakHeight`, `PeakLocation` | mV, samples | maximum of the baseline-subtracted waveform in [PS − 10, PS + 50) |
| `PulseCharge` | pC | Σ V in [PS − 10, PS + 50) × 2 ns / 50 Ω |
| `Baseline`, `BaselineMV`, `BaselineStdDev` | ADC, mV, mV | pedestal mean / σ (ch0: last 30 samples, others: first 40) |
| `Threshold` | mV | threshold above the baseline (NSIGMA × σ, or V) |
| `WindowStart`, `WindowStop` | samples | charge / peak window |

Timing observable: `Δt = (PulseStart(PMT) − PulseStart(ch0)) × 2 ns`, SiPM likewise.

#### Analysis output (`runners/aus_run_point.sh`, automation: `processed/scan_.../<PMT>/`)

```text
<PMT>/thetaX_phiY/charge/   csv/aus_charge_results.csv, figures/ (final fit, step-3 fit)
<PMT>/thetaX_phiY/time/     csv/aus_results.csv (incl. late_* , FWHM_signal), figures/ (PMT, SiPM)
<PMT>/thetaX_phiY/plots/    pulsestart_chN.png, delta_t.png, charge_peakheight.png, summary.txt
<PMT>/waveformdist/         thetaX_phiY_chN.png, thetaX_phiY_sipm_*.png
<PMT>/charge/  <PMT>/time/  merged CSVs and plots vs angle
```

---

### KOR System

#### Raw files: `{serials}_{date}.root` (no `prd_` prefix)

Produced directly by the digitizer DAQ. One file per angle point, containing all three PMTs. Single TTree `T` with 200,000 events:

| Branch | dtype | Shape | Description |
|--------|-------|-------|-------------|
| `ADC` | uint32 | **(200000, 8, 1024)** | Raw waveforms: events × 8 channels × 1024 samples. Baseline ≈ 15000 ADC counts. |
| `EventNumber` | uint32 | (200000,) | Sequential event index |
| `TriggerTimeTag` | uint32 | (200000,) | Hardware trigger timestamp |
| `RecordLength` | uint32 | fixed = 1024 | Samples per waveform |
| `PostTrigger` | uint32 | fixed = 60 | Samples retained after trigger |
| `OffsetValue0–3` | uint32 | fixed = 7050 | DC offset per channel group |
| `TriggerValue` | uint32 | fixed = 4095 | Trigger threshold |
| `ActiveChannels76543210` | object | (200000,) | Bitmask of active channels per event |

#### Processed ROOT files: `prd_{serials}_{date}.root` (with `prd_` prefix)

Produced by KOR NTP macros from the raw files. One file per angle point, containing all three PMTs. Contains four TTrees and pre-built summary histograms:

TTrees (one per digitizer channel):

| Tree | Role | `diff` mean |
|------|------|-------------|
| `tree_ch0` | PMT #1 | ≈ 11 samples (≈ 22 ns) |
| `tree_ch1` | PMT #2 | ≈ 15 samples (≈ 30 ns) |
| `tree_ch2` | (unpopulated in standard runs) | ≈ 21 samples |
| `tree_ch3` | PMT #3 / trigger reference | ≈ 421 samples (≈ 842 ns) |

Branches (same layout on all four trees):

| Branch | dtype | Description |
|--------|-------|-------------|
| `diff` | float64 | Timing difference relative to trigger (samples). Multiply by 2 ns/sample. |
| `falltime` | float64 | Waveform falling-edge time (samples) |
| `max` | float64 | Waveform peak amplitude |
| `max_time` | int32 | Sample index of the peak (typically ≈ 616) |
| `LiveTime` | float64 | Acquisition live time (ms, 0–200) |
| `pico` | float64 | Picoammeter current reading |

Non-tree summary objects (per channel, `{n}` = 0, 1, 2, 3):

| Object | Type | Description |
|--------|------|-------------|
| `NoiseCount_ch{n}` | TParameter\<long\> | Dark noise event count |
| `NoiseCountRate_ch{n}` | TParameter\<double\> | Dark noise rate (Hz) |
| `Ped_ch{n}` | TH1D | Pedestal charge histogram |
| `Max_ch{n}` | TH1D | Peak amplitude histogram |
| `Time_ch{n}` | TH1D | Timing histogram |
| `Diff_ch{n}` | TH1D | `diff` histogram |
| `Pico_ch{n}` | TH1D | Picoammeter histogram |
| `PicoAbove_ch{n}` | TH1D | Above-threshold picoammeter histogram |

The analysis reads `diff` from `tree_ch{n}`:
```
timing (ns) = tree_ch{n}.diff × 2 ns/sample
```

Channel assignment is derived from the PMT serial order in the filename. The three PMTs map to channels `[0, 1, 3]` by default (channel 2 is skipped). `ch3` exhibits a noise count rate ~500× higher than `ch0`/`ch1`, suggesting it may serve as the laser trigger reference in some configurations.

---

## Quick Start (sukap)

### 1) Environment
```bash
cd /disk03/usr8/kanai062/UAP-Shifter
source miniforge3/etc/profile.d/conda.sh
conda activate /disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap
export UAP_HOME=$PWD PYTHONPATH=$PWD:$PYTHONPATH
```
(new installation: `bash install_hkprecal_env.sh; source env.sh`)

### 2) AUS
One point, everything (raw2root + charge + timing + plots + SiPM):
```bash
runners/aus_run_point.sh -raw /disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B \
                         -point theta0_phi0 -nevent 300000          # options: runners/aus_run_point.sh -h
```
Whole PMT: raw2root jobs, then every point, then the plots vs angle:
```bash
P=/disk03/hk04/precalib/production/aus/processed/scan_20261108_135057/EM5370-B
R=/disk03/hk04/precalib/production/aus/caendigi/scan_20261108_135057/EM5370-B
python3 runners/aus_cluster_runner-raw2root-hk.py --raw-dir $R --out-dir $P --channels 0,1,5,7 \
        --queue hk --Nevent 300000 --nsigma 2.2 --vcut-mv 2.0 --elapse 1:00:00
# after the jobs (pjstat):
for f in $P/outputs/output_theta*_phi*.root; do
  pt=$(basename $f .root); pt=${pt#output_}
  runners/aus_run_point.sh -raw $R -point $pt -pmt-ch 5 -root $f -vroot $P/outputs_vcut2.0mV/output_$pt.root \
      -out $P/$pt -wf-out $P/waveformdist -wf-prefix ${pt}_ > $P/$pt.log 2>&1
done
python3 runners/aus_merge_plot.py $P EM5370-B
```

### 3) KOR: raw -> ROOT (runners/)
```bash
python3 runners/kor_cluster_runner.py --raw-dir /path/to/kor/raw --out-dir /path/to/kor/root --max-active-jobs 100
```

### 4) KOR: ROOT -> CSV (Hydra mode)
```bash
python3 main.py root2csv --config-name kor_root2csv_emg_default
```

To fit one KOR processed ROOT file directly:

```bash
python main.py root2csv --config-name charge_default \
  --input-dir /absolute/path/precal_prd_kor_run_20260815_011.root --serial EM6400
```

`--input-dir` accepts a file or a directory; no copy or symlink is needed.
Relative paths supplied with this flag are resolved from the directory where the
command starts, before Hydra changes directories. Directory inputs should contain
one scan, not repeated angles at different HVs. `--serial` selects the PMT; it may
be omitted if the selected YAML already specifies the correct serial.

The existing defaults save CSV, fit figures, `main.log` and `.hydra/config.yaml`
under `${UAP_HOME:-.}/outputs/<date>/<time>-root2csv-<system>/` (some profiles add
`-charge`). No output-directory argument is needed. Existing `input_dir=...`,
`serial=...` and other Hydra overrides remain supported; the explicit flags take
precedence if both forms are supplied. Single-point results do not establish an
angular dependence or an independently normalized relative QE.

The new `charge_default` and `timing_default` profiles compose four independent
sections: `fit.model`, `fit.constraints`, `fit.statistic`, `fit.optimizer`.
For example, append `fit.constraints.weights=free` to release the Poisson weights,
or `fit.model.backscatter=false` to remove backscatter without changing the
statistic. `system` only selects the reader. Each run also saves the complete
`fit_config.yaml` (definitions, parameter names, limits).

### 5) KOR: CSV -> Plot (Hydra mode)
```bash
python3 main.py csv2plot --config-name csv2plot_default
```

## Automation (AUS)

The three scripts run on the **Shifter PC** (precalib@10.200.102.69) as stand-alone copies of
`runners/1112-AUSbackup.sh`, `runners/1113-AUSjobsubmission.sh`, `runners/1113-AUSUAP-auto.sh`
(UAP-Shifter is not cloned on the Shifter PC). They log in to sukap as `hkpd` and use the UAP-Shifter of
`/disk03/usr8/kanai062/UAP-Shifter` there (must be on branch 1116 and readable by hkpd):

```text
1112-AUSbackup.sh         AUS DAQ -> Shifter -> sukap (MD5 checked), every 5 min
1113-AUSjobsubmission.sh  aus_cluster_runner-raw2root-hk.py for every new point (hk queue, max 100 jobs)
1113-AUSUAP-auto.sh       aus_run_point.sh for every finished job, aus_merge_plot.py per PMT,
                          AUSwaveform-2Dplot.py, PNG copies to /home/hkpd/public_html/precalib/aus_daily_check/
```
Commands while running: `status | log | quit | help`. When a script in `runners/` changes, copy it to the Shifter PC again.
