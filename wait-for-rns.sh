#!/bin/bash
# Polls rnstatus until Reticulum is actually ready, or times out.
# Exists because systemd's After=/Requires= only guarantee that rnsd
# has been *launched*, not that it has finished initializing its
# interfaces. Dependent services should wait on this gate instead of
# on reticulum.service directly.
#
# Readiness = rnstatus exits 0. Without a shared instance it exits 1
# (printing "No shared RNS instance available to get status from" on
# current RNS, "Could not get RNS status" on old releases), so the exit
# code is checked instead of the message text.

TRIES=0
MAX_TRIES=30   # 30 * 2s = 60s timeout

while true; do
    if /home/svcuser/.local/bin/rnstatus >/dev/null 2>&1; then
        exit 0
    fi
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "Timed out waiting for RNS to become ready" >&2
        exit 1
    fi
    sleep 2
done
