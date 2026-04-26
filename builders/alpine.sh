#!/bin/bash
set -euo pipefail

CONFIG=$1
OUT=$2
TAG=$3

rm -rf "$OUT"

apko build "$CONFIG" "$TAG" "$OUT"

LOADED_TAG=$(sudo podman load < "$OUT" | sed -n 's/^Loaded image: //p')
if [ -n "$LOADED_TAG" ] && [ "$LOADED_TAG" != "$TAG" ]; then
  sudo podman tag "$LOADED_TAG" "$TAG"
fi
