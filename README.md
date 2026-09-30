# reticulum-readygate

**Stop guessing when Reticulum is actually ready. Know it.**

`systemd`'s `After=`/`Requires=` only guarantee *start order* — not
*readiness*. If you run `rnsd` alongside NomadNet, `rngit`, or any other
RNS-based service on the same box, that gap is exactly why things
occasionally fail to start on boot, or need a manual restart after a
reboot, for no reproducible reason.

`reticulum-readygate` closes that gap with one small `systemd` oneshot
service that polls `rnstatus` until Reticulum is *actually* up — not just
launched — and gives every other service on the box a single, reliable
thing to depend on instead.

```
reticulum.service          (rnsd itself)
        |
        v
reticulum-ready.service    (this project — polls rnstatus until RNS is up)
        |
        v
   your other services     (nomadnet.service, rngit.service, etc.)
```

## Why not just `sleep 5`?

- **Fixes every start path** — boot, a manual `systemctl restart`, a full
  stack reload script — not just the one you remembered to add a delay to.
- **Fails loudly instead of guessing** — if `rnsd` genuinely doesn't come
  up, the gate times out and reports it, rather than starting dependents
  against a broken interface.
- **No wasted time** — `RemainAfterExit=yes` means the gate doesn't
  re-poll on every dependent's start; it only re-checks when explicitly
  restarted.
- **Hardware-aware** — works with slow-to-enumerate interfaces (LoRa/RNode
  over USB) by polling instead of assuming a fixed boot time.

## What's included

| File | Purpose |
|---|---|
| `reticulum.service` | Base unit for `rnsd` itself |
| `reticulum-ready.service` | The readiness gate — depend on this, not on `reticulum.service` |
| `wait-for-rns.sh` | Polls `rnstatus` until RNS is ready (or times out) |
| `example-nomadnet.service` | Example dependent service, showing the pattern |
| `example-rngit.service` | Another example dependent service ([rngit](https://github.com/) — Git over Reticulum) |
| `reloadstack.sh` | Restarts the whole stack in the correct order |
| `stopstack.sh` | Stops the whole stack in the correct order |
| `checkstack.sh` | Prints the status of every service in the stack |

## Quick start

1. Copy `wait-for-rns.sh` to somewhere on your service user's `PATH`
   (e.g. `~/.local/bin/`) and `chmod +x` it.
2. Copy `reticulum.service` and `reticulum-ready.service` to
   `/etc/systemd/system/`.
3. For each service that needs RNS to be ready, point its
   `After=`/`Requires=` at `reticulum-ready.service` (see
   `example-nomadnet.service` / `example-rngit.service`).
4. `sudo systemctl daemon-reload && sudo systemctl enable --now reticulum.service reticulum-ready.service <your services>`

See [`docs/walkthrough.md`](docs/walkthrough.md) for the full explanation,
troubleshooting tips, and notes on Python-environment path issues (e.g.
`pip install --break-system-packages`) that commonly bite this setup.

## Tested on

Ubuntu 24.04.4 LTS (systemd 255, Python 3.12). Should work unmodified on
any other systemd-based distro — adjust paths and package names as
needed.

## License

Public domain — released under [The Unlicense](https://unlicense.org). See
[`LICENSE`](LICENSE) for details.
