#!/bin/bash
set -euo pipefail

IMAGE=$1
TAR=$2

# Reports go next to the build output (override with OUTDIR), so the whole
# pipeline works even when the repo itself is mounted read-only (e.g. Lima).
OUTDIR=${OUTDIR:-dist}
mkdir -p "$OUTDIR"
ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')

echo "[+] Generating SBOM for $IMAGE"
syft "$TAR" -o spdx-json > "${OUTDIR}/sbom-${ARTIFACT}.json"
