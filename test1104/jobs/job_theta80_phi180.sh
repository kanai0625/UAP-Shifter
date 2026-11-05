#!/usr/bin/env bash
#PJM -L rscgrp=all
set -euo pipefail
source "/disk2/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/thisroot.sh"
source "/disk2/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61/pyrate_venv/bin/activate"
"/disk2/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61/pyrate_venv/bin/pyrate" -c "/disk2/disk03/usr8/kanai062/UAP-Shifter/test1104/configs/R12860_theta80_phi180_dat.yaml" -n 20000 > "/disk2/disk03/usr8/kanai062/UAP-Shifter/test1104/logs/theta80_phi180.log" 2>&1
