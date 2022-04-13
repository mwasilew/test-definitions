#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2021 Foundries.io Ltd.

# shellcheck disable=SC1091
. ./sh-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
TYPE="kernel"
UBOOT_VAR_TOOL=fw_printenv
export UBOOT_VAR_TOOL

usage() {
    echo "\
    Usage: $0 [-type <kernel|uboot>]

    -t <kernel|uboot>
        This determines type of corruption test
        performed:
        kernel: corrupt OTA updated kernel binary
        uboot: corrupt OTA updated u-boot binary
    -u <u-boot variable read tool>
        Set the name of the tool to read u-boot variables
        On the unsecured systems it will usually be
        fw_printenv. On secured systems it might be
        fiovb_printenv
    "
}

while getopts "t:u:h" opts; do
    case "$opts" in
        t) TYPE="${OPTARG}";;
        u) UBOOT_VAR_TOOL="${OPTARG}";;
        h|*) usage ; exit 1 ;;
    esac
done

! check_root && error_msg "You need to be root to run this script."
create_out_dir "${OUTPUT}"

ref_bootcount_after_upgrade=1
ref_rollback_after_upgrade=0
ref_bootupgrade_available_after_upgrade=0
ref_upgrade_available_after_upgrade=0
ref_fiovb_is_secondary_boot_after_upgrade=0

# check u-boot variables to ensure rollback happend
bootcount_after_rollback=$(uboot_variable_value bootcount)
compare_test_value "bootcount_after_upgrade" "${ref_bootcount_after_upgrade}" "${bootcount_after_upgrade}"
rollback_after_upgrade=$(uboot_variable_value rollback)
compare_test_value "upgrade_after_upgrade" "${ref_rollback_after_upgrade}" "${rollback_after_upgrade}"
upgrade_available_after_upgrade=$(uboot_variable_value upgrade_available)
compare_test_value "upgrade_available_after_upgrade" "${ref_upgrade_available_after_upgrade}" "${upgrade_available_after_upgrade}"
if [ -f /usr/lib/firmware/version.txt ]; then
    . /usr/lib/firmware/version.txt
    bootupgrade_available_after_upgrade=$(uboot_variable_value bootupgrade_available)
    compare_test_value "bootupgrade_available_after_upgrade" "${ref_bootupgrade_available_after_upgrade}" "${bootupgrade_available_after_upgrade}"

    # shellcheck disable=SC2154
    ref_bootfirmware_version_after_upgrade="${bootfirmware_version}"
    bootfirmware_version_after_upgrade=$(uboot_variable_value bootfirmware_version)
    # shellcheck disable=SC2154
    compare_test_value "bootfirmware_version_after_upgrade" "${ref_bootfirmware_version_after_upgrade}" "${bootfirmware_version_after_upgrade}"
    fiovb_is_secondary_boot_after_upgrade=$(uboot_variable_value fiovb.is_secondary_boot)
    compare_test_value "fiovb_is_secondary_boot_after_upgrade" "${ref_fiovb_is_secondary_boot_after_upgrade}" "${fiovb_is_secondary_boot_after_upgrade}"
else
    report_skip "bootupgrade_available_after_upgrade"
    report_skip "bootfirmware_version_after_upgrade"
    report_skip "fiovb_is_secondary_boot_after_upgrade"
fi
# for now ignore /etc/os-release
cat /etc/os-release
cat /boot/loader/uEnv.txt
