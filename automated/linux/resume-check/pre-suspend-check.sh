#!/bin/sh -x

# Record the state of the machine before it is suspended, so that
# resume-check.sh can tell afterwards whether a suspend/resume cycle really
# happened and whether it introduced any errors.
#
# This script does not suspend the machine. Run it, then trigger the suspend
# by whatever means the job uses, then run resume-check.sh once the machine
# is back up.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib

OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

# Kept out of the test directory so that resume-check.sh can read it even when
# it runs from a different action. /tmp is tmpfs on most images, so the file
# does not survive a reboot, which is what we want: state from a previous boot
# must never look like a valid baseline.
STATE_FILE="/tmp/pre-suspend-state.txt"
# When set, check that this sleep mode is offered by /sys/power/state.
SLEEP_MODE=""

STATS_DIR="/sys/power/suspend_stats"

usage() {
    printf "Usage: %s \
        \n\t[-p <state file>] \
        \n\t[-m <mem|freeze|standby|disk>]" "$0" 1>&2
    exit 1
}

while getopts "p:m:" o; do
    case "$o" in
        p) STATE_FILE="${OPTARG}" ;;
        m) SLEEP_MODE="${OPTARG}" ;;
        *) usage ;;
    esac
done

create_out_dir "${OUTPUT}"

# ---------------------------------------------------------------------------
# Is the machine in a state where a suspend can be expected to work?
# ---------------------------------------------------------------------------
if [ -r "/sys/power/state" ]; then
    info_msg "Sleep states offered: $(cat /sys/power/state)"
    report_pass "kernel-supports-suspend"
else
    warn_msg "/sys/power/state is missing, kernel has no suspend support"
    report_fail "kernel-supports-suspend"
fi

if [ -n "${SLEEP_MODE}" ]; then
    if grep -qw "${SLEEP_MODE}" /sys/power/state 2>/dev/null; then
        report_pass "sleep-mode-${SLEEP_MODE}-supported"
    else
        warn_msg "${SLEEP_MODE} not offered by /sys/power/state"
        report_fail "sleep-mode-${SLEEP_MODE}-supported"
    fi
fi

# ---------------------------------------------------------------------------
# Collect the baseline
# ---------------------------------------------------------------------------

# Identifies the running kernel instance. If this changes by the time
# resume-check.sh runs, the machine rebooted instead of resuming.
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
if [ -z "${boot_id}" ]; then
    warn_msg "Cannot read boot_id, a reboot will not be distinguishable from a resume"
    report_skip "boot-id-recorded"
else
    report_pass "boot-id-recorded"
fi

if [ -d "${STATS_DIR}" ]; then
    suspend_success="$(cat "${STATS_DIR}/success")"
    suspend_fail="$(cat "${STATS_DIR}/fail")"
    info_msg "suspend_stats baseline: success=${suspend_success} fail=${suspend_fail}"
    report_pass "suspend-stats-available"
else
    # The counters are cumulative for the boot. Leaving these empty tells
    # resume-check.sh it has no baseline rather than making it assume zero.
    suspend_success=""
    suspend_fail=""
    warn_msg "${STATS_DIR} not present, no cycle counters to baseline"
    report_skip "suspend-stats-available"
fi

# Number of kernel log lines already present. resume-check.sh scans only the
# lines added after this point, so nothing logged before the suspend can be
# mistaken for a resume error.
if dmesg > "${OUTPUT}/dmesg-pre-suspend.log" 2>/dev/null; then
    dmesg_lines="$(wc -l < "${OUTPUT}/dmesg-pre-suspend.log")"
    report_pass "kernel-log-readable"
else
    dmesg_lines=""
    warn_msg "Cannot read the kernel log, check kernel.dmesg_restrict"
    report_skip "kernel-log-readable"
fi

uptime_seconds="$(awk '{printf "%d", $1}' /proc/uptime)"

# ---------------------------------------------------------------------------
# Save it
# ---------------------------------------------------------------------------
rm -f "${STATE_FILE}"
{
    echo "BOOT_ID=${boot_id}"
    echo "UPTIME=${uptime_seconds}"
    echo "SUSPEND_SUCCESS=${suspend_success}"
    echo "SUSPEND_FAIL=${suspend_fail}"
    echo "DMESG_LINES=${dmesg_lines}"
} > "${STATE_FILE}"

if [ -s "${STATE_FILE}" ]; then
    info_msg "Pre-suspend state saved to ${STATE_FILE}:"
    cat "${STATE_FILE}"
    cp "${STATE_FILE}" "${OUTPUT}/" 2>/dev/null || true
    report_pass "pre-suspend-state-saved"
else
    warn_msg "Failed to write ${STATE_FILE}"
    report_fail "pre-suspend-state-saved"
fi

# exit with return code 0 to help LAVA parse results
exit 0
