#!/usr/bin/env bash

RAW_LOC="/data/videos-raw"
ARCHIVE_LOC="/data/videos-raw/ZZ_Done"
FINAL_LOC="/data/videos/staging"

OLD_IFS="$IFS"
IFS=$'\n'

for INFILE in $(find "${RAW_LOC}" -type f \( -name *.raw* -a ! -path *ZZ_Done* \)); do
	FNAME=$(basename $INFILE | sed 's/\.raw//')
	FPATH=$(dirname $INFILE)
	OUTFILE="$FPATH/$FNAME"
	ARCHIVEPATH="$ARCHIVE_LOC/${FPATH#$RAW_LOC}"
	STAGEPATH="$FINAL_LOC/${FPATH#$RAW_LOC}"
	echo -n "Detecting Crop for $INFILE... "
	CROP=$(ffmpeg -i "${INFILE}" -max_muxing_queue_size 1024 -vf "cropdetect=24:2:0" -t 900 -f null - 2>&1 | awk '/crop/ { print $NF }' | tail -1)
	echo "${CROP}"
	echo "$(date): Transcoding $INFILE to $OUTFILE"
	ffmpeg -i "${INFILE}" -max_muxing_queue_size 1024 -fflags +genpts -c:v libx265 -vf "${CROP}" -preset slow -crf 18 -c:a copy -c:s copy "${OUTFILE}"
	echo "$(date): Archiving $INFILE to ${ARCHIVEPATH}/$(basename $INFILE)" 
	mkdir -p "$ARCHIVEPATH"
	mv "$INFILE" "${ARCHIVEPATH}/$(basename $INFILE)"
	echo "$(date): Staging $INFILE to ${STAGEPATH}/${FNAME}"
	mkdir -p "$STAGEPATH"
	mv "$OUTFILE" "${STAGEPATH}/${FNAME}"
done

IFS="$OLD_IFS"
