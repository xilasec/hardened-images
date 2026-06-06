#!/bin/bash
set -euo pipefail

IMAGE=$1

OUTDIR=${OUTDIR:-dist}
ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')
SCAN_REPORT="${OUTDIR}/scan-${ARTIFACT}.json"
TRIVY_REPORT="${OUTDIR}/trivy-${ARTIFACT}.json"

echo "[+] Running policy checks against $SCAN_REPORT"

RESULT=$(opa eval \
  --input "$SCAN_REPORT" \
  --data policies \
  --format raw \
  "data.policies.vuln.allow")

if [ "$RESULT" != "true" ]; then
  echo "[-] Policy check FAILED | violations:"
  opa eval \
    --input "$SCAN_REPORT" \
    --data policies \
    --format pretty \
    "data.policies.vuln.violation"
  exit 1
fi

echo "[+] Running policy checks against ${TRIVY_REPORT}"

RESULT=$(opa eval \
  --input "${TRIVY_REPORT}" \
  --data policies \
  --format raw \
  "data.policies.vuln.allow")

if [ "$RESULT" != "true" ]; then
  echo "[-] Policy check FAILED | violations:"
  opa eval \
    --input "${TRIVY_REPORT}" \
    --data policies \
    --format pretty \
    "data.policies.vuln.violation"
  exit 1
fi


echo "[+] Policy check PASSED"
