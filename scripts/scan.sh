#!/bin/bash
# Scan a built archive with two independent scanners.
#
# Usage: scripts/scan.sh <image> <flavor> [arch]
#
#   grype  reads the syft SBOM (same inventory that gets attested)
#   trivy  reads the image archive with its own cataloger, so a package syft
#          misses is still seen by one scanner
#
# Both apply the OpenVEX documents for the locally built packages this image
# installs (vex/<package>.openvex.json). Gating happens in scripts/verify.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE=${1:?usage: scan.sh <image> <flavor> [arch]}
FLAVOR=${2:?}
STEM=$(stem "$IMAGE" "$FLAVOR" "${3:-host}")
TAR="$OUTDIR/$STEM.tar"
SBOM="$OUTDIR/sbom-$STEM.spdx.json"
GRYPE="$OUTDIR/grype-$STEM.json"
TRIVY="$OUTDIR/trivy-$STEM.json"
[ -f "$SBOM" ] || die "missing $SBOM (run scripts/sbom.sh first)"

export TRIVY_DISABLE_VEX_NOTICE=1
vex_args=()
for v in $(vex_files_of "$(image_config "$IMAGE" "$FLAVOR")"); do
  echo "[+] Applying VEX $v"
  vex_args+=(--vex "$v")
done

echo "[+] grype ($SBOM)"
grype "$SBOM" -q "${vex_args[@]}" -o table -o "json=$GRYPE"

echo "[+] trivy ($TAR)"
trivy image -q --input "$TAR" "${vex_args[@]}" --format json --output "$TRIVY"
trivy convert -q --format table "$TRIVY"

# Cross-check: which High/Critical findings each scanner reports.
g=$(jq -r '.matches[] | select(.vulnerability.severity|test("High|Critical")) | .vulnerability.id' "$GRYPE" | sort -u)
t=$(jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity|test("HIGH|CRITICAL")) | .VulnerabilityID' "$TRIVY" | sort -u)
both=$(comm -12 <(echo "$g") <(echo "$t") | grep . || true)
gonly=$(comm -23 <(echo "$g") <(echo "$t") | grep . || true)
tonly=$(comm -13 <(echo "$g") <(echo "$t") | grep . || true)
echo "[+] High/Critical cross-check"
echo "    both:       ${both:-none}" | tr '\n' ' '; echo
echo "    grype only: ${gonly:-none}" | tr '\n' ' '; echo
echo "    trivy only: ${tonly:-none}" | tr '\n' ' '; echo
