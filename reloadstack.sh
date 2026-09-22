#!/bin/bash
# Restarts the full Reticulum service stack in the correct order:
# reticulum.service -> reticulum-ready.service (readiness gate) -> dependents.
#
# Edit DEPENDENTS below to match the services you've configured to
# depend on reticulum-ready.service.

DEPENDENTS=(nomadnet.service rngit.service)
SERVICES=(reticulum.service reticulum-ready.service "${DEPENDENTS[@]}")

echo "[1/3] Restarting reticulum.service..."
sudo systemctl restart reticulum.service

echo "[2/3] Waiting for RNS to become ready (up to 60s)..."
if sudo systemctl restart reticulum-ready.service; then
    echo "RNS is ready."
else
    echo "ERROR: reticulum-ready.service failed — RNS did not come up in time."
    echo "Check: sudo journalctl -u reticulum-ready.service -u reticulum.service -n 30"
    exit 1
fi

echo "[3/3] Restarting dependent services..."
sudo systemctl restart "${DEPENDENTS[@]}"

echo ""
echo "Reload complete. Status:"
for svc in "${SERVICES[@]}"; do
    STATUS="$(systemctl is-active "$svc")"
    printf "%-25s %s\n" "$svc" "$STATUS"
done
