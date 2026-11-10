#!/bin/bash
# OCI conformance, ELF hardening (scripts/harden.sh) and CIS checks (dockle).
# Usage: scripts/compliance.sh <image> <flavor> [arch]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

STEM=$(stem "${1:?usage: compliance.sh <image> <flavor> [arch]}" "${2:?}" "${3:-host}")
TAR="$OUTDIR/$STEM.tar"

# OCI media types only (no Docker v2 types), standard annotations present.
m=$(tar -xOf "$TAR" index.json | jq -r '.manifests[0].digest')
oci=$(tar -xOf "$TAR" "$m" | jq -r '
  [ (.mediaType == "application/vnd.oci.image.manifest.v1+json"),
    (.config.mediaType == "application/vnd.oci.image.config.v1+json"),
    (all(.layers[]; .mediaType | startswith("application/vnd.oci.image.layer.v1.tar"))),
    (.annotations["org.opencontainers.image.title"] // "" | length > 0),
    (.annotations["org.opencontainers.image.source"] // "" | length > 0),
    (.annotations["org.opencontainers.image.created"] // "" | length > 0) ] | all')
[ "$oci" = true ] || die "$STEM is not an OCI image with standard annotations"
echo "[+] OCI media types and annotations OK"

scripts/harden.sh "$@"

REPORT="$OUTDIR/dockle-$STEM.json"
echo "[+] dockle $STEM"
# Fails on WARN and above. The remaining INFO findings are expected for base
# images: CIS-DI-0005 (Docker Content Trust; images are cosign-signed instead)
# and CIS-DI-0006 (HEALTHCHECK belongs to the application image).
rc=0
dockle --exit-code 1 --exit-level warn --format json --output "$REPORT" \
  --input "$TAR" || rc=$?
jq -r '.details[]? | "    " + .level + " " + .code + ": " + .title + " (" + (.alerts | join("; ")) + ")"' "$REPORT"
[ "$rc" -eq 0 ] || die "compliance failed for $STEM"
echo "[+] compliance passed"
