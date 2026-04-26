#!/bin/bash
set -euo pipefail

IMAGE=$1

ARTIFACT=$(echo "${IMAGE##*/}" | tr ':' '-')
IMAGE_NAME=$(echo "${IMAGE##*/}" | cut -d: -f1)
DOCKER_TAR="dist/${IMAGE_NAME}-docker.tar"
REPORT="compliance-${ARTIFACT}.json"

if command -v fuse-overlayfs &>/dev/null && [ -c /dev/fuse ]; then
  BSTORE=(--storage-driver overlay --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs)
else
  BSTORE=(--storage-driver vfs)
fi

echo "[+] Converting OCI archive to Docker format for dockle"
sudo buildah "${BSTORE[@]}" push "$IMAGE" "docker-archive:${DOCKER_TAR}"

echo "[+] Running CIS compliance check for $IMAGE"
dockle \
  --exit-code 1 \
  --exit-level warn \
  --format json \
  --accept-key DKL-LI-0001 \
  --accept-key CIS-DI-0005 \
  --accept-key CIS-DI-0006 \
  --input "$DOCKER_TAR" | tee "$REPORT"
# DKL-LI-0001: no /etc/shadow is intentional - scratch-built minimal images have no
#              password-based auth; the absence of the file is more secure than a locked one.
# CIS-DI-0005: Docker Content Trust is Docker-daemon-specific; we sign with cosign
#              (Sigstore keyless) which is stronger and not daemon-dependent.
# CIS-DI-0006: HEALTHCHECK belongs to the application image layer, not the base image.
#              Consuming teams add it when they build on top of this golden base.

sudo rm -f "$DOCKER_TAR"
echo "[+] Compliance check PASSED"
