#!/bin/bash
# Stops the full Reticulum service stack in the correct order:
# dependents first, then the readiness gate, then reticulum.service.
#
# Edit DEPENDENTS below to match the services you've configured to
# depend on reticulum-ready.service.

DEPENDENTS=(nomadnet.service rngit.service)
SERVICES=(reticulum.service reticulum-ready.service "${DEPENDENTS[@]}")

echo "Stopping Reticulum stack..."
sudo systemctl stop "${DEPENDENTS[@]}" reticulum-ready.service reticulum.service

echo "Stop script completed. Checking status..."
for svc in "${SERVICES[@]}"; do
    STATUS="$(systemctl is-active "$svc")"
    printf "%-25s %s\n" "$svc" "$STATUS"
done
