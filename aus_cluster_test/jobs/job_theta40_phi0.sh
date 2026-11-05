#!/usr/bin/env bash
#PJM -L rscgrp=all
#PJM -L elapse="1:00:00"
set -euo pipefail
source "/disk2/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/thisroot.sh"
source "/disk2/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61/pyrate_venv/bin/activate"
"/disk2/disk03/usr8/schen/workspace/HKPrecal/waveformreader/aus_pyrate/darkmatteraustralia-pyrate-3c2e05d64b61/pyrate_venv/bin/pyrate" -c "/disk2/disk03/usr8/kanai062/UAP-Shifter/aus_cluster_test/configs/R12860_theta40_phi0_dat.yaml" -n 1000 > "/disk2/disk03/usr8/kanai062/UAP-Shifter/aus_cluster_test/logs/theta40_phi0.log" 2>&1
