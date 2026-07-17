#!/bin/sh -x

# Verify that the system resumed from suspend without errors.
#
# Suspending the system and providing the wakeup source are out of scope:
# this script runs after the system is back up and only inspects what the
# kernel recorded about the cycle that already happened.
#
# Run pre-suspend-check.sh before the suspend to get a baseline. Without it
# this script still runs, but it cannot tell a resume from a reboot and falls
# back to the counter baselines given on the command line.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib

OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

# State recorded by pre-suspend-check.sh. Values found here win over the
# baselines below.
STATE_FILE="/tmp/pre-suspend-state.txt"
# Number of successful cycles recorded before the suspend under test. Cycles
# accumulate for the whole boot, so a caller that suspends more than once
# should pass the value read from /sys/power/suspend_stats/success beforehand.
BASELINE_SUCCESS="0"
# Number of failed cycles recorded before the suspend under test.
BASELINE_FAIL="0"
# Extended regexp of kernel messages treated as suspend/resume failures.
ERROR_PATTERN="PM: [Ss]uspend[- ].*(fail|abort)|Freezing of tasks failed|did not resume|failed to suspend|Call Trace|BUG:|WARNING:|Oops|kernel panic"

STATS_DIR="/sys/power/suspend_stats"
# Markers written by the kernel when a cycle starts and finishes. The second
# alternative in each covers kernels older than v4.15.
ENTRY_PATTERN="PM: suspend entry|PM: Syncing filesystems"
EXIT_PATTERN="PM: suspend exit|PM: Finishing wakeup|Restarting tasks.*done"

usage() {
    printf "Usage: %s \
        \n\t[-p <state file from pre-suspend-check.sh>] \
        \n\t[-b <successful cycles before suspend>] \
        \n\t[-f <failed cycles before suspend>] \
        \n\t[-e <error regexp>]" "$0" 1>&2
    exit 1
}

while getopts "p:b:f:e:" o; do
    case "$o" in
        p) STATE_FILE="${OPTARG}" ;;
        b) BASELINE_SUCCESS="${OPTARG}" ;;
        f) BASELINE_FAIL="${OPTARG}" ;;
        e) ERROR_PATTERN="${OPTARG}" ;;
        *) usage ;;
    esac
done

create_out_dir "${OUTPUT}"

# ---------------------------------------------------------------------------
# What was recorded before the suspend
# ---------------------------------------------------------------------------

# Read one KEY=VALUE from the state file. The file is parsed rather than
# sourced: it is written by another script and must not be able to run code.
get_state() {
    [ -r "${STATE_FILE}" ] || return 0
    grep -m1 "^$1=" "${STATE_FILE}" | cut -d= -f2-
}

PRE_DMESG_LINES=""
if [ -r "${STATE_FILE}" ]; then
    info_msg "Using pre-suspend state from ${STATE_FILE}:"
    cat "${STATE_FILE}"
    cp "${STATE_FILE}" "${OUTPUT}/" 2>/dev/null || true
    report_pass "pre-suspend-state-found"

    pre_boot_id="$(get_state BOOT_ID)"
    pre_uptime="$(get_state UPTIME)"
    pre_success="$(get_state SUSPEND_SUCCESS)"
    pre_fail="$(get_state SUSPEND_FAIL)"
    PRE_DMESG_LINES="$(get_state DMESG_LINES)"

    # A machine that rebooted is also "back up", and its counters and kernel
    # log start from scratch, which would otherwise read as a clean run.
    boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    if [ -z "${pre_boot_id}" ] || [ -z "${boot_id}" ]; then
        warn_msg "No boot_id to compare, cannot rule out a reboot"
        report_skip "resumed-without-reboot"
    elif [ "${pre_boot_id}" = "${boot_id}" ]; then
        report_pass "resumed-without-reboot"
    else
        warn_msg "boot_id changed: ${pre_boot_id} -> ${boot_id}"
        warn_msg "The machine rebooted, it did not resume from suspend"
        report_fail "resumed-without-reboot"
    fi

    # Counters are cumulative for the boot, so the recorded values are the
    # only baseline that is correct for repeated cycles.
    [ -n "${pre_success}" ] && BASELINE_SUCCESS="${pre_success}"
    [ -n "${pre_fail}" ] && BASELINE_FAIL="${pre_fail}"

    if [ -n "${pre_uptime}" ]; then
        now_uptime="$(awk '{printf "%d", $1}' /proc/uptime)"
        add_metric "time-since-pre-suspend-check" "pass" \
            "$((now_uptime - pre_uptime))" "seconds"
    fi
else
    warn_msg "${STATE_FILE} not found, run pre-suspend-check.sh before the suspend"
    warn_msg "Falling back to baselines success=${BASELINE_SUCCESS} fail=${BASELINE_FAIL}"
    report_skip "pre-suspend-state-found"
    report_skip "resumed-without-reboot"
fi

# ---------------------------------------------------------------------------
# What the kernel counted
# ---------------------------------------------------------------------------
if [ -d "${STATS_DIR}" ]; then
    report_pass "suspend-stats-available"
    cp -r "${STATS_DIR}" "${OUTPUT}/suspend_stats" 2>/dev/null || true

    success="$(cat "${STATS_DIR}/success")"
    fail="$(cat "${STATS_DIR}/fail")"
    info_msg "suspend_stats: success=${success} fail=${fail} (baseline ${BASELINE_SUCCESS}/${BASELINE_FAIL})"

    if [ "${success}" -gt "${BASELINE_SUCCESS}" ]; then
        report_pass "suspend-cycle-completed"
    else
        warn_msg "No new successful cycle recorded: success=${success}, baseline=${BASELINE_SUCCESS}"
        report_fail "suspend-cycle-completed"
    fi

    if [ "${fail}" -le "${BASELINE_FAIL}" ]; then
        report_pass "no-failed-suspend-cycle"
    else
        warn_msg "Failed cycles recorded: fail=${fail}, baseline=${BASELINE_FAIL}"
        warn_msg "Last failure: step=$(cat "${STATS_DIR}/last_failed_step") dev=$(cat "${STATS_DIR}/last_failed_dev") errno=$(cat "${STATS_DIR}/last_failed_errno")"
        report_fail "no-failed-suspend-cycle"
    fi

    # Per-phase counters, so a failure points at the phase that broke.
    for phase in freeze prepare suspend suspend_late suspend_noirq resume resume_early resume_noirq; do
        counter="${STATS_DIR}/failed_${phase}"
        [ -r "${counter}" ] || continue
        if [ "$(cat "${counter}")" -eq 0 ]; then
            report_pass "no-failures-in-${phase}"
        else
            warn_msg "failed_${phase}=$(cat "${counter}")"
            report_fail "no-failures-in-${phase}"
        fi
    done
else
    warn_msg "${STATS_DIR} not present, kernel built without CONFIG_PM_SLEEP_DEBUG?"
    report_skip "suspend-stats-available"
fi

# ---------------------------------------------------------------------------
# What the kernel logged
# ---------------------------------------------------------------------------
if ! dmesg > "${OUTPUT}/dmesg.log" 2>/dev/null; then
    warn_msg "Cannot read the kernel log, check kernel.dmesg_restrict"
    report_skip "resume-logged-in-kernel-log"
    report_skip "no-errors-during-resume"
    exit 0
fi

# Prefer the line count recorded before the suspend: it proves the messages
# below it were produced by the cycle under test. Without it, fall back to the
# most recent cycle the kernel logged, which is all this script can infer on
# its own since the suspend was triggered elsewhere.
start_line=""
if [ -n "${PRE_DMESG_LINES}" ]; then
    now_lines="$(wc -l < "${OUTPUT}/dmesg.log")"
    if [ "${now_lines}" -ge "${PRE_DMESG_LINES}" ]; then
        start_line="$((PRE_DMESG_LINES + 1))"
    else
        # Fewer lines than before means the ring buffer wrapped or was
        # cleared, so the recorded offset now points at unrelated messages.
        warn_msg "Kernel log shrank (${PRE_DMESG_LINES} -> ${now_lines} lines), ignoring the recorded offset"
    fi
fi

if [ -n "${start_line}" ]; then
    tail -n +"${start_line}" "${OUTPUT}/dmesg.log" > "${OUTPUT}/dmesg-resume.log"
    # The entry must appear after the pre-suspend check ran, otherwise the
    # only suspend in the log predates the cycle we are verifying.
    if grep -qE "${ENTRY_PATTERN}" "${OUTPUT}/dmesg-resume.log"; then
        report_pass "suspend-entered-after-pre-suspend-check"
    else
        warn_msg "No suspend entry logged since the pre-suspend check, the machine may never have suspended"
        report_fail "suspend-entered-after-pre-suspend-check"
    fi
else
    report_skip "suspend-entered-after-pre-suspend-check"
    start_line="$(grep -nE "${ENTRY_PATTERN}" "${OUTPUT}/dmesg.log" | tail -1 | cut -d: -f1)"
    if [ -z "${start_line}" ]; then
        warn_msg "No suspend entry found in the kernel log"
        warn_msg "The system may not have suspended, or the log ring buffer wrapped"
        report_fail "resume-logged-in-kernel-log"
        report_skip "no-errors-during-resume"
        exit 0
    fi
    tail -n +"${start_line}" "${OUTPUT}/dmesg.log" > "${OUTPUT}/dmesg-resume.log"
fi

if grep -qE "${EXIT_PATTERN}" "${OUTPUT}/dmesg-resume.log"; then
    report_pass "resume-logged-in-kernel-log"
else
    warn_msg "No suspend exit logged for the cycle under test"
    report_fail "resume-logged-in-kernel-log"
fi

if grep -qE "${ERROR_PATTERN}" "${OUTPUT}/dmesg-resume.log"; then
    warn_msg "Errors found in the kernel log for the last suspend/resume cycle:"
    grep -E "${ERROR_PATTERN}" "${OUTPUT}/dmesg-resume.log"
    report_fail "no-errors-during-resume"
else
    report_pass "no-errors-during-resume"
fi

# exit with return code 0 to help LAVA parse results
exit 0
