#!/bin/bash
# SPDX SBOM of a built archive. Usage: scripts/sbom.sh <image> <flavor> [arch]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

STEM=$(stem "${1:?usage: sbom.sh <image> <flavor> [arch]}" "${2:?}" "${3:-host}")
echo "[+] SBOM for $STEM"
syft "$OUTDIR/$STEM.tar" -q -o "spdx-json=$OUTDIR/sbom-$STEM.spdx.json"
