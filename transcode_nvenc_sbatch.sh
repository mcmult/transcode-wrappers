#!/usr/bin/env bash

#SBATCH --ntasks=1 --cpus-per-task=4 --mem=8192 --gres=gpu:1
#SBATCH -o /home/mcmult/transcode-logs/%j__%x.log

THREADS=$SLURM_CPUS_ON_NODE
if [[ "x$THREADS" == "x" ]]; then
	THREADS=$(grep -c processor /proc/cpuinfo)
fi

if [[ $# -ge 2 ]]; then
	INFILE="${1}"
	HDR_SUPPORTED="${2}"
else
	echo "Error: Must provide at least 2 arguments"
	exit 1
fi

ffmpeg -version

OLD_IFS="$IFS"
IFS=$'\n'

RAW_LOC="/mnt/data/videos-raw"
FINAL_LOC="/data/videos/staging"
FNAME=$(basename $INFILE | sed 's/\.raw//')
FPATH=$(dirname $INFILE)
STAGEPATH="$FINAL_LOC/${FPATH#$RAW_LOC}"
OUTFILE="$STAGEPATH/$FNAME"

set -x

function x265_setup() {
	HDR_INFO=$(ffprobe -hide_banner -select_streams v -show_frames -read_intervals "%+#1" -show_entries "frame=color_space,color_primaries,color_transfer,side_data_list,pix_fmt" -i "${1}" 2>/dev/null)

	# if not defined, not hdr.
	if [ "x$HDR_INFO" == "x" ] || [ "$(echo "$HDR_INFO" | grep -c "color_space=unknown")" != "0" ]; then
		echo -n "";
		return;
	fi

	# not HDR, but does have color space information
	if [ "$(echo "$HDR_INFO" | grep -E -c "green_x=|blue_x=|red_x=")" == "0" ]; then
		X265_PARAMS="colorprim=$(echo "$HDR_INFO" | grep "color_primaries=" | cut -d "=" -f2)"
		X265_PARAMS="${X265_PARAMS}:transfer=$(echo "$HDR_INFO" | grep "color_transfer=" | cut -d "=" -f2)"
		X265_PARAMS="${X265_PARAMS}:colormatrix=$(echo "$HDR_INFO" | grep "color_space=" | cut -d "=" -f2)"
	else
		# This is HDR, lets build the opts string in the most ugly way possible
		X265_PARAMS="hdr-opt=1:repeat-headers=1"
		X265_PARAMS="$X265_PARAMS:colorprim=$(echo "$HDR_INFO" | grep "color_primaries=" | cut -d "=" -f2)"
		X265_PARAMS="$X265_PARAMS:transfer=$(echo "$HDR_INFO" | grep "color_transfer=" | cut -d "=" -f2)"
		X265_PARAMS="$X265_PARAMS:colormatrix=$(echo "$HDR_INFO" | grep "color_space=" | cut -d "=" -f2)"
		X265_PARAMS="${X265_PARAMS}:master-display="
		X265_PARAMS="${X265_PARAMS}G($(echo "$HDR_INFO" | grep "green_x=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "green_y=" | cut -d "=" -f2 | cut -d "/" -f1))"
		X265_PARAMS="${X265_PARAMS}B($(echo "$HDR_INFO" | grep "blue_x=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "blue_y=" | cut -d "=" -f2 | cut -d "/" -f1))"
		X265_PARAMS="${X265_PARAMS}R($(echo "$HDR_INFO" | grep "red_x=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "red_y=" | cut -d "=" -f2 | cut -d "/" -f1))"
		X265_PARAMS="${X265_PARAMS}WP($(echo "$HDR_INFO" | grep "white_point_x=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "white_point_y=" | cut -d "=" -f2 | cut -d "/" -f1))"
		X265_PARAMS="${X265_PARAMS}L($(echo "$HDR_INFO" | grep "max_luminance=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "min_luminance=" | cut -d "=" -f2 | cut -d "/" -f1))"
		X265_PARAMS="${X265_PARAMS}:max-cll=$(echo "$HDR_INFO" | grep "max_content=" | cut -d "=" -f2 | cut -d "/" -f1),$(echo "$HDR_INFO" | grep "max_average=" | cut -d "=" -f2 | cut -d "/" -f1)"
	fi

	echo -n "$X265_PARAMS"
}

function crop_detect() {
	if [ "$1" != "force" ]; then
		CROP=$(grep "${FNAME}" crop_db | awk -F '|' '{print $2}')
		if [ ! -z "${CROP}" ]; then
			echo "${CROP}"
			return
		fi
	fi
	CROP=$(ffmpeg -hwaccel auto -i "${INFILE}" -max_muxing_queue_size 1024 -vf "cropdetect=0.0941176471:2:0" -threads "${THREADS}" -f null - 2>&1 | awk '/crop/ { print $NF }' | tail -1)
	echo "${FNAME}|${CROP}" >> crop_db
	echo "${CROP}"
}

function nv_crop_detect() {
	CROP="${1}"
	# nvidia crop translation
	NV_CROP_LR="$(echo ${CROP} | awk -F ':' '{print $3}')"
	NV_CROP_TB="$(echo ${CROP} | awk -F ':' '{print $4}')"
	NV_CROP="${NV_CROP_TB}x${NV_CROP_TB}x${NV_CROP_LR}x${NV_CROP_LR}"
	echo "${NV_CROP}"
}

function get_field_order() {
	FIELD_ORDER=$(ffprobe -v quiet -hide_banner -select_streams v:0 -show_entries "stream=field_order" -i "${INFILE}"  | grep "field_order" | awk -F '=' '{print $2}')
	echo "${FIELD_ORDER}"
}

ENCODER="hevc_nvenc"

echo -n "Getting resolution for $INFILE ... "
INPUT_RESOLUTION=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "${INFILE}")
echo "${INPUT_RESOLUTION}"

if [[ "x${INPUT_RESOLUTION}" == "x720x480"* ]]; then
	ENCODER="h264_nvenc"
else
	echo -n "Detecting HDR for $INFILE ... "
	X265_PARAMS=$(x265_setup "${INFILE}")
	HDR=0
	if [ "x${X265_PARAMS}" != "x" ]; then
		if [ $(echo ${X265_PARAMS} | grep -c "hdr-opt=1") != 0 ]; then
			echo "HDR found ($X265_PARAMS)"
			HDR=1
			if [ "${HDR_SUPPORTED}" != "yes" ]; then
				echo "Skipping, HDR transcoding was not requested."
				exit
			fi
			ENCODER="libx265"
		else
			echo "not found"
		fi
	else
		echo "not found"
	fi
fi

echo -n "Detecting Crop for $INFILE ... "
CP_CROP=$(crop_detect)
NV_CROP=$(nv_crop_detect "${CP_CROP}")
echo "${CP_CROP} - ${NV_CROP}"
NV_DEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "${1}" | sed 's/video//')_cuvid"
FIELD_ORDER=$(get_field_order)
echo "FIELD_ORDER = $FIELD_ORDER"

set -e
echo "$(date): Transcoding $INFILE to $OUTFILE"
mkdir -p "${STAGEPATH}"
# If there is nothing to crop out, just strip non-english language
if [ "$HDR" == "0" ]; then
	if [ "x${X265_PARAMS}" == "x" ]; then
		if [ "${FIELD_ORDER}" != "progressive" ]; then
			ffmpeg -vsync passthrough -i "${INFILE}" -vf "${CP_CROP},fieldmatch,yadif=deint=interlaced,decimate" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v "${ENCODER}" -preset slow -cq:v 16 -rc 1 -profile:v 1 -tier 1 -spatial_aq 1 -temporal_aq 1 -rc_lookahead 48 -threads "${THREADS}" -c:a copy -c:s copy "${OUTFILE}"
		else
			ffmpeg -vsync passthrough -hwaccel cuda -hwaccel_output_format cuda -crop "${NV_CROP}" -c:v "${NV_DEC}" -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v "${ENCODER}" -preset slow -cq:v 16 -rc 1 -profile:v 1 -tier 1 -spatial_aq 1 -temporal_aq 1 -rc_lookahead 48 -threads "${THREADS}" -c:a copy -c:s copy "${OUTFILE}"
		fi
	else
		PRIMARIES="$(echo "${X265_PARAMS}" | grep "colorprim" | cut -d "=" -f2 | cut -d ":" -f1)"
		TRANSFER="$(echo "${X265_PARAMS}" | grep "transfer" | cut -d "=" -f2 | cut -d ":" -f1)"
		SPACE="$(echo "${X265_PARAMS}" | grep "colormatrix" | cut -d "=" -f2 | cut -d ":" -f1)"
		if [ "${FIELD_ORDER}" != "progressive" ]; then
			ffmpeg -vsync passthrough -i "${INFILE}" -vf "${CP_CROP},fieldmatch,yadif=deint=interlaced,decimate" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v "${ENCODER}" -preset slow -cq:v 16 -rc 1 -profile:v 1 -tier 1 -spatial_aq 1 -temporal_aq 1 -rc_lookahead 48 -color_primaries "${PRIMARIES}" -color_trc "${TRANSFER}" -colorspace "${SPACE}" -threads "${THREADS}" -c:a copy -c:s copy "${OUTFILE}"
		else
			ffmpeg -vsync passthrough -hwaccel cuda -hwaccel_output_format cuda -crop "${NV_CROP}" -c:v "${NV_DEC}" -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v "${ENCODER}" -preset slow -cq:v 16 -rc 1 -profile:v 1 -tier 1 -spatial_aq 1 -temporal_aq 1 -rc_lookahead 48 -color_primaries "${PRIMARIES}" -color_trc "${TRANSFER}" -colorspace "${SPACE}" -threads "${THREADS}" -c:a copy -c:s copy "${OUTFILE}"
		fi
	fi
else
	ffmpeg -vsync passthrough -hwaccel cuda -hwaccel_output_format cuda -crop "${NV_CROP}" -c:v "${NV_DEC}" -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v "${ENCODER}" -x265-params "${X265_PARAMS}" -preset slow -crf 16 -threads "${THREADS}" -c:a copy -c:s copy "${OUTFILE}"
fi
echo "$(date): Archiving $INFILE to ${FPATH}/${FNAME}"
mv "${INFILE}" "${FPATH}/${FNAME}"

IFS="$OLD_IFS"

