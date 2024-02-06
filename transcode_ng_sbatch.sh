#!/usr/bin/env bash

#SBATCH --ntasks=1 --cpus-per-task=16 --mem=32G
#SBATCH -o /home/mcmult/transcode-logs/%j__%x.log

### Option Parsing ###
function show_help() {
	echo -e "Usage: $(basename ${1}) [OPTIONS]"
	echo -e "\t-e\tSpecify what library to use to encode video.  Default is libsvtav1."
	echo -e "\t-f\tRoot directory where final file should go. This option is mandatory."
	echo -e "\t-l\tRoot directory where raw files live. This option is mandatory."
	echo -e "\t-i\tInput file to operate on. This option is mandatory."
	echo -e "\t-h|?\tDisplay this help text"
}

OPTIND=1

INFILE=""
RAW_LOC=""
FINAL_LOC=""

OLD_IFS="$IFS"
IFS=$'\n'

while getopts "h?e:f:i:l:" opt; do
	case "$opt" in
		h|\?)
			show_help $0
			;;
		e)
			ENCODER=${OPTARG}
			if [[ "libsvtav1 libx264 libx265" != *"$ENCODER"* ]]; then
				echo "Error: $ENCODER is not supported at this time."
				exit 1
			fi
			;;
		f)
			FINAL_LOC=${OPTARG}
			;;
		i)
			INFILE=${OPTARG}
			;;
		l)
			RAW_LOC=${OPTARG}
			;;
	esac
done

shift $((OPTIND-1))

if [[ -z "$FINAL_LOC" ]] || [[ -z "$INFILE" ]] || [[ -z "$RAW_LOC" ]]; then
	echo "Error, -f -i and -l must all be specified."
	show_help $0
	exit 1
fi

### Set variables ###
FNAME=$(basename $INFILE | sed 's/\.raw//')
FPATH=$(dirname $INFILE)
STAGEPATH="$FINAL_LOC/${FPATH#$RAW_LOC}"
OUTFILE="$STAGEPATH/$FNAME"

IFS="$OLD_IFS"

### Set thread count ###
THREADS=$SLURM_CPUS_ON_NODE
if [[ "x$THREADS" == "x" ]]; then
	THREADS=$(grep -c processor /proc/cpuinfo)
	if [[ $THREADS > 16 ]]; then
		THREADS=16
	fi
fi

### Default output options ###
SVTAV1_PARAMS="-crf 20 -preset 8 -g 120 -svtav1-params tune=0:enable-overlays=1:scd=1:lp=${THREADS}"
LIBX264_PARAMS="-crf 16 -preset medium"
LIBX265_PARAMS="-crf 18 -preset medium"
OUTPUT_PIXFMT="yuv420p10le"

### Load ffmpeg ###
module load ffmpeg-tc
ffmpeg -version

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
	if [ "$1" != "force" ]; then
		CROP=$(grep -F "${FNAME}" crop_db | awk -F '|' '{print $2}')
		if [ ! -z "${CROP}" ]; then
			echo "${CROP}"
			return
		fi
	fi
	CROP=$(ffmpeg -i "${INFILE}" -max_muxing_queue_size 1024 -vf "cropdetect=0.0941176471:2:0" -threads "${THREADS}" -f null - 2>&1 | awk '/crop/ { print $NF }' | tail -1)
	echo "${FNAME}|${CROP}" >> crop_db
	echo "${CROP}"
}

function get_field_order() {
	FIELD_ORDER=$(ffprobe -v quiet -hide_banner -select_streams v:0 -show_entries "stream=field_order" -i "${INFILE}"  | grep "field_order" | awk -F '=' '{print $2}')
	echo "${FIELD_ORDER}"
}

if [ -z "${ENCODER}" ]; then
	ENCODER="libsvtav1"
fi

case "${ENCODER}" in
	"libx264")
		ENCODER_PARAMS=$LIBX264_PARAMS
		;;
	"libx265")
		ENCODER_PARAMS=${LIBX265_PARAMS}
		;;
	"libsvtav1")
		ENCODER_PARAMS=$(SVTAV1_HDR_setup "${INFILE}")
		;;
	*)
		echo "Error: invalid encoder \"${ENCODER}\""
		exit
		;;
esac

SRC_RES=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "${INFILE}" | sed s/x/:/)

if [ -z "$CROP" ]; then
	echo -n "Detecting Crop for $INFILE ... "
	CROP="$(crop_detect)"
fi
if [ "crop=${SRC_RES}:0:0" == "${CROP}" ]; then
	echo "Crop filter disabled: input and output resolution is the same."
	CP_CROP=""
else
	CP_CROP="-vf ${CROP}"
	echo "Crop filter enabled: ${CP_CROP}"
fi
FIELD_ORDER=$(get_field_order)
echo "FIELD_ORDER = $FIELD_ORDER"

set -e
echo "$(date): Transcoding $INFILE to $OUTFILE"
mkdir -p "${STAGEPATH}"

ffmpeg -i "${INFILE}" -map 0:m:language:eng -c:v ${ENCODER} ${CP_CROP} ${ENCODER_PARAMS} -pix_fmt "${OUTPUT_PIXFMT}" -threads "${THREADS}" -c:a copy -c:s copy -fps_mode passthrough "${OUTFILE}"

if [[ "${INFILE}" == *".raw.mkv" ]]; then
	echo "$(date): Archiving $INFILE to ${FPATH}/${FNAME}"
	mv "${INFILE}" "${FPATH}/${FNAME}"
fi
