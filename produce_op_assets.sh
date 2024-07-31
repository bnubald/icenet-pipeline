#!/usr/bin/env bash

display_help() {
  echo "Usage: $0 [options] <forecast name w/hemi> [region]"
  echo
  echo "Generate forecast outputs from netCDF prediction file (Outputs: geotiff, png, mp4)"
  echo "Outputs to 'results/forecast/<forecast name w/hemi>'"
  echo
  echo "Positional arguments:"
  echo "  name			Name of the prediction netCDF file, with hemisphere postfix ('_south'), e.g. 'forecastfile_south'."
  echo "  region		Region to clip. If prefixed with 'l', will use lat/lon, else, pixel bounds."
  echo "			Specify via 'x_min,y_min,x_max,y_max' if using pixel bounds."
  echo "			Specify via 'llat_min,lon_min,lat_max,lon_max' if using lat/lon bounds (Notice the prefix 'l', see example below)."
  echo "Optional arguments:"
  echo "  -c	Cartopy CRS to use for plotting forecasts (e.g. Mercator)."
  echo "  -h    Show this help message and exit."
  echo "  -l    Integer defining max leadtime to generate outputs for."
  echo "  -n    To not clip data when specifying lat/lon region with -c, else, depending on CRS, may plot may have missing regions."
  echo "  -v    Enable verbose mode - debugging print of commands."
  echo
  echo "Examples:"
  echo "  1) $0 -v"
  echo "    Runs script in verbose mode, in this case, just prints help."
  echo
  echo "  2) $0 fc.2024-05-21_north 70,155,145,240"
  echo "    Produce outputs from './results/predict/fc.2024-05-21_north.nc'"
  echo "    and crop to only the pixel region of x_min=70, y_min=155, x_max=145, y_max=240."
  echo
  echo "  3) $0 fc.2024-05-21_north l-100,55,-70,75"
  echo "    Produce outputs from './results/predict/fc.2024-05-21_north.nc'"
  echo "    and crop to lat/lon region of lat_min=55, lon_min=-100, lat_max=75, lon_max=-70."
  echo
  echo "  4) $0 -n fc.2024-05-21_north l-100,55,-70,75"
  echo "    Same as 4), but outputs north-facing plots instead of polar equal area."
  echo
  echo "  5) $0 -c Mercator.GOOGLE fc.2024-05-21_north l-100,55,-70,75"
  echo "    Same as 4), but outputs using Web Mercator for plots instead of polar equal area."
  echo

}

start=$(date +%s)

set -e -o pipefail

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
  display_help
  exit 0
fi

echo "ARGS: $@"

# Defaults if not specified
SCRIPT_ARGS=""
MAX_LEADTIME="93"
VERBOSE=""
SKIP_METRICS=false

while getopts "c:l:nv" opt; do
  case "$opt" in
    c) SCRIPT_ARGS="${SCRIPT_ARGS}--crs ${OPTARG} ";;
    l) MAX_LEADTIME="${OPTARG}";;
    n) SCRIPT_ARGS="${SCRIPT_ARGS}--no-clip-region ";;
    v) VERBOSE="-v";;
  esac
done

shift $((OPTIND-1))

[[ "${1:-}" = "--" ]] && shift

if [ $# -lt 1 ]; then
  display_help
  exit 1
fi

[ -n "$VERBOSE" ] && SCRIPT_ARGS="${SCRIPT_ARGS}-v"

echo "ARGS = $SCRIPT_ARGS, Leftovers: $@"

if [ -n "$VERBOSE" ]; then
  echo "~~Verbosity enabled~~"
  set -x
fi

FORECAST_NAME="$1"
REGION="$2"

OUTPUT_DIR="results/forecasts/$FORECAST_NAME"
LOG_DIR="log/forecasts/$FORECAST_NAME"

FORECAST_FILE="results/predict/${FORECAST_NAME}.nc"
HEMI=`echo $FORECAST_NAME | sed -r 's/^.+_(north|south)$/\1/'`

if [ -n "$REGION" ]; then
    if [[ "$REGION" == l* ]]; then
        SKIP_METRICS=true
        REGION="-z=${REGION:1}"
        printf '\033[0;31mNote: The metrics such as binary accuracy, sic and sie error do not currently support lat/lon based region bounds!\033[0m'
        echo
    else
        REGION="-r $REGION"
    fi
fi

if ! [[ $HEMI =~ ^(north|south)$ ]]; then
  echo "Hemisphere from $FORECAST_NAME not available, raise an issue"
  exit 1
fi


function produce_docs {
  local DIR=$1

  cp template_LICENSE.md ${DIR}/LICENSE.md
  cp template_README.md ${DIR}/README.md
}

function rename_gfx {
  GFX_DIR="$1"
  F_PREFIX="$2"
  F_GLOB="$3"

  for NOM in $( find $GFX_DIR -name "${F_PREFIX}${F_GLOB}" ); do
    NOM_FILENAME=`basename $NOM`
    mv -v $NOM ${GFX_DIR}/${NOM_FILENAME#${F_PREFIX}}
  done
}


for WORKING_DIR in "$OUTPUT_DIR" "$LOG_DIR"; do
  if [ -d $WORKING_DIR ]; then
    echo "Output directory $WORKING_DIR already exists, removing"
    rm -rv $OUTPUT_DIR
  fi
done

echo "Making $OUTPUT_DIR"
mkdir -p $OUTPUT_DIR

for DATE_FORECAST in $( cat ${FORECAST_NAME}.csv ); do
  DATE_DIR="$OUTPUT_DIR/$DATE_FORECAST"
  echo "Making $DATE_DIR for forecast date $DATE_FORECAST"
  mkdir -p $DATE_DIR

  echo "Producing single output file for date forecast"
  python -c 'import xarray; xarray.open_dataset("'$FORECAST_FILE'").sel(time=slice("'$DATE_FORECAST'", "'$DATE_FORECAST'")).to_netcdf("'$DATE_DIR'/'$DATE_FORECAST'.nc")'

  echo "Producing geotiffs from that file"
  icenet_output_geotiff -o $DATE_DIR $FORECAST_FILE $DATE_FORECAST 1..${MAX_LEADTIME}
  rename_gfx $DATE_DIR "${FORECAST_NAME}.${DATE_FORECAST}." '*.tiff'

  echo "Producing movie file of raw video"
  icenet_plot_forecast $REGION $SCRIPT_ARGS -o $DATE_DIR -l 1..${MAX_LEADTIME} -f mp4 $HEMI $FORECAST_FILE $DATE_FORECAST
  rename_gfx $DATE_DIR "${FORECAST_NAME}.${DATE_FORECAST}." '*.mp4'

  echo "Producing stills for manual composition (with coastlines)"
  icenet_plot_forecast $REGION $SCRIPT_ARGS -o $DATE_DIR -l 1..${MAX_LEADTIME} $HEMI $FORECAST_FILE $DATE_FORECAST
  rename_gfx $DATE_DIR "${FORECAST_NAME}.${DATE_FORECAST}." '*.png'

  echo "Producing movie and stills of ensemble standard deviation in predictions"
  icenet_plot_forecast $REGION $SCRIPT_ARGS -s -o $DATE_DIR -l 1..${MAX_LEADTIME} -f mp4 $HEMI $FORECAST_FILE $DATE_FORECAST
  rename_gfx $DATE_DIR "${FORECAST_NAME}.${DATE_FORECAST}." '*.stddev.mp4'

  icenet_plot_forecast $REGION $SCRIPT_ARGS -s -o $DATE_DIR -l 1..${MAX_LEADTIME} $HEMI $FORECAST_FILE $DATE_FORECAST
  rename_gfx $DATE_DIR "${FORECAST_NAME}.${DATE_FORECAST}." '*.stddev.png'

  produce_docs $DATE_DIR


  if [[ "$SKIP_METRICS" = true ]]; then
    continue
  fi

  # TODO: copy docs to root folder
  # TODO: copy plot/ content for whole domain

  echo "Producing binary accuracy plots (these are meaningless forecasting into the future w.r.t the OSISAF data)"

  SIC_FILENAME="./data/osisaf/${HEMI}/siconca/`date +%Y`.nc"
  # Get the most recent day, sorry for ignoring all timezone information
  SIC_LATEST=`python -c 'import xarray; print(str(xarray.open_dataset("'$SIC_FILENAME'").time.values[-1])[0:10])'`

  if [[ `date --date="$SIC_LATEST" +%s` -gt `date --date="$DATE_FORECAST + 1 day" +%s` ]]; then
    echo "We have necessary SIC data ($SIC_LATEST) for forecast date $DATE_FORECAST"

    for THRESHOLD in 0.15 0.5 0.8 0.9; do
      icenet_plot_bin_accuracy $REGION -e -b -t $THRESHOLD \
        -o ${DATE_DIR}/bin_accuracy.${THRESHOLD}.png \
        $HEMI $FORECAST_FILE $DATE_FORECAST
    done

    icenet_plot_metrics $REGION -e -b -s \
      -o ${DATE_DIR}/ \
      $HEMI $FORECAST_FILE $DATE_FORECAST

    icenet_plot_sic_error $REGION \
      -o ${DATE_DIR}/${DATE_FORECAST}.sic_error.mp4 \
      $HEMI $FORECAST_FILE $DATE_FORECAST

    icenet_plot_sie_error $REGION -e -b \
      -o ${DATE_DIR}/${DATE_FORECAST}.sie_error.25.png \
      $HEMI $FORECAST_FILE $DATE_FORECAST
  else
    echo "We do not have observational SIC data ($SIC_LATEST) for plotting \
    forecast date $DATE_FORECAST"
  fi

  # Future uses - probably via another workflow:
  #  rsync to local destinations?
  #  Azure blob storage upload using az
done

echo "Done, enjoy your forecasts in $OUTPUT_DIR"

end=$(date +%s)
echo "Elapsed Time: $(($end-$start)) seconds"
