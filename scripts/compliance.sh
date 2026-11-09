#!/bin/bash
# CIS image checks with dockle. Usage: scripts/compliance.sh <image> <flavor> [arch]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

STEM=$(stem "${1:?usage: compliance.sh <image> <flavor> [arch]}" "${2:?}" "${3:-host}")
REPORT="$OUTDIR/dockle-$STEM.json"
echo "[+] dockle $STEM"
# Fails on WARN and above. The remaining INFO findings are expected for base
# images: CIS-DI-0005 (Docker Content Trust; images are cosign-signed instead)
# and CIS-DI-0006 (HEALTHCHECK belongs to the application image).
rc=0
dockle --exit-code 1 --exit-level warn --format json --output "$REPORT" \
  --input "$OUTDIR/$STEM.tar" || rc=$?
jq -r '.details[]? | "    " + .level + " " + .code + ": " + .title + " (" + (.alerts | join("; ")) + ")"' "$REPORT"
[ "$rc" -eq 0 ] || die "compliance failed for $STEM"
echo "[+] compliance passed"
