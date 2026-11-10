#!/bin/bash
# Policy gate (policies/vulnerability.rego) over both scanner reports.
# Usage: scripts/verify.sh <image> <flavor> [arch]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

STEM=$(stem "${1:?usage: verify.sh <image> <flavor> [arch]}" "${2:?}" "${3:-host}")
rc=0
for report in "$OUTDIR/grype-$STEM.json" "$OUTDIR/trivy-$STEM.json"; do
  [ -f "$report" ] || die "missing $report (run scripts/scan.sh first)"
  result=$(opa eval --input "$report" --data policies --format json 'data.policies.vuln')
  allow=$(jq -r '.result[0].expressions[0].value.allow' <<<"$result")
  jq -r '.result[0].expressions[0].value.warning[]? | "    warning: " + .' <<<"$result"
  if [ "$allow" = true ]; then
    echo "[+] policy passed: $report"
  else
    echo "[-] policy failed: $report"
    jq -r '.result[0].expressions[0].value.violation[]? | "    " + .' <<<"$result"
    rc=1
  fi
done
exit $rc
