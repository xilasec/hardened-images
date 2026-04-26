#!/bin/bash
set -euo pipefail

IMAGE=$1
TAR=$2

ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')
SBOM="sbom-${ARTIFACT}.json"
SCAN_REPORT="scan-${ARTIFACT}.json"
TRIVY_REPORT="trivy-${ARTIFACT}.json"

# Reads the SBOM so it uses the same artifact inventory as the rest of the
# pipeline. Ubuntu OVAL / Alpine secdb are aware of backported patch versions,
# so this is the most accurate source for distro packages.
echo "[+] Scanning with grype (primary gate)"
GRYPE_EXIT=0
grype --config .grype.yaml "$SBOM" --fail-on critical -o table -o "json=${SCAN_REPORT}" || GRYPE_EXIT=$?

echo ""

# Scans the OCI archive directly so it runs its own cataloger independently
# of syft. Useful for catching things the SBOM might have missed and for
# cross-checking grype results.
echo "[+] Scanning with trivy (second opinion)"
trivy image \
  --input "$TAR" \
  --severity HIGH,CRITICAL \
  --format table \
  --exit-code 0 \
  --quiet

trivy image \
  --input "$TAR" \
  --severity HIGH,CRITICAL \
  --format json \
  --output "$TRIVY_REPORT" \
  --exit-code 0 \
  --quiet

echo ""

# Cross-scanner comparison
#
# Which scanner to trust:
#   CONFIRMED by both  → fix immediately; two independent DBs agree
#   grype-only         → likely real; grype uses distro OVAL so it knows
#                        backported patches, if it still fires, investigate
#   trivy-only         → investigate; may be a false positive because trivy
#                        used upstream NVD version range instead of distro data
#
# Suppressing melange-patched CVEs:
#   When you apply a patch via melange the version string stays the same
#   (e.g. busybox 1.37.0), so scanners will still flag it. Suppress these
#   explicitly and auditably:
#     .grype.yaml  → grype ignore list (with package name + reason)
#     .trivyignore → trivy ignore list (with reason comment)
echo "[+] Cross-scanner HIGH/CRITICAL comparison"

GRYPE_LIST=$(mktemp)
TRIVY_LIST=$(mktemp)
trap 'rm -f "$GRYPE_LIST" "$TRIVY_LIST"' EXIT

jq -r '
  .matches[]
  | select(.vulnerability.severity == "Critical" or .vulnerability.severity == "High")
  | .vulnerability.id
' "$SCAN_REPORT" 2>/dev/null | sort -u | grep -v '^$' > "$GRYPE_LIST" || true

jq -r '
  .Results[]?
  | .Vulnerabilities[]?
  | select(.Severity == "HIGH" or .Severity == "CRITICAL")
  | .VulnerabilityID
' "$TRIVY_REPORT" 2>/dev/null | sort -u | grep -v '^$' > "$TRIVY_LIST" || true

CONFIRMED="" ; GRYPE_ONLY="" ; TRIVY_ONLY=""

if [ -s "$GRYPE_LIST" ] && [ -s "$TRIVY_LIST" ]; then
  CONFIRMED=$(comm -12 "$GRYPE_LIST" "$TRIVY_LIST" || true)
  GRYPE_ONLY=$(comm -23 "$GRYPE_LIST" "$TRIVY_LIST" || true)
  TRIVY_ONLY=$(comm -13 "$GRYPE_LIST" "$TRIVY_LIST" || true)
elif [ -s "$GRYPE_LIST" ]; then
  GRYPE_ONLY=$(cat "$GRYPE_LIST")
elif [ -s "$TRIVY_LIST" ]; then
  TRIVY_ONLY=$(cat "$TRIVY_LIST")
fi

if [ -n "$CONFIRMED" ]; then
  echo "  CONFIRMED by both, fix these first:"
  echo "$CONFIRMED" | sed 's/^/    /'
else
  echo "  none confirmed by both scanners"
fi
[ -n "$GRYPE_ONLY" ] && { echo "  grype-only (likely real, check distro OVAL):"; echo "$GRYPE_ONLY" | sed 's/^/    /'; }
[ -n "$TRIVY_ONLY" ] && { echo "  trivy-only (investigate, may be distro-patched):"; echo "$TRIVY_ONLY" | sed 's/^/    /'; }

echo ""

# Gate on grype
if [ "$GRYPE_EXIT" -ne 0 ]; then
  echo "[-] Grype found CRITICAL CVEs, build failed"
  exit "$GRYPE_EXIT"
fi

echo "[+] Scan passed"
