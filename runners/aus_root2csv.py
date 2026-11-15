#!/usr/bin/env python3
"""
AUS root2csv (no hydra): runs UAP's root2csv engine with a config from UAP-Shifter/config
plus overrides, with the stepped charge fit / late-pulse timing fit / figure changes of
uap/fit/aus_charge_steps.py, aus_timing_late.py, aus_plot_style.py.

Four-step charge fit (default for --kind charge; --no-ped-prefit = original one-step fit)
  1. pedestal: Gaussian fitted (unbinned ML, truncated to the window) to the charges within
     pedestal peak +- PED_WINDOW * sigma  (window re-centred twice)
  2. SPE seed: histogram of the charges >= SPE_SEARCH_MIN (1 pC, bins SPE_BIN = 0.05 pC);
     the bin with the most events = SPE start value; SPE Gaussian fitted (truncated ML) to the
     charges within  start +- SPE_HALFWIDTH (1 pC)  (lower edge at least pedestal + 3 sigma, --spe-ped-gap)
  3. pedestal + SPE + 2PE (no backscatter): start values = steps 1/2,
     pedestal mean/sigma bounded to step 1 +- PED_BOUND * (fit error),
     SPE mean bounded to  start +- SPE_HALFWIDTH,  SPE sigma to 0.25 .. 2 x step-2 sigma,
     the SPE priors of the config (spe_mu_prior / spe_sigma_prior) are not used (--keep-spe-prior)
  4. + backscatter: pedestal mean/sigma bounded to step 3 +- PED_BOUND (2) x error,
     SPE mean/sigma to step 3 +- SPE_BOUND (10) x error
  CSV: final (step 4) result + ped_prefit_* (1) + spe_seed_* (2) + step2_* (3).
  Figures: ..._log.png (step 4) and ..._step2_spe_log.png (step 3).

Timing (--kind timing): fit window = histogram peak of delta t
  (search -520 .. +520 ns, 2 ns bins = 520 bins)  PMT +- 50 ns (100 ns window, --pmt-twin),
  SiPM +- 30 ns (60 ns window, --sipm-twin)
  PMT (uap/fit/aus_timing_late.py, --no-late = one EMG + --tbkg background):
    1 prompt EMG in peak -10 .. +6 ns (--prompt-range)  2 late-pulse EMG after the prompt (prompt fixed)
    3 linear background (EMGs fixed)  4 everything free;  extended unbinned NLL
  SiPM: UAP EMG + linear background (--tbkg-sipm)
  Figures (uap/fit/aus_plot_style.py): data per 2 ns sample, continuous model, mu / FWHM of the prompt EMG

Examples
  python3 runners/aus_root2csv.py --kind charge --root out/root/output_theta0_phi0.root \
      --pmt-ch 5 --serial EM5370-B --out out/charge
  python3 runners/aus_root2csv.py --kind timing --root out/root/output_theta0_phi0.root \
      --pmt-ch 5 --serial EM5370-B --out out/timing
  extra config overrides:  --set charge_fit_range=[-1,6] --set npe=2
"""

import argparse
import logging
import os
import sys
from argparse import Namespace
from pathlib import Path

import numpy as np
import yaml

UAP_DIR = Path(os.environ.get("UAP_HOME") or Path(__file__).resolve().parents[1]).resolve()   # UAP-Shifter
sys.path.insert(0, str(UAP_DIR))

TIMING_DEFAULTS = {        # window around the peak of the -520..520 ns histogram (2 ns bins)
    "tmin": -520.0, "tmax": 520.0, "window_half_width": 50.0, "window_bin_width": 2.0,   # PMT: 100 ns
    "sipm_tmin": -520.0, "sipm_tmax": 520.0, "sipm_window_half_width": 30.0, "sipm_window_bin_width": 2.0,  # SiPM: 60 ns
    "plot_nbins": 30,
}


# ----------------------------------------------------------------------------- pedestal pre-fit


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kind", choices=["charge", "timing"], required=True)
    ap.add_argument("--root", required=True, help="ROOT file (or directory of output_theta*_phi*.root)")
    ap.add_argument("--out", required=True, help="output directory (csv/, figures/, main.log)")
    ap.add_argument("--serial", default="PMT")
    ap.add_argument("--pmt-ch", default="auto")
    ap.add_argument("--config", default=None, help="UAP config name (default: aus_root2csv_<kind>_default)")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE", help="config override (YAML value)")
    ap.add_argument("--no-ped-prefit", action="store_true", help="charge: original one-step UAP fit")
    ap.add_argument("--ped-window", type=float, default=2.0, help="step 1 window: peak +- N sigma")
    ap.add_argument("--spe-bound", type=float, default=None,
                    help="last step SPE bounds: previous best +- N x fit error (default 10; --three-step: = --ped-bound; "
                         "0 = only the step-2 window)")
    ap.add_argument("--ped-bound", type=float, default=2.0, help="steps 3/4 bounds: previous best +- N x fit error")
    ap.add_argument("--spe-search-min", type=float, default=1.0, help="step 2: SPE start = max bin above this [pC]")
    ap.add_argument("--spe-halfwidth", type=float, default=1.0, help="step 2/3: SPE fit window start +- N [pC]")
    ap.add_argument("--spe-bin", type=float, default=0.05, help="step 2: histogram bin width [pC]")
    ap.add_argument("--spe-ped-gap", type=float, default=3.0,
                    help="step 2/3: SPE window starts at least at pedestal + N sigma (0 = off)")
    ap.add_argument("--keep-spe-prior", action="store_true", help="keep spe_mu_prior/spe_sigma_prior of the config")
    ap.add_argument("--three-step", action="store_true", help="previous 3-step fit (no SPE seed step)")
    ap.add_argument("--pmt-twin", type=float, default=100.0, help="timing: PMT window width [ns] (default 100)")
    ap.add_argument("--sipm-twin", type=float, default=60.0, help="timing: SiPM window width [ns] (default 60)")
    ap.add_argument("--uap-plots", action="store_true", help="original UAP figures (no aus_plot_style changes)")
    ap.add_argument("--tbkg", default="const", choices=["linear", "const", "none"],
                    help="timing: PMT background shape (linear = UAP default, const = flat, none)")
    ap.add_argument("--tbkg-sipm", default="linear", choices=["linear", "const", "none"],
                    help="timing: SiPM background shape (default linear = unchanged)")
    ap.add_argument("--no-late", action="store_true",
                    help="timing: PMT fit without the late-pulse EMG (one EMG + --tbkg background)")
    ap.add_argument("--prompt-range", default="-10,6",
                    help="timing step 1: prompt EMG fitted to data in peak + LO .. peak + HI ns (default -10,6)")
    a = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="[%(asctime)s][%(name)s][%(levelname)s] %(message)s")
    name = a.config or ("aus_root2csv_charge_default" if a.kind == "charge" else "aus_root2csv_emg_default")
    cfg = yaml.safe_load((UAP_DIR / "config" / (name + ".yaml")).read_text())
    cfg.pop("hydra", None)
    cfg.pop("defaults", None)
    if a.kind == "timing":
        cfg.update(TIMING_DEFAULTS)
        cfg.update(window_half_width=0.5 * a.pmt_twin, sipm_window_half_width=0.5 * a.sipm_twin,
                   plot_nbins=max(10, int(round(a.pmt_twin / 2.0))))   # 2 ns bins (= 1 sample) in the figure
    for item in a.set:
        k, v = item.split("=", 1)
        cfg[k.strip()] = yaml.safe_load(v)
    out = Path(a.out).resolve()
    csv_name = "aus_charge_results.csv" if a.kind == "charge" else "aus_results.csv"
    cfg.update(input_dir=str(Path(a.root).resolve()), serial=a.serial, pmt_ch=a.pmt_ch,
               out_csv=str(out / "csv" / csv_name), fig_dir=str(out / "figures"), out_base="")
    (out / "csv").mkdir(parents=True, exist_ok=True)
    (out / "used_config.yaml").write_text(yaml.safe_dump(cfg, sort_keys=False))

    if a.kind == "charge" and not a.no_ped_prefit:
        from uap.fit.aus_charge_steps import install_steps, install_two_step
        if a.three_step:
            install_two_step(a.ped_window, a.ped_bound, a.spe_bound)
        else:
            install_steps(a.ped_window, a.ped_bound, a.spe_bound, a.spe_search_min, a.spe_halfwidth,
                          a.spe_bin, a.keep_spe_prior, a.spe_ped_gap)
    from uap.fit import aus_plot_style
    if a.kind == "timing":
        aus_plot_style.install_timing_bkg(a.tbkg, a.tbkg_sipm)
        if not a.no_late:                         # PMT: prompt EMG -> late EMG -> linear bkg -> all free
            from uap.fit import aus_timing_late
            lo, hi = (float(v) for v in a.prompt_range.split(","))
            aus_timing_late.install(lo, hi)
    if not a.uap_plots:
        if a.kind == "charge":
            aus_plot_style.install_charge()      # every fit parameter in the legend
        else:
            aus_plot_style.install_timing()      # continuous model, 2 ns data points, mu / FWHM marked
    from uap.engine import root2csv
    root2csv.run(Namespace(**cfg))
    print("ROOT2CSV_DONE {}".format(cfg["out_csv"]))


if __name__ == "__main__":
    main()
