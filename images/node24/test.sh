#!/bin/bash
# shellcheck disable=SC2086 # $RUN holds several docker flags
# Functional test for node24.
# Usage: test.sh <image-ref> (DOCKER, PLATFORM and RUN come from scripts/test.sh)
set -euo pipefail
REF=$1
D=${DOCKER:-docker}
node() { $D $RUN -e HOME=/tmp "$REF" "$@"; }

ver=$(node --version)
[[ $ver == v24.* ]] || { echo "[-] expected node v24.x, got '$ver'"; exit 1; }
# TLS stack and the CA bundle load; crypto works.
node -e 'require("tls"); require("crypto").createHash("sha256").update("x").digest("hex")' \
  || { echo "[-] node crypto/tls failed"; exit 1; }
# Runtime image: no package manager.
if $D $RUN --entrypoint /usr/bin/npm "$REF" --version >/dev/null 2>&1; then
  echo "[-] npm must not ship in the runtime image"; exit 1
fi
echo "[+] node24: node $ver, crypto/tls OK, no npm"
