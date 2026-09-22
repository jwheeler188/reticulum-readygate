#!/bin/bash
# Prints the status of every service in the Reticulum stack.
#
# Edit DEPENDENTS below to match the services you've configured to
# depend on reticulum-ready.service.

DEPENDENTS=(nomadnet.service rngit.service)
SERVICES=(reticulum.service reticulum-ready.service "${DEPENDENTS[@]}")

for svc in "${SERVICES[@]}"; do
    STATUS="$(systemctl is-active "$svc")"
    printf "%-25s %s\n" "$svc" "$STATUS"
done
