#!/bin/bash
# Polls rnstatus until Reticulum is actually ready. If rnsd is running but
# never becomes ready, kills it so systemd restarts it, then waits again.
# Exists because systemd's After=/Requires= only guarantee that rnsd
# has been *launched*, not that it has finished initializing its
# interfaces. Dependent services should wait on this gate instead of
# on reticulum.service directly.
#
# Readiness = rnstatus exits 0. Without a shared instance it exits 1
# (printing "No shared RNS instance available to get status from" on
# current RNS, "Could not get RNS status" on old releases), so the exit
# code is checked instead of the message text.
#
# Recovery: rnsd can start and then hang without exiting (seen at boot,
# when it started the instant the network came up). systemd's Restart=
# only acts when the process exits, so a hung rnsd stays "active" forever
# and everything behind this gate stays down. After each timeout the gate
# sends SIGKILL to rnsd's main process; Restart=on-failure (or always)
# then starts a fresh rnsd and the gate waits again. This needs no sudo:
# the gate runs as the same user as rnsd. A killed-and-restarted rnsd does
# not stop this gate or its dependents (only an explicit stop/restart of
# reticulum.service does).
#
# Settings (environment, e.g. Environment= lines in reticulum-ready.service):
#   RNSTATUS            rnstatus to run       (default ~/.local/bin/rnstatus)
#   RNS_UNIT            rnsd's systemd unit   (default reticulum.service)
#   RNS_READY_TRIES     checks per wait, 2 s apart (default 30, about 60 s+)
#   RNS_READY_RESTARTS  rnsd restarts before giving up (default 2, 0 = never)

RNSTATUS="${RNSTATUS:-$HOME/.local/bin/rnstatus}"
UNIT="${RNS_UNIT:-reticulum.service}"
MAX_TRIES="${RNS_READY_TRIES:-30}"
MAX_RESTARTS="${RNS_READY_RESTARTS:-2}"

wait_ready() {
    local tries=0
    while [ "$tries" -lt "$MAX_TRIES" ]; do
        if "$RNSTATUS" >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 2
    done
    return 1
}

restarts=0
while true; do
    if wait_ready; then
        [ "$restarts" -gt 0 ] && echo "RNS is ready after $restarts rnsd restart(s)"
        exit 0
    fi
    if [ "$restarts" -ge "$MAX_RESTARTS" ]; then
        echo "Timed out waiting for RNS to become ready" >&2
        exit 1
    fi
    restarts=$((restarts + 1))
    pid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        echo "RNS not ready; rnsd (pid $pid) looks hung - killing it so systemd restarts it ($restarts/$MAX_RESTARTS)" >&2
        kill -KILL "$pid" 2>/dev/null ||
            echo "Could not signal rnsd pid $pid (does the gate run as rnsd's user?)" >&2
    else
        echo "RNS not ready and $UNIT has no running process; waiting again ($restarts/$MAX_RESTARTS)" >&2
    fi
    sleep 5   # give systemd time to start the new rnsd
done
