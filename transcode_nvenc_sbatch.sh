#!/usr/bin/env bash

#SBATCH --ntasks=1 --cpus-per-task=1 --mem=8192 --gres=gpu:1
#SBATCH -o /home/mcmult/transcode-logs/%j__%x.log

RAW_LOC="/data/videos-raw"
FINAL_LOC="/data/videos/staging"

INFILE="${1}"
HDR_SUPPORTED="${2}"

module load ffmpeg

OLD_IFS="$IFS"
IFS=$'\n'

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


FNAME=$(basename $INFILE | sed 's/\.raw//')
FPATH=$(dirname $INFILE)
STAGEPATH="$FINAL_LOC/${FPATH#$RAW_LOC}"
OUTFILE="$STAGEPATH/$FNAME"
echo -n "Detecting HDR for $INFILE ... "
X265_PARAMS=$(x265_setup "${INFILE}")
HDR=0
if [ "x${X265_PARAMS}" != "x" ]; then
	if [ $(echo ${X265_PARAMS} | grep -E -c "green_x=|blue_x=|red_x=") != 0 ]; then
		echo "HDR found ($X265_PARAMS)"
		HDR=1
		if [ "${HDR_SUPPORTED}" != "yes" ]; then
			echo "Skipping for now, HDR not supported (yet)"
			continue
		fi
	else
		echo "not found"
	fi
else
	echo "not found"
fi
echo -n "Detecting Crop for $INFILE ... "
CROP=$(ffmpeg -hwaccel auto -i "${INFILE}" -max_muxing_queue_size 1024 -vf "cropdetect=24:2:0" -t 900 -f null - 2>&1 | awk '/crop/ { print $NF }' | tail -1)
echo -n "${CROP}"
# nvidia crop translation
NV_CROP_LR="$(echo ${CROP} | awk -F ':' '{print $3}')"
NV_CROP_TB="$(echo ${CROP} | awk -F ':' '{print $4}')"
NV_CROP="${NV_CROP_TB}x${NV_CROP_TB}x${NV_CROP_LR}x${NV_CROP_LR}"
echo " ${NV_CROP}"
NV_DEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "${1}")_cuvid"
set -e
echo "$(date): Transcoding $INFILE to $OUTFILE"
mkdir -p "${STAGEPATH}"
# If there is nothing to crop out, just strip non-english language
if [ "$HDR" == "0" ]; then
	if [ "x${X265_PARAMS}" == "x" ]; then
		ffmpeg -vsync passthrough -hwaccel cuda -hwaccel_output_format cuda -crop "${NV_CROP}" -c:v "${NV_DEC}" -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v hevc_nvenc -preset slow -cq:v 16 -rc 1 -profile:v 1 -tier 1 -spatial_aq 1 -temporal_aq 1 -rc_lookahead 48 -c:a copy -c:s copy "${OUTFILE}"
	else
		PRIMARIES="$(echo "${X265_PARAMS}" | grep "colorprim" | cut -d "=" -f2 | cut -d ":" -f1)"
		TRANSFER="$(echo "${X265_PARAMS}" | grep "transfer" | cut -d "=" -f2 | cut -d ":" -f1)"
		SPACE="$(echo "${X265_PARAMS}" | grep "colormatrix" | cut -d "=" -f2 | cut -d ":" -f1)"
		ffmpeg -vsync passthrough -hwaccel cuda -hwaccel_output_format cuda -crop "${NV_CROP}" -c:v "${NV_DEC}" -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v hevc_nvenc -preset slow -cq:v 16 -rc 1 -profile:v 1 -tier 1 -spatial_aq 1 -temporal_aq 1 -rc_lookahead 48 -color_primaries "${PRIMARIES}" -color_trc "${TRANSFER}" -colorspace "${SPACE}" -c:a copy -c:s copy "${OUTFILE}"
	fi
else
	ffmpeg -vsync passthrough -hwaccel cuda -hwaccel_output_format cuda -crop "${NV_CROP}" -c:v "${NV_DEC}" -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -map 0:m:language:eng -c:v libx265 -x265-params "${X265_PARAMS}" -preset slow -crf 16 -c:a copy -c:s copy "${OUTFILE}"
fi
echo "$(date): Archiving $INFILE to ${FPATH}/${FNAME}"
mv "${INFILE}" "${FPATH}/${FNAME}"

IFS="$OLD_IFS"
