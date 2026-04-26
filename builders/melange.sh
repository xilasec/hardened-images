#!/bin/bash
set -euo pipefail

# Build all melange package configs into a local APK repository.
# Usage: ./builders/melange.sh [arch]
#
# Requires:
#   - melange installed
#   - MELANGE_SIGNING_KEY env var set to the path of the private key,
#     or melange/xilasec@hardned-images.rsa present for local development

ARCH=${1:-x86_64}
REPO_DIR="./packages"
KEY_FILE="${MELANGE_SIGNING_KEY:-melange/xilasec@hardned-images.rsa}"
PUB_KEY="melange/xilasec@hardned-images.rsa.pub"

if [ ! -f "$KEY_FILE" ]; then
  echo "[-] Signing key not found at $KEY_FILE"
  echo "    Generate one with: melange keygen melange/xilasec@hardned-images.rsa"
  echo "    Commit melange/xilasec@hardned-images.rsa.pub and store melange/xilasec@hardned-images.rsa as a CI secret."
  exit 1
fi

mkdir -p "$REPO_DIR"

for config in melange/*.yaml; do
  CONFIG_FILE="${config%.*}"
  PKG_NAME=$(yq -r '.package.name' $config)
  PKG_VER=$(yq -r '.package.version' $config)
  PKG_EPOCH=$(yq -r '.package.epoch' $config)

  APK_FILE="${REPO_DIR}/${ARCH}/${PKG_NAME}-${PKG_VER}-r${PKG_EPOCH}.apk"

  if [ -f "$APK_FILE" ]; then
    echo "[=] Skipping $PKG_NAME: $APK_FILE already exists."
    continue
  fi

  echo "[+] Building package: $PKG_NAME"
  melange build "$config" \
    --namespace xilasec \
    --source-dir "${CONFIG_FILE}/" \
    --arch "$ARCH" \
    --signing-key "$KEY_FILE" \
    --repository-append "$REPO_DIR" \
    --keyring-append "$PUB_KEY" \
    --out-dir "$REPO_DIR"
done

echo "[+] Local APK repository at $REPO_DIR"
