# reticulum-readygate
A systemd oneshot service that polls rnstatus until Reticulum is actually ready — not just launched — so NomadNet, rngit, and other RNS-based services on the same box stop failing to start on boot or needing manual restarts after reboot.
