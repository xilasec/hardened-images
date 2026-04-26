#!/bin/bash
set -euo pipefail

IMAGE=$1
DATE=${2:-$(date -u +%Y%m%d)}

mkdir -p dist

case $IMAGE in
  alpine-*)
    CONFIG="images/alpine/${IMAGE#alpine-}.yaml"
    OUT="dist/${IMAGE}.tar"
    TAG="ghcr.io/xilasec/${IMAGE}:${DATE}"
    echo "[+] Building packages with melange"
    ./builders/melange.sh
    echo "[+] Building $TAG"
    ./builders/alpine.sh "$CONFIG" "$OUT" "$TAG"
    ;;

  ubuntu-*)
    CONFIG="images/ubuntu/${IMAGE#ubuntu-}.yaml"
    OUT="dist/${IMAGE}.tar"
    TAG="ghcr.io/xilasec/${IMAGE}:${DATE}"
    echo "[+] Building $TAG"
    ./builders/ubuntu.sh "$CONFIG" "$OUT" "$TAG"
    ;;

  *)
    echo "Unknown image type: $IMAGE"
    exit 1
    ;;
esac

# if command -v fuse-overlayfs &>/dev/null && [ -c /dev/fuse ]; then
#   BSTORE=(--storage-driver overlay --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs)
# else
#   BSTORE=(--storage-driver vfs)
# fi
# sudo buildah "${BSTORE[@]}" tag "$TAG" "ghcr.io/xilasec/${IMAGE}:latest"
# echo "[+] Built: $TAG"
