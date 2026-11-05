#!/usr/bin/env bash
#PJM -L rscgrp=hk
#PJM -L elapse="1:00:00"
set -euo pipefail
source "/disk03/usr8/kanai062/UAP-Shifter/miniforge3/etc/profile.d/conda.sh"
conda activate "/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap"
export CONDA_PREFIX="/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap"
export PATH="/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin:$PATH"
export LD_LIBRARY_PATH="/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib:/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib/root:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/lib/python3.8/site-packages:${PYTHONPATH:-}"
python3 "/disk2/disk03/usr8/kanai062/UAP-Shifter/miniforge3/envs/hkprecal-uap/bin/pyrate" -c "/disk2/disk03/usr8/kanai062/UAP-Shifter/1105/1030-035344-EM5650-H/configs/R12860_theta0_phi0_dat.yaml" -n 100 > "/disk2/disk03/usr8/kanai062/UAP-Shifter/1105/1030-035344-EM5650-H/logs/theta0_phi0.log" 2>&1
