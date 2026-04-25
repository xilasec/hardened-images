#!/bin/bash
set -euo pipefail

IMAGE=$1

echo "[+] Signing $IMAGE"
cosign sign "$IMAGE"

echo "[+] Attesting SLSA build provenance"
PREDICATE=$(cat <<EOF
{
  "buildType": "https://github.com/xilasec/hardened-images/build/v1",
  "builder": {
    "id": "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-xilasec/hardened-images}"
  },
  "invocation": {
    "configSource": {
      "uri": "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-xilasec/hardened-images}",
      "digest": {"sha1": "${GITHUB_SHA:-unknown}"},
      "entryPoint": "${GITHUB_WORKFLOW:-local}"
    }
  },
  "metadata": {
    "buildStartedOn": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "completeness": {
      "parameters": true,
      "environment": false,
      "materials": false
    },
    "reproducible": false
  }
}
EOF
)

echo "$PREDICATE" | cosign attest \
  --predicate - \
  --type slsaprovenance \
  "$IMAGE"

echo "[+] Signed and attested: $IMAGE"
