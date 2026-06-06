#!/bin/bash
set -euo pipefail

IMAGE=$1

OUTDIR=${OUTDIR:-dist}
ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')
IMAGE_NAME=$(echo "${IMAGE##*/}" | cut -d: -f1)
# Both builders already write a docker-archive tar that dockle reads directly,
# so there's no buildah-storage round-trip (which never worked for apko images,
# as those are never imported into buildah storage).
TAR="${OUTDIR}/${IMAGE_NAME}.tar"
REPORT="${OUTDIR}/compliance-${ARTIFACT}.json"

echo "[+] Running CIS compliance check for $IMAGE ($TAR)"
dockle \
  --exit-code 1 \
  --exit-level warn \
  --format json \
  --accept-key DKL-LI-0001 \
  --accept-key CIS-DI-0005 \
  --accept-key CIS-DI-0006 \
  --input "$TAR" | tee "$REPORT"
# DKL-LI-0001: no /etc/shadow is intentional - scratch-built minimal images have no
#              password-based auth; the absence of the file is more secure than a locked one.
# CIS-DI-0005: Docker Content Trust is Docker-daemon-specific; we sign with cosign
#              (Sigstore keyless) which is stronger and not daemon-dependent.
# CIS-DI-0006: HEALTHCHECK belongs to the application image layer, not the base image.
#              Consuming teams add it when they build on top of this golden base.

echo "[+] Compliance check PASSED"
