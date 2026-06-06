#!/bin/bash
set -euo pipefail

IMAGE=$1
DATE=${2:-$(date -u +%Y%m%d)}

# Where the OCI archive is written. Override with OUTDIR to build on a writable
# native filesystem - e.g. inside a Lima VM where the repo is mounted read-only:
#   OUTDIR=/var/tmp/dist WORKDIR=/var/tmp/work make build BUILD=...
OUTDIR=${OUTDIR:-dist}
mkdir -p "$OUTDIR"

case $IMAGE in
  alpine-*)
    CONFIG="images/alpine/${IMAGE#alpine-}.yaml"
    OUT="$OUTDIR/${IMAGE}.tar"
    TAG="ghcr.io/xilasec/${IMAGE}:${DATE}"
    # Only build local melange packages when the image actually consumes them
    # (i.e. references the @local repo). Images that use stock upstream packages
    # - like node24 - skip melange entirely, so they build faster and don't
    # require the melange signing key.
    if grep -q '@local' "$CONFIG"; then
      echo "[+] Building local packages with melange"
      ./builders/melange.sh
    fi
    echo "[+] Building $TAG"
    ./builders/alpine.sh "$CONFIG" "$OUT" "$TAG"
    ;;

  ubuntu-*)
    CONFIG="images/ubuntu/${IMAGE#ubuntu-}.yaml"
    OUT="$OUTDIR/${IMAGE}.tar"
    TAG="ghcr.io/xilasec/${IMAGE}:${DATE}"
    echo "[+] Building $TAG"
    ./builders/ubuntu.sh "$CONFIG" "$OUT" "$TAG"
    ;;

  *)
    echo "Unknown image type: $IMAGE"
    exit 1
    ;;
esac

# Both builders already write the OCI archive to $OUT themselves: apko writes it
# directly, and ubuntu.sh pushes it from buildah storage. The previous trailing
# `buildah push` here was redundant for ubuntu and broke the alpine path (apko
# images are never in buildah storage), so it's gone.
echo "[+] Build complete: $OUT"