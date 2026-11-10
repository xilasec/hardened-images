#!/bin/bash
# Scan a built archive.
#
# Usage: scripts/scan.sh <image> <flavor> [arch]
#
#   grype  on the syft SBOM (the inventory that gets attested)
#   trivy  on the archive, with its own cataloger
#   grype  again with the other distro's advisories, for packages we build
#          ourselves: their versions are newer than the distro's, so the
#          distro's own advisories never match them
#
# All apply vex/. Gating happens in scripts/verify.sh.
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
XDISTRO="$OUTDIR/grype-xdistro-$STEM.json"
[ -f "$SBOM" ] || die "missing $SBOM (run scripts/sbom.sh first)"
rm -f "$XDISTRO"

export TRIVY_DISABLE_VEX_NOTICE=1
vex_args=()
for v in $(vex_files); do
  echo "[+] Applying VEX $v"
  vex_args+=(--vex "$v")
done

echo "[+] grype ($SBOM)"
grype "$SBOM" -q "${vex_args[@]}" -o table -o "json=$GRYPE"

echo "[+] trivy ($TAR)"
trivy image -q --input "$TAR" "${vex_args[@]}" --format json --output "$TRIVY"
trivy convert -q --format table "$TRIVY"

own=$(for r in $(recipes_for_flavor "$FLAVOR"); do recipe_provides "melange/$r.yaml"; done | jq -R . | jq -sc .)
if [ "$own" != "[]" ]; then
  case "$FLAVOR" in
    musl) other=wolfi:rolling ;;
    glibc) other="alpine:$(flavor_repositories musl | grep -oE 'v[0-9]+\.[0-9]+' | head -n1 | tr -d v)" ;;
  esac
  echo "[+] grype with $other advisories for our own packages"
  grype "$SBOM" -q --distro "$other" "${vex_args[@]}" -o json \
    | jq --argjson own "$own" '.matches |= map(select(.artifact.name | IN($own[])))' > "$XDISTRO"
  jq -r '.matches[] | "    \(.vulnerability.id) \(.vulnerability.severity) \(.artifact.name)@\(.artifact.version)"' "$XDISTRO"
fi

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
