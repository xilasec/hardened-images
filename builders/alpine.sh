#!/bin/bash
set -euo pipefail

CONFIG=$1
OUT=$2
TAG=$3

apko build "$CONFIG" "$TAG" "$OUT"

docker load < "$OUT"
docker tag $(tar tf "$OUT" | head -1 | cut -d/ -f1) "$TAG"