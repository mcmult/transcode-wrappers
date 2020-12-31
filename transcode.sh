#!/usr/bin/env bash

RAW_LOC="/data/videos-raw"
ARCHIVE_LOC="/data/videos-raw/ZZ_Done"
FINAL_LOC="/data/videos/staging"

OLD_IFS="$IFS"
IFS=$'\n'

function hdr_setup() {
	HDR_INFO=$(ffprobe -hide_banner -select_streams v -show_frames -read_intervals "%+#1" -show_entries "frame=color_space,color_primaries,color_transfer,side_data_list,pix_fmt" -i "${1}" 2>/dev/null)

	# if not defined, not hdr.
	if [ "x$HDR_INFO" == "x" ] || [ "$(echo "$HDR_INFO" | grep -c "color_space=unknown")" != "0" ]; then
		echo -n "";
		return;
	fi

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

	echo -n "$X265_PARAMS"
}


for INFILE in $(find "${RAW_LOC}" -type f \( -name *.raw* -a ! -path *ZZ_Done* \)); do
	FNAME=$(basename $INFILE | sed 's/\.raw//')
	FPATH=$(dirname $INFILE)
	OUTFILE="$FPATH/$FNAME"
	ARCHIVEPATH="$ARCHIVE_LOC/${FPATH#$RAW_LOC}"
	STAGEPATH="$FINAL_LOC/${FPATH#$RAW_LOC}"
	echo -n "Detecting Crop for $INFILE... "
	CROP=$(ffmpeg -i "${INFILE}" -max_muxing_queue_size 1024 -vf "cropdetect=24:2:0" -t 900 -f null - 2>&1 | awk '/crop/ { print $NF }' | tail -1)
	echo "${CROP}"
	echo -n "Detecting if HDR..."
	HDR=$(hdr_setup "${INFILE}")
	if [ "x${HDR}" != "x" ]; then
		echo "HDR found ($HDR)"
	else
		echo "not found"
	fi
	set -e
	echo "$(date): Transcoding $INFILE to $OUTFILE"
	if [ "x${HDR}" == "x" ]; then
		ffmpeg -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -c:v libx265 -vf "${CROP}" -preset slow -crf 18 -c:a copy -c:s copy "${OUTFILE}"
	else
		ffmpeg -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -c:v libx265 -x265-params "${HDR}" -vf "${CROP}" -preset slow -crf 18 -c:a copy -c:s copy "${OUTFILE}"
	fi
	echo "$(date): Archiving $INFILE to ${ARCHIVEPATH}/$(basename $INFILE)" 
	mkdir -p "$ARCHIVEPATH"
	mv "$INFILE" "${ARCHIVEPATH}/$(basename $INFILE)"
	echo "$(date): Staging $INFILE to ${STAGEPATH}/${FNAME}"
	mkdir -p "$STAGEPATH"
	mv "$OUTFILE" "${STAGEPATH}/${FNAME}"
done

IFS="$OLD_IFS"
