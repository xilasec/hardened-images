#!/bin/bash
# Load a built archive and run the image's functional test (images/<image>/test.sh).
#
# Usage: scripts/test.sh <image> <flavor> [arch]
# DOCKER overrides the container CLI (e.g. DOCKER="sudo docker"). Foreign
# architectures need binfmt/qemu on the host.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE=${1:?usage: test.sh <image> <flavor> [arch]}
FLAVOR=${2:?}
ARCH=${3:-host}
STEM=$(stem "$IMAGE" "$FLAVOR" "$ARCH")
export DOCKER=${DOCKER:-docker}
PLATFORM="linux/$(oci_arch "$ARCH")"
export PLATFORM

# Use the reference docker reports: apko tags single-arch archives with an
# -<arch> suffix (e.g. node24:musl-amd64).
out=$($DOCKER load -i "$OUTDIR/$STEM.tar")
REF=$(sed -n 's/^Loaded image[^:]*: //p' <<<"$out" | head -n1)
[ -n "$REF" ] || die "could not determine loaded image from: $out"
echo "[+] Testing $STEM ($REF, $PLATFORM)"

user=$($DOCKER image inspect --format '{{.Config.User}}' "$REF")
case "$user" in
  ""|root|0|0:*) die "image runs as root (User='$user')" ;;
esac

"images/$IMAGE/test.sh" "$REF"
