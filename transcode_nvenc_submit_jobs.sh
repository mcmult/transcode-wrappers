#!/usr/bin/env bash

RAW_LOC="/data/videos-raw"
HDR="no"

module load slurm/20.11

OLD_IFS="$IFS"
IFS=$'\n'

for INFILE in $(find "${RAW_LOC}" -type f \( -name *.raw* -a ! -path *exclude* \)); do
	JOB_NAME=$(basename $INFILE | sed 's/\.raw//' | sed 's/\ /_/g')
	sbatch --job-name="${JOB_NAME}" /home/mcmult/transcode-wrappers/transcode_nvenc_sbatch.sh ${INFILE} ${HDR}
done

IFS="$OLD_IFS"
