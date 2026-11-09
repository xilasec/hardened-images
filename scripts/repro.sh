#!/bin/bash
# Reproducibility gate: rebuild with an empty package cache and require the
# exact same manifest digest as scripts/build.sh produced.
#
# Usage: scripts/repro.sh <image> <flavor> [arch]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE=${1:?usage: repro.sh <image> <flavor> [arch]}
FLAVOR=${2:?usage: repro.sh <image> <flavor> [arch]}
ARCH=$(apk_arch "${3:-host}")
STEM=$(stem "$IMAGE" "$FLAVOR" "$ARCH")
FIRST=$(cat "$OUTDIR/$STEM.digest" 2>/dev/null) || die "build $STEM first"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUTDIR="$TMP/out" APKO_CACHE_DIR="$TMP/cache" scripts/build.sh "$IMAGE" "$FLAVOR" "$ARCH" >/dev/null
SECOND=$(cat "$TMP/out/$STEM.digest")

if [ "$FIRST" != "$SECOND" ]; then
  die "$STEM is not reproducible: $FIRST != $SECOND"
fi
echo "[+] $STEM reproducible: $FIRST"
