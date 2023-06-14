#!/usr/bin/env bash

source ENVS
conda activate $ICENET_CONDA

set -u -o pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage $0 PREDICTION_NETWORK"
    exit 1
fi

PREDICTION_NETWORK="$1"

for HEMI in south north; do
    DATE_RANGE="`date +%Y-1-1` `date +%F`"
    icenet_data_era5 -w 10 -v $DATA_ARGS_ERA5 $HEMI $DATE_RANGE 2>&1 | tee logs/fc.era5.${HEMI}.log
    icenet_data_sic -v $HEMI $DATE_RANGE 2>&1 | tee logs/fc.sic.${HEMI}.log

    FORECAST_INIT=`python -c 'import xarray as xr; print(str(xr.open_dataset("data/osisaf/'$HEMI'/siconca/'${DATE_RANGE:0:4}'.nc").time.values.max())[0:10])'`

    export FORECAST_START="$FORECAST_INIT"
    export FORECAST_END="$FORECAST_INIT"
    ./run_prediction.sh fc.$FORECAST_INIT $PREDICTION_NETWORK $HEMI forecast $TRAIN_DATA_NAME 2>&1 | tee logs/fc.${HEMI}.log

    ./produce_op_assets.sh fc.${FORECAST_INIT}_${HEMI} 2>&1 | tee logs/op_assets.${HEMI}.log
done
