#!/bin/bash -e
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2021 Foundries.io Ltd.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
MOUNTPOINT=sysroot

usage() {
	echo "\
	Usage: $0
		     [-m <sysroot>]

	-m <sysroot>
		This is the name of the mountpoint to be tested.
	"
}

while getopts "m:" opts; do
	case "$opts" in
		m) MOUNTPOINT="${OPTARG}";
		   ;;
		h|*) usage ; exit 1 ;;
	esac
done

create_out_dir "${OUTPUT}"
INODES=$(df --output=itotal,size,target | grep "$MOUNTPOINT" | xargs echo -n | cut -d " " -f 1)
echo "Inodes: $INODES"
BLOCKS=$(df --output=itotal,size,target | grep "$MOUNTPOINT" | xargs echo -n | cut -d " " -f 2)
echo "1k Blocks: $BLOCKS"
DISK_SIZE=$(lsblk -b | grep "$MOUNTPOINT" | xargs echo -n | cut -d " " -f 4)
echo "Disk Size (bytes): $DISK_SIZE"
# Subtract inode table and fs size from disk size. Result should be withing 1%

RESULT=$(echo "${DISK_SIZE}-(${INODES}*256)-(${BLOCKS}*1024) > ${DISK_SIZE}*0.01"|bc)
# shellcheck disable=SC2086
if [ $RESULT ]; then
    report_pass "disk-resize-test"
else
    report_fail "disk-resize-test"
fi
