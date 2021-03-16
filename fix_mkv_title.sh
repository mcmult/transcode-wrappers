#!/usr/bin/env bash

if [ "$#" != "1" ]; then
	echo "Must provide a path to search for MKV files"
	exit 1;
fi

OLD_IFS="$IFS"
IFS=$'\n'

for INFILE in $(find "$1" -type f \( -name *.mkv \) | sort); do
	FNAME=$(basename $INFILE)
	TITLE=${FNAME::-4}
	echo -n "checking \"$FNAME\"..."

	# rejection handling
	RES="${TITLE//[^.]}"
	if [ ${#RES} -ge 2 ] && [ $(echo $TITLE | grep -c "\.\.\.") -eq 0 ]; then
		echo " Skipping (file name is nonsense)"
		continue
	fi

	RES="${TITLE//[^_]}"
	if [ ${#RES} -ge 2 ]; then
		echo " Skipping (file name is nonsense)"
		continue
	fi

	OLD_TITLE=$(ffprobe $INFILE 2>&1 | grep -B 4 "Duration" | grep title | cut -d " " -f 17-)

	# Season/Episode number handling
	echo ${TITLE} | grep -E -i "^S[0-9]+ E[0-9]+ \+ E[0-9]+ - " > /dev/null
	if [ "$?" == "0" ]; then
		TITLE=$(echo ${TITLE} | cut -d " " -f 6-)
	fi

	echo ${TITLE} | grep -E -i "^S[0-9]+ E[0-9]+ - |^S[0-9]+ ES[0-9]+ - " > /dev/null
	if [ "$?" == "0" ]; then
		TITLE=$(echo ${TITLE} | cut -d " " -f 4-)
	fi

	echo ${TITLE} | grep -E -i "^S[0-9]+E[0-9]+ - |^E[0-9]+ -|^[0-9]+ - " > /dev/null
	if [ "$?" == "0" ]; then
		TITLE=$(echo ${TITLE} | cut -d " " -f 3-)
	fi

	echo ${TITLE} | grep -E -i "^S[0-9]+E[0-9]+ " > /dev/null
	if [ "$?" == "0" ]; then
		TITLE=$(echo ${TITLE} | cut -d " " -f 2-)
	fi

	# Resolution handling
	echo ${TITLE} | grep -i " 4k HDR$" > /dev/null
	if [ "$?" == "0" ]; then
		TITLE="$(echo ${TITLE} | rev | cut -d " " -f 3- | rev)"
	fi

	echo ${TITLE} | grep -E -i " 480p| 720p$| 1080p$| 1440p| 4k$" > /dev/null
	if [ "$?" == "0" ]; then
		TITLE="$(echo ${TITLE} | rev | cut -d " " -f 2- | rev)"
	fi

	# Part handling
	echo ${TITLE} | grep -E -i "\- part [0-9]+$" > /dev/null
	if [ "$?" == "0" ]; then
		NAME=$(echo ${TITLE} | rev | cut -d " " -f 4- | rev)
		PNUM=$(echo ${TITLE} | grep -E -o -i "part [0-9]+$" | grep -E -o "[0-9]+$")
		TITLE="${NAME} (part ${PNUM})"
	fi


	echo ${TITLE} | grep -E -i "\- part i+$" > /dev/null
	if [ "$?" == "0" ]; then
		NAME=$(echo ${TITLE} | rev | cut -d " " -f 4- | rev)
		PSTR=$(echo ${TITLE} | grep -E -o -i "part i+$" | grep -E -o -i "i+$")
		TITLE="${NAME} (part ${#PSTR})"
	fi

	echo ${TITLE} | grep -E -i "part i+$" > /dev/null
	if [ "$?" == "0" ]; then
		NAME=$(echo ${TITLE} | rev | cut -d " " -f 3- | rev)
		PSTR=$(echo ${TITLE} | grep -E -o -i "part i+$" | grep -E -o -i "i+$")
		TITLE="${NAME} (part ${#PSTR})"
	fi

	if [[ ${OLD_TITLE} != ${TITLE} ]]; then
		echo -e "\nUpdating title of $INFILE from \"${OLD_TITLE}\" to \"${TITLE}\""
		mkvpropedit "${INFILE}" -e info -s title="${TITLE}" >/dev/null
	else
		echo " done"
	fi
done

IFS="$OLD_IFS"
