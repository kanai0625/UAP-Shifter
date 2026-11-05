#!/usr/bin/env bash
#PJM -L rscgrp=all
#PJM -L elapse="2:00:00"
set -euo pipefail
source "/disk2/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/thisroot.sh"
source "/disk03/usr8/kanai062/UAP-Shifter/miniforge3/etc/profile.d/conda.sh"
conda activate "/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap"
export PATH="/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin:$PATH"
export LD_LIBRARY_PATH="/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib:/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib/root:${LD_LIBRARY_PATH:-}"
python3 "/disk2/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/pyrate" -c "/disk2/disk03/usr8/kanai062/UAP-Shifter/1105/1101-200616-EM6190-C/configs/R12860_theta60_phi270_dat.yaml" -n 10000 > "/disk2/disk03/usr8/kanai062/UAP-Shifter/1105/1101-200616-EM6190-C/logs/theta60_phi270.log" 2>&1
