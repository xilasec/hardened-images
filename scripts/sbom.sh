#!/bin/bash
set -euo pipefail

IMAGE=$1
TAR=$2

ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')

echo "[+] Generating SBOM for $IMAGE"
syft "$TAR" -o spdx-json > "sbom-${ARTIFACT}.json"
