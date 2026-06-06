#!/bin/bash
set -euo pipefail

# Functional smoke test for a built image.
#
# Both builders emit a docker-archive tar (apko natively; the ubuntu builder via
# `buildah push docker-archive`), so we load it straight into Docker - the
# runtime preinstalled on GitHub's ubuntu-latest runner, so this mirrors how the
# image is actually run - and assert that:
#   * it is configured to run as a non-root user
#   * `node --version` runs and matches the expected major line
#   * `npm --version` runs
#
# Usage: ./scripts/smoke.sh <docker-archive.tar> <tag> [expected-node-version-prefix]

TAR=$1
TAG=${2:-}   # informational; the real ref comes from `docker load`
EXPECT=${3:-}

echo "[+] Loading $TAR into Docker"
LOAD_OUT=$(sudo docker load -i "$TAR")
echo "$LOAD_OUT"

# Resolve the reference docker actually loaded. apko tags single-arch images
# with an -<arch> suffix, so we trust docker's output rather than the passed tag.
REF=$(printf '%s\n' "$LOAD_OUT" | sed -n 's/^Loaded image: //p' | head -n1)
[ -z "$REF" ] && REF=$(printf '%s\n' "$LOAD_OUT" | sed -n 's/^Loaded image ID: //p' | head -n1)
if [ -z "$REF" ]; then
  echo "[-] Could not determine the loaded image reference"; exit 1
fi
echo "[+] Loaded: $REF"

echo "[+] Image is configured to run as a non-root user"
# apko emits the uid ("1000") while buildah may emit the name ("appuser"), so
# assert "not root" rather than an exact value.
IMG_USER=$(sudo docker inspect --format '{{.Config.User}}' "$REF")
echo "    User: ${IMG_USER:-<root>}"
case "${IMG_USER:-}" in
  ""|root|0)
    echo "[-] Expected the image to run as a non-root user, got '${IMG_USER:-<root>}'"
    exit 1
    ;;
esac

echo "[+] node --version"
NODE_VER=$(sudo docker run --rm --entrypoint /usr/bin/node "$REF" --version)
echo "    $NODE_VER"
if [ -n "$EXPECT" ] && [[ "$NODE_VER" != ${EXPECT}* ]]; then
  echo "[-] Expected node version to start with '${EXPECT}', got '${NODE_VER}'"
  exit 1
fi

echo "[+] npm --version"
NPM_VER=$(sudo docker run --rm -e HOME=/tmp --entrypoint /usr/bin/npm "$REF" --version)
echo "    npm ${NPM_VER}"

echo "[+] Smoke test PASSED: ${REF}"
