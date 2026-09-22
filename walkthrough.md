# Running Multiple Services on a Reticulum Node with systemd

This walkthrough shows how to reliably run several interdependent services on
top of a Reticulum (RNS) node — for example NomadNet, `rngit`, or any other
LXMF/RNS-based service — without hitting startup race conditions on boot or
restart.

Tested and optimized for **Ubuntu 24.04.4 LTS** (systemd 255, Python 3.12).
The same approach will work on other systemd-based distros, but paths and
package names may differ slightly.

## The problem this solves

If you just point your other services at `reticulum.service` with a normal
`After=`/`Requires=`, you'll eventually run into this:

> systemd's `After=` and `Requires=` directives only guarantee **start
> order**, not **readiness**.

For a service with the default `Type=simple`, systemd considers
`reticulum.service` "started" the instant it forks and execs `rnsd` — not
once `rnsd` has actually finished initializing its interfaces and is ready
to accept connections. So any service that depends directly on
`reticulum.service` can start a split-second before RNS is actually usable.
This shows up as:

- Dependent services occasionally failing to start on boot
- Having to manually restart individual services after a reboot or a full
  stack restart
- Intermittent, hard-to-reproduce failures that "go away" if you just
  restart things again

The fix is to stop trusting process-launch order and add an explicit
**readiness gate** that systemd itself waits on.

## Overview of the setup

```
reticulum.service          (rnsd itself)
        |
        v
reticulum-ready.service    (oneshot gate — polls rnstatus until RNS is truly up)
        |
        v
   your other services     (nomadnet.service, rngit.service, etc.)
```

Every service that needs RNS to be ready points its `After=`/`Requires=` at
`reticulum-ready.service` instead of at `reticulum.service` directly. This
one change fixes the race for **every** start path — boot, a manual
`systemctl restart`, or a full stack reload script — not just the path your
own scripts happen to control.

## 1. Prerequisites

- Ubuntu 24.04.4 LTS with systemd
- Python 3.12 (Ubuntu 24.04's default `python3`)
- RNS (`rns`), and whatever RNS-based services you're running (e.g.
  `nomadnetwork`, `rngit`), installed for a **dedicated non-root service
  user** — do not run this stack as root
- `rnsd`, `rnstatus`, and your services' executables available on that
  user's `PATH` (typically `~/.local/bin/` after a `pip install --user`)

Throughout this guide, replace `svcuser` with whatever user you actually run
the stack as, and adjust `/home/svcuser/.local/bin/...` paths to match where
your tools actually live (check with `which rnsd`, `which rnstatus`, etc.,
run *as that user*).

## 2. Locate your actual install paths

Every path in this bundle (`/home/svcuser/.local/bin/rnsd`, etc.) is a
**placeholder based on the common case**. Don't assume it matches your
system — especially if any package was installed with
`pip install ... --break-system-packages`.

`--break-system-packages` simply tells pip to bypass Ubuntu/Debian's
"externally managed environment" protection. It does **not** pin down
*where* things get installed — that still depends on how the command was
run (as your normal user, with `sudo`, inside an active virtualenv, etc.).
Depending on that, you could end up with executables in `~/.local/bin`,
`/usr/local/bin`, `/usr/bin`, or a venv's `bin/` directory — or, if you've
run the install more than one way over time, more than one copy of the
same package on the same machine.

**Find where each executable actually landed:**
```bash
which rnsd rnstatus nomadnet rngit
```

If `which` comes up empty for something, it may only be reachable inside a
venv, or it may sit in `~/.local/bin` while you're checking from a `sudo`
shell that doesn't have that directory on `PATH`. Try:
```bash
find / -xdev -iname "rnsd" -type f 2>/dev/null
find / -xdev -iname "rngit" -type f 2>/dev/null
```

**Check which Python interpreter each one actually uses** (the shebang line
on the first line of the script tells you):
```bash
head -1 "$(which rnsd)"
```
`#!/usr/bin/python3` means it's using the system Python (typically the
result of an install run with `sudo ... --break-system-packages`).
`#!/home/svcuser/.local/bin/python3` or a path containing `venv` means it's
using a user install or a virtualenv — and that interpreter needs to still
exist at that exact path when the service runs.

You can also check where the underlying Python *packages* (not just the
command-line scripts) were installed:
```bash
pip show rns
pip show nomadnetwork
pip show rngit
```
The `Location:` line in the output tells you which `site-packages` (or
`dist-packages`) directory pip used.

### Does it matter that systemd uses a different environment than your shell?

Yes — this is one of the most common reasons a service "works fine when I
run it by hand" but fails, or silently uses the wrong version, under
systemd. Two separate things are going on:

1. **`ExecStart=` doesn't go through your shell.** systemd doesn't read
   `~/.bashrc` or `~/.profile`, doesn't activate any virtualenv, and uses a
   minimal default `PATH` (typically
   `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) that
   does **not** include `~/.local/bin`. This is exactly why every
   `ExecStart=` line in this bundle uses a full absolute path (e.g.
   `/home/svcuser/.local/bin/rnsd`) instead of a bare command name — always
   do this in unit files, regardless of how you installed things.

2. **Mixed installs (system vs. user vs. venv) can silently diverge.** If
   you've installed the same package more than one way over time — once
   with `sudo --break-system-packages`, once without, once inside a venv —
   you can end up with multiple independent copies, each with its own
   version and its own set of dependencies. Whichever one the resolved
   `which`/`find` path points to is the one that actually runs under
   systemd, and it may not be the one you most recently updated by hand.

**Practical fix**: run the `which`/`head -1`/`pip show` commands above
*as the same user the service runs as* (`sudo -u svcuser which rnsd`, for
example — running it as yourself while the service runs as another user is
a common source of "but it works for me" confusion), then use the exact
resulting path in `ExecStart=` for every unit file — don't assume this
bundle's placeholder paths are correct for your install.

## 3. Set up the base Reticulum service

`reticulum.service` (included in this bundle) runs `rnsd` itself:

```ini
[Unit]
Description=Reticulum Network Stack daemon (rnsd)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=svcuser
ExecStart=/home/svcuser/.local/bin/rnsd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Notes:
- `After=`/`Wants=network-online.target` (rather than the weaker
  `network.target`) matters if any of your Reticulum interfaces are
  network-based (TCP, I2P, etc.) — it ensures the network is actually up,
  not just that networking services have started.
- `Restart=on-failure` with `RestartSec=5` lets `rnsd` self-heal if it
  crashes or fails to bind cleanly, instead of staying down.

## 4. Add the readiness gate

This is the key piece. It's a `Type=oneshot` service with
`RemainAfterExit=yes`, so systemd only considers it "active" once the wait
script inside it exits successfully — and it *stays* active (without
re-running) until the gate is explicitly restarted or `reticulum.service`
goes down and drags it along.

**`reticulum-ready.service`:**
```ini
[Unit]
Description=Wait for Reticulum (rnsd) to be ready
After=reticulum.service
Requires=reticulum.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=svcuser
ExecStart=/home/svcuser/.local/bin/wait-for-rns.sh

[Install]
WantedBy=multi-user.target
```

**`wait-for-rns.sh`** (place at `/home/svcuser/.local/bin/wait-for-rns.sh`
and `chmod +x` it):
```bash
#!/bin/bash
TRIES=0
MAX_TRIES=30   # 30 * 2s = 60s timeout

while true; do
    OUTPUT="$(/home/svcuser/.local/bin/rnstatus 2>/dev/null)"
    if [ "$OUTPUT" != "Could not get RNS status" ] && [ -n "$OUTPUT" ]; then
        exit 0
    fi
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "Timed out waiting for RNS to become ready" >&2
        exit 1
    fi
    sleep 2
done
```

The script polls `rnstatus` every 2 seconds for up to 60 seconds. As soon as
`rnstatus` returns real output (rather than the "Could not get RNS status"
error it gives before RNS is up), the script exits 0 and the gate goes
"active." If RNS never comes up within the timeout, the gate fails loudly
instead of hanging forever — so a genuinely broken `rnsd` shows up clearly
in `systemctl status` rather than silently blocking everything downstream.

Adjust `MAX_TRIES` if your interfaces (especially LoRa/RNode hardware) take
longer than a minute to come online.

## 5. Point your other services at the gate

For **every** service that needs RNS to be ready, use
`After=reticulum-ready.service` / `Requires=reticulum-ready.service`
instead of targeting `reticulum.service` directly. Two examples are
included in this bundle:

**`example-nomadnet.service`:**
```ini
[Unit]
Description=Nomad Network Service
After=reticulum-ready.service
Requires=reticulum-ready.service

[Service]
ExecStart=/home/svcuser/.local/bin/nomadnet -d
Restart=always
User=svcuser

[Install]
WantedBy=default.target
```

**`example-rngit.service`:**
```ini
[Unit]
Description=rngit - Git over Reticulum node
After=reticulum-ready.service
Requires=reticulum-ready.service

[Service]
Type=simple
ExecStart=/home/svcuser/.local/bin/rngit -s
Restart=always
User=svcuser

[Install]
WantedBy=multi-user.target
```

Copy this pattern for any additional service you add later — a forwarding
bot, a notification script, another LXMF-based tool, whatever. Rename the
file, point `ExecStart=` at your service's binary, keep the
`After=`/`Requires=reticulum-ready.service` lines as-is.

## 6. Install everything

```bash
# Wait script
chmod +x wait-for-rns.sh
cp wait-for-rns.sh /home/svcuser/.local/bin/wait-for-rns.sh

# Unit files (rename example-*.service to match your actual services first)
sudo cp reticulum.service reticulum-ready.service example-nomadnet.service example-rngit.service /etc/systemd/system/
# e.g.: sudo mv /etc/systemd/system/example-nomadnet.service /etc/systemd/system/nomadnet.service

sudo systemctl daemon-reload
sudo systemctl enable reticulum.service reticulum-ready.service nomadnet.service rngit.service
```

## 7. Manage the stack with the included scripts

Three helper scripts are included, each with a `DEPENDENTS` array at the top
you edit to list your own services:

- **`reloadstack.sh`** — restarts `reticulum.service`, waits for the
  readiness gate, then restarts every dependent. Fails loudly (and tells
  you where to look) if RNS doesn't come up in time, instead of restarting
  dependents against a broken RNS.
- **`stopstack.sh`** — stops dependents first, then the gate, then
  `reticulum.service` — avoiding services with `Restart=always` trying to
  bounce back up mid-shutdown.
- **`checkstack.sh`** — prints each service's name next to its
  `active`/`inactive`/`failed` status, in stack order, for a quick glance.

```bash
chmod +x reloadstack.sh stopstack.sh checkstack.sh
```

Sample `checkstack.sh` output once everything is edited and running:
```
reticulum.service         active
reticulum-ready.service   active
nomadnet.service          active
rngit.service             active
```

## 8. Why this is worth the extra service

It's tempting to just add a `sleep 5` before starting dependents and call it
done. The gate approach is more robust because:

- It fixes **every** start path (boot, manual restart, your own scripts) —
  a `sleep` in one script only helps when that script is the one doing the
  restarting.
- It fails explicitly on a timeout rather than guessing a fixed delay that
  might be too short on a slow boot (e.g. LoRa hardware enumerating) or
  needlessly long on a fast one.
- `RemainAfterExit=yes` means the gate doesn't re-run its poll loop on every
  dependent's start — it only re-checks readiness when the gate itself is
  restarted, keeping subsequent service starts fast.

## Troubleshooting

- **A dependent fails to start even with the gate in place**: check the
  gate's own logs first — `sudo journalctl -u reticulum-ready.service -n 30`
  — to see whether it actually reported success.
- **The gate times out**: increase `MAX_TRIES` in `wait-for-rns.sh`,
  especially if you're using LoRa/RNode hardware interfaces that take a
  while to enumerate over USB.
- **Restarting the full stack still shows stale statuses**: make sure your
  reload script restarts `reticulum-ready.service` itself, not just
  `reticulum.service` — since it's `RemainAfterExit=yes`, its status won't
  refresh unless you explicitly restart it.
- **A service fails under systemd with "command not found" or an import
  error, but runs fine when you launch it by hand**: this is almost always
  the `ExecStart=` path pointing at the wrong Python environment. Re-check
  section 2 — confirm the exact executable path and its shebang line as the
  actual service user (`sudo -u svcuser which ...`), and make sure
  `ExecStart=` uses that full path rather than a bare command name.
