#!/bin/bash
set -euo pipefail

CONFIG=$1
OUT=$2
TAG=$3

rm -rf "$OUT"

apko build "$CONFIG" "$TAG" "$OUT"

echo "Executing podman to tag images"
LOAD_OUTPUT=$(sudo podman load < "$OUT")
echo "Debug Load Output: $LOAD_OUTPUT"

LOADED_TAG=$(echo "$LOAD_OUTPUT" | grep -oE 'Loaded image(s)?: \S+' | awk '{print $NF}')

if [ -n "$LOADED_TAG" ]; then
  sudo podman tag "$LOADED_TAG" "$TAG"
else
  echo "Error Idk what happend."
  exit 1
fi
