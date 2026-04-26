#!/bin/bash
set -euo pipefail

CONFIG=$1
OUT=$2
TAG=$3

rm -rf "$OUT"

apko build "$CONFIG" "$TAG" "$OUT"

echo "Executing podman to tag images"
LOADED_TAG=$(sudo podman load < "$OUT" | grep "Loaded image:" | sed 's/^Loaded image: //p' | head -n 1)
echo "Detected loaded tag: $LOADED_TAG"
echo "Target tag: $TAG"
if [ -z "$LOADED_TAG" ]; then
    echo "Erro: Podman não carregou nada."
    exit 1
fi

if [ "$LOADED_TAG" != "$TAG" ]; then
  sudo podman tag "$LOADED_TAG" "$TAG"
  echo "Retagged $LOADED_TAG to $TAG"
fi