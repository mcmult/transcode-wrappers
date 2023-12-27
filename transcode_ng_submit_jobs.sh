#!/usr/bin/env bash

RAW_LOC="/mnt/media-raw"
FINAL_LOC="/mnt/media/staging"

module load slurm ffmpeg-tc

OLD_IFS="$IFS"
IFS=$'\n'

#fix_mkv_title dependency list
FIXUP_DEPEND=""

for INFILE in $(find "${RAW_LOC}" -type f \( -name *.raw* -a ! -path *exclude* \) | sort ); do
	JOB_NAME=$(basename $INFILE | sed 's/\.raw//' | sed 's/\ /_/g')
	SUBMIT=$(sbatch --job-name="${JOB_NAME}" /home/mcmult/transcode-wrappers/transcode_ng_sbatch.sh -f "${FINAL_LOC}" -l "${RAW_LOC}" -i "${INFILE}")
	JOB_ID=$(echo "${SUBMIT##* }")
	if [[ -z ${FIXUP_DEPEND} ]]; then
		FIXUP_DEPEND="afterany:${JOB_ID}"
	else
		FIXUP_DEPEND="${FIXUP_DEPEND},afterany:${JOB_ID}"
	fi
done

IFS="$OLD_IFS"

sbatch --ntasks=1 --cpus-per-task=1 --dependency=${FIXUP_DEPEND} /home/mcmult/transcode-wrappers/fix_mkv_title.sh "${FINAL_LOC}"
