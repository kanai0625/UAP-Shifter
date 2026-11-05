#!/usr/bin/env bash
#PJM -L rscgrp=hk
set -euo pipefail
source "/disk2/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/thisroot.sh"
source "/disk2/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61/pyrate_venv/bin/activate"
"/disk2/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61/pyrate_venv/bin/pyrate" -c "/disk2/disk03/usr8/kanai062/UAP-Shifter/jobtest-1104/configs/R12860_theta60_phi180_dat.yaml" > "/disk2/disk03/usr8/kanai062/UAP-Shifter/jobtest-1104/logs/theta60_phi180.log" 2>&1
