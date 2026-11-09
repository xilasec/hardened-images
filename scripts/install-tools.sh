#!/bin/bash
# Install pinned, checksum-verified tool binaries (amd64 + arm64).
#
# Usage: scripts/install-tools.sh <tool>...   (apko melange syft grype trivy opa dockle cosign)
# BIN_DIR defaults to /usr/local/bin (uses sudo when not writable).
#
# Bumping a tool: change its version and both sha256 values below, taken from
# the release's published checksums file.
set -euo pipefail

BIN_DIR=${BIN_DIR:-/usr/local/bin}
case "$(uname -m)" in
  x86_64) A=amd64 ;;
  aarch64|arm64) A=arm64 ;;
  *) echo "[-] unsupported host arch $(uname -m)"; exit 1 ;;
esac

# tool | version | amd64 sha256 | arm64 sha256
PINS="
apko    1.2.7   5151b4a79e9a7fd495d5f7591cb25293b747bc9e4eb5929643ba80701bfa8153 801c75d114e40b9aff08bd26342f02a5081e590c1445aaff22bcf3f3b5760ffc
melange 0.50.3  aa64af564fd8fc50ed251d83c2b00ee5a9d9c159cb5f722c0af975b337bf0a85 4f89887c01347aa58b4dd6009c5b79b84f7396acb71d25e9451afba7e59f669e
syft    1.42.3  0d6be741479eddd2c8644a288990c04f3df0d609bbc1599a005532a9dff63509 dc630590c953347789d08f8ebf57c7d8094db89100785fcd94b1cddeac791804
grype   0.110.0 aaa98d27d2d7efd9317c6a1ad6d9b15f3e65bab320e7d03bde41e251387bb71c 804041ee69f119022e3e866741a558eae6f2df372a5dc1a5376d456d16f8c931
trivy   0.70.0  8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9 2f6bb988b553a1bbac6bdd1ce890f5e412439564e17522b88a4541b4f364fc8d
opa     1.15.0  8193ccebcfc99ea7fe2e6a3a0d9e1eda94a64cf151f8a5473fe709b1395abf60 7a0b129fd53e6a3bbd3854e8f942977662e14045836967452ae563673f268db4
dockle  0.4.15  8bfc9183d1d3d67800edb45bea4bb63ddf1d28bec5f89944075a07007d79caad 14c2fbcd675afaa0f1717e97ab71eee178dabdef676066189f49bad0f53b8762
cosign  3.0.5   db15cc99e6e4837daabab023742aaddc3841ce57f193d11b7c3e06c8003642b2 d098f3168ae4b3aa70b4ca78947329b953272b487727d1722cb3cb098a1a20ab
"

url_of() {
  local t=$1 v=$2
  case "$t" in
    apko|melange) echo "https://github.com/chainguard-dev/$t/releases/download/v$v/${t}_${v}_linux_$A.tar.gz" ;;
    syft|grype) echo "https://github.com/anchore/$t/releases/download/v$v/${t}_${v}_linux_$A.tar.gz" ;;
    trivy) local ta=64bit; [ "$A" = arm64 ] && ta=ARM64
           echo "https://github.com/aquasecurity/trivy/releases/download/v$v/trivy_${v}_Linux-$ta.tar.gz" ;;
    dockle) local da=64bit; [ "$A" = arm64 ] && da=ARM64
            echo "https://github.com/goodwithtech/dockle/releases/download/v$v/dockle_${v}_Linux-$da.tar.gz" ;;
    opa) echo "https://github.com/open-policy-agent/opa/releases/download/v$v/opa_linux_${A}_static" ;;
    cosign) echo "https://github.com/sigstore/cosign/releases/download/v$v/cosign-linux-$A" ;;
  esac
}

SUDO=""
[ -w "$BIN_DIR" ] || SUDO=sudo
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for tool in "$@"; do
  line=$(awk -v t="$tool" '$1 == t' <<<"$PINS")
  [ -n "$line" ] || { echo "[-] unknown tool '$tool'"; exit 1; }
  read -r _ ver sha_amd64 sha_arm64 <<<"$line"
  sha=$sha_amd64; [ "$A" = arm64 ] && sha=$sha_arm64
  url=$(url_of "$tool" "$ver")
  echo "[+] $tool $ver ($A)"
  curl -sfL "$url" -o "$TMP/dl"
  echo "$sha  $TMP/dl" | sha256sum -c --quiet -
  if [[ $url == *.tar.gz ]]; then
    mkdir -p "$TMP/x" && tar -xzf "$TMP/dl" -C "$TMP/x"
    bin=$(find "$TMP/x" -type f -name "$tool" | head -n1)
    [ -n "$bin" ] || { echo "[-] $tool binary not found in archive"; exit 1; }
  else
    bin="$TMP/dl"
  fi
  $SUDO install -m 0755 "$bin" "$BIN_DIR/$tool"
  rm -rf "$TMP/x" "$TMP/dl"
done
