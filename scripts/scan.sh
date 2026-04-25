#!/bin/bash
set -euo pipefail

IMAGE=$1

ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')
SBOM="sbom-${ARTIFACT}.json"
SCAN_REPORT="scan-${ARTIFACT}.json"

echo "[+] Scanning $IMAGE"
grype "$SBOM" -o json --fail-on critical | tee "$SCAN_REPORT"
