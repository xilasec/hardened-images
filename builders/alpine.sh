#!/bin/bash
set -euo pipefail

CONFIG=$1
OUT=$2
TAG=$3

rm -rf $OUT

apko build "$CONFIG" "$TAG" "$OUT"

# apko appends the build arch to the tag (e.g. :20260426-amd64).
# Capture what podman actually loaded and re-tag to the expected name.
LOADED_TAG=$(sudo podman load < "$OUT" | sed -n 's/^Loaded image: //p')
if [ "$LOADED_TAG" != "$TAG" ]; then
  sudo podman tag "$LOADED_TAG" "$TAG"
fi
