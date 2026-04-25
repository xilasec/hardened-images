#!/bin/bash
set -euo pipefail

IMAGE=$1

ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')
REPORT="compliance-${ARTIFACT}.json"

echo "[+] Running CIS compliance check for $IMAGE"

dockle \
  --exit-code 1 \
  --exit-level warn \
  --format json \
  "$IMAGE" | tee "$REPORT"

echo "[+] Compliance check PASSED — report: $REPORT"
