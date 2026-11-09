#!/bin/bash
# Build one image flavor for one architecture from its lockfile.
#
# Usage: scripts/build.sh <image> <flavor> [arch]
#
# Output: $OUTDIR/<image>-<flavor>-<arch>.tar (docker-loadable) and
#         $OUTDIR/<image>-<flavor>-<arch>.digest (manifest digest). The digest
#         is what scan/test results are bound to; publish refuses to push
#         anything whose digest differs.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE=${1:?usage: build.sh <image> <flavor> [arch]}
FLAVOR=${2:?usage: build.sh <image> <flavor> [arch]}
ARCH=$(apk_arch "${3:-host}")
check_flavor "$FLAVOR"
CFG=$(image_config "$IMAGE" "$FLAVOR")
LOCK=$(image_lock "$IMAGE" "$FLAVOR")
[ -f "$LOCK" ] || die "missing $LOCK (run scripts/lock.sh $IMAGE $FLAVOR)"

STEM=$(stem "$IMAGE" "$FLAVOR" "$ARCH")
mkdir -p "$OUTDIR"
TAR="$OUTDIR/$STEM.tar"
rm -f "$TAR"

echo "[+] Building $REGISTRY/$IMAGE:$FLAVOR ($ARCH) from $LOCK"
# --sbom=false: the SBOM of record is produced by syft from this archive
# (scripts/sbom.sh) and attested at publish time.
apko build --sbom=false --lockfile "$LOCK" --arch "$ARCH" \
  ${APKO_CACHE_DIR:+--cache-dir "$APKO_CACHE_DIR"} \
  "$CFG" "$REGISTRY/$IMAGE:$FLAVOR" "$TAR"

archive_manifest_digest "$TAR" > "$OUTDIR/$STEM.digest"
echo "[+] $TAR $(cat "$OUTDIR/$STEM.digest")"
