#!/usr/bin/env bash

#SBATCH --ntasks=1 --cpus-per-task=16 --mem=32G
#SBATCH -o /home/mcmult/transcode-logs/%j__%x.log

THREADS=$SLURM_CPUS_ON_NODE
if [[ "x$THREADS" == "x" ]]; then
	THREADS=$(grep -c processor /proc/cpuinfo)
	if [[ $THREADS > 16 ]]; then
		THREADS=16
	fi
fi

if [[ $# -ge 1 ]]; then
	INFILE="${1}"
	CROP="${2}"
else
	echo "Error: Must provide at least 2 arguments"
	exit 1
fi

module load ffmpeg-tc
ffmpeg -version

OLD_IFS="$IFS"
IFS=$'\n'

RAW_LOC="/mnt/data/videos-raw"
FINAL_LOC="/data/videos/staging"
FNAME=$(basename $INFILE | sed 's/\.raw//')
FPATH=$(dirname $INFILE)
STAGEPATH="$FINAL_LOC/${FPATH#$RAW_LOC}"
OUTFILE="$STAGEPATH/$FNAME"

IFS="$OLD_IFS"

SVTAV1_PARAMS="-crf 20 -preset 8 -g 120 -svtav1-params tune=0:enable-overlays=1:scd=1"
LIBX264_PARAMS="-crf 16 -preset medium"
OUTPUT_PIXFMT="yuv420p10le"

set -x

function SVTAV1_HDR_setup() {
	HDR_INFO=$(ffprobe -hide_banner -select_streams v -show_frames -read_intervals "%+#1" -show_entries "frame=color_space,color_primaries,color_transfer,side_data_list,pix_fmt" -i "${1}" 2>/dev/null)

	# if not defined, not hdr.
	if [ "x$HDR_INFO" == "x" ] || [ "$(echo "$HDR_INFO" | grep -c "color_space=unknown")" != "0" ]; then
		echo -n "$SVTAV1_PARAMS"
		return;
	fi

	# not HDR, but does have color space information
	if [ "$(echo "$HDR_INFO" | grep -E -c "green_x=|blue_x=|red_x=")" != "0" ]; then
		IS_HDR=1
		SVTAV1_PARAMS="-color_primaries:v $(echo "$HDR_INFO" | grep "color_primaries=" | cut -d "=" -f2) ${SVTAV1_PARAMS}"
		SVTAV1_PARAMS="-color_trc:v $(echo "$HDR_INFO" | grep "color_transfer=" | cut -d "=" -f2) ${SVTAV1_PARAMS}"
		SVTAV1_PARAMS="${SVTAV1_PARAMS}:mastering-display="
		SVTAV1_PARAMS="${SVTAV1_PARAMS}G($(echo "$HDR_INFO" | grep "green_x=" | cut -d "=" -f2),$(echo "$HDR_INFO" | grep "green_y=" | cut -d "=" -f2))"
		SVTAV1_PARAMS="${SVTAV1_PARAMS}B($(echo "$HDR_INFO" | grep "blue_x=" | cut -d "=" -f2),$(echo "$HDR_INFO" | grep "blue_y=" | cut -d "=" -f2))"
		SVTAV1_PARAMS="${SVTAV1_PARAMS}R($(echo "$HDR_INFO" | grep "red_x=" | cut -d "=" -f2),$(echo "$HDR_INFO" | grep "red_y=" | cut -d "=" -f2))"
		SVTAV1_PARAMS="${SVTAV1_PARAMS}WP($(echo "$HDR_INFO" | grep "white_point_x=" | cut -d "=" -f2),$(echo "$HDR_INFO" | grep "white_point_y=" | cut -d "=" -f2))"
		SVTAV1_PARAMS="${SVTAV1_PARAMS}L($(echo "$HDR_INFO" | grep "max_luminance=" | cut -d "=" -f2),$(echo "$HDR_INFO" | grep "min_luminance=" | cut -d "=" -f2))"
		SVTAV1_PARAMS="${SVTAV1_PARAMS}:content-light=$(echo "$HDR_INFO" | grep "max_content=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "max_average=" | cut -d "=" -f2 | cut -d "/" -f1)"
		#SVTAV1_PARAMS="${SVTAV1_PARAMS}:matrix-coefficients=$(echo "$HDR_INFO" | grep "color_space=" | cut -d "=" -f2)"
	fi

	echo -n "$SVTAV1_PARAMS"
}

function crop_detect() {
	CROP=$(ffmpeg -hwaccel auto -i "${INFILE}" -max_muxing_queue_size 1024 -vf "cropdetect=0.0941176471:2:0" -threads "${THREADS}" -f null - 2>&1 | awk '/crop/ { print $NF }' | tail -1)
	echo "${CROP}"
}

function get_field_order() {
	FIELD_ORDER=$(ffprobe -v quiet -hide_banner -select_streams v:0 -show_entries "stream=field_order" -i "${INFILE}"  | grep "field_order" | awk -F '=' '{print $2}')
	echo "${FIELD_ORDER}"
}

echo -n "Getting resolution for $INFILE ... "
INPUT_RESOLUTION=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "${INFILE}")
echo "${INPUT_RESOLUTION}"

if [[ "x${INPUT_RESOLUTION}" == "x720x480"* ]]; then
	ENCODER="libx264"
	ENCODER_PARAMS=$LIBX264_PARAMS
else
	ENCODER="libsvtav1"
	ENCODER_PARAMS=$(SVTAV1_HDR_setup "${INFILE}")
fi

if [ ! -z "$CROP" ]; then
	CP_CROP="-vf ${CROP}"
else
	echo -n "Detecting Crop for $INFILE ... "
	CP_CROP="-vf $(crop_detect)"
fi
echo "${CP_CROP}"
FIELD_ORDER=$(get_field_order)
echo "FIELD_ORDER = $FIELD_ORDER"

set -e
echo "$(date): Transcoding $INFILE to $OUTFILE"
mkdir -p "${STAGEPATH}"

ffmpeg -vsync passthrough -hwaccel auto -i "${INFILE}" -map 0:m:language:eng -c:v ${ENCODER} ${CP_CROP} ${ENCODER_PARAMS} -pix_fmt "${OUTPUT_PIXFMT}" -threads "${THREADS}" -c:a copy -c:s copy "${OUTFILE}"

if [[ "${INFILE}" == *".raw.mkv" ]]; then
	echo "$(date): Archiving $INFILE to ${FPATH}/${FNAME}"
	mv "${INFILE}" "${FPATH}/${FNAME}"
fi
