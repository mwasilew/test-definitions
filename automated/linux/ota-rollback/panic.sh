#!/bin/sh

PANIC_COUNT=0

if [ -f /etc/panic.rollback ]; then
    # shellcheck source=/dev/null
    . /etc/panic.rollback
    echo "Current count: ${PANIC_COUNT}"
    if [ "${PANIC_COUNT}" -eq 3 ]; then
        exit 0
    fi
fi

sync
PANIC_COUNT=$((PANIC_COUNT+1))
echo "Creating /etc/panic.rollback file"
echo "PANIC_COUNT=${PANIC_COUNT}" > /etc/panic.rollback
sleep 2
sync
sysctl -w kernel.panic="0" && echo c > /proc/sysrq-trigger

