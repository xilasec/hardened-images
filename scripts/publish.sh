#!/bin/bash
# Publish one image flavor as a multi-arch index, bound to the tested digests.
#
# Usage:
#   scripts/publish.sh push    <image> <flavor>   # push + verify + sign + attest
#   scripts/publish.sh promote <image> <flavor> <index-digest>
#
# push expects, for every arch of the flavor, the $OUTDIR/<stem>.digest and
# SBOM produced by the build job after all gates passed. It
#   1. skips when $REGISTRY/<image>:<flavor> already serves exactly those
#      per-arch digests (nothing changed),
#   2. rebuilds the multi-arch index from the same lockfile and refuses to
#      continue unless every per-arch digest equals the tested one,
#   3. pushes it with `apko publish` under the dated tag <flavor>-YYYYMMDD and
#      checks the registry serves that exact index (pushed == scanned ==
#      tested),
#   4. cosign-signs the index and its manifests (keyless) and attests each
#      arch's SBOM plus the image's VEX documents.
# The moving <flavor> tag is only updated by `promote`, after the workflow has
# attached build provenance, so it never points at an unsigned image.
#
# SIGN=false skips step 4 (local registries without OIDC).
# TLS_VERIFY=false allows plain-HTTP registries (e.g. localhost:5000).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

CMD=${1:?usage: publish.sh push|promote <image> <flavor> [digest]}
IMAGE=${2:?}
FLAVOR=${3:?}
check_flavor "$FLAVOR"
REPO="$REGISTRY/$IMAGE"
SIGN=${SIGN:-true}
TLS_VERIFY=${TLS_VERIFY:-true}

output() {
  echo "    $1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

# "<oci-arch> <digest>" lines for an index reference, sorted.
index_manifests() {
  skopeo inspect --tls-verify="$TLS_VERIFY" --raw "docker://$1" \
    | jq -r '.manifests[] | "\(.platform.architecture) \(.digest)"' | sort
}

case "$CMD" in
  push)
    CFG=$(image_config "$IMAGE" "$FLAVOR")
    LOCK=$(image_lock "$IMAGE" "$FLAVOR")
    tested=""
    for arch in $(flavor_archs "$FLAVOR"); do
      s=$(stem "$IMAGE" "$FLAVOR" "$arch")
      [ -f "$OUTDIR/$s.digest" ] || die "no tested digest for $s: its build job did not pass"
      tested+="$(oci_arch "$arch") $(cat "$OUTDIR/$s.digest")"$'\n'
    done
    tested=$(sort <<<"$tested" | grep .)

    current=$(index_manifests "$REPO:$FLAVOR" 2>/dev/null || true)
    if [ "$current" = "$tested" ]; then
      echo "[=] $REPO:$FLAVOR already serves the tested digests; nothing to publish"
      output "published=false"
      exit 0
    fi

    # Build the multi-arch index locally first and compare it with the tested
    # digests, so nothing unverified ever reaches the registry.
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    DATE_TAG="$FLAVOR-$(date -u +%Y%m%d)"
    apko build --sbom=false --lockfile "$LOCK" --cache-dir "$TMP/cache" \
      "$CFG" "$REPO:$DATE_TAG" "$TMP/index.tar" >/dev/null
    tar -xOf "$TMP/index.tar" index.json > "$TMP/index.json"
    built=$(jq -r '.manifests[] | "\(.platform.architecture) \(.digest)"' "$TMP/index.json" | sort)
    if [ "$built" != "$tested" ]; then
      printf '[-] rebuilt manifests differ from the tested ones\n tested:\n%s\n rebuilt:\n%s\n' "$tested" "$built" >&2
      die "refusing to publish $REPO:$FLAVOR"
    fi
    INDEX_DIGEST="sha256:$(sha256sum < "$TMP/index.json" | cut -d' ' -f1)"
    echo "[+] Rebuilt index $INDEX_DIGEST matches the tested digests"

    echo "[+] Publishing $REPO:$DATE_TAG"
    ref=$(apko publish --sbom=false --lockfile "$LOCK" "$CFG" "$REPO:$DATE_TAG" | tail -n1)
    [ "${ref##*@}" = "$INDEX_DIGEST" ] || die "apko publish pushed '$ref', expected $INDEX_DIGEST"
    pushed=$(index_manifests "$REPO@$INDEX_DIGEST")
    [ "$pushed" = "$tested" ] || die "registry serves different manifests for $REPO@$INDEX_DIGEST"
    echo "[+] Pushed digests match tested digests"

    if [ "$SIGN" = true ]; then
      echo "[+] Signing $REPO@$INDEX_DIGEST (index + manifests)"
      cosign sign --yes --recursive "$REPO@$INDEX_DIGEST"
      for arch in $(flavor_archs "$FLAVOR"); do
        s=$(stem "$IMAGE" "$FLAVOR" "$arch")
        echo "[+] Attesting SBOM for $arch"
        cosign attest --yes --type spdxjson --predicate "$OUTDIR/sbom-$s.spdx.json" \
          "$REPO@$(cat "$OUTDIR/$s.digest")"
      done
      for v in $(vex_files_of "$CFG"); do
        echo "[+] Attesting $v"
        cosign attest --yes --type openvex --predicate "$v" "$REPO@$INDEX_DIGEST"
      done
    else
      echo "[!] SIGN=false: not signing or attesting"
    fi

    output "published=true"
    output "repository=$REPO"
    output "digest=$INDEX_DIGEST"
    output "tag=$DATE_TAG"
    ;;

  promote)
    DIGEST=${4:?usage: publish.sh promote <image> <flavor> <index-digest>}
    echo "[+] Tagging $REPO@$DIGEST as $FLAVOR"
    skopeo copy --all --preserve-digests \
      --src-tls-verify="$TLS_VERIFY" --dest-tls-verify="$TLS_VERIFY" \
      "docker://$REPO@$DIGEST" "docker://$REPO:$FLAVOR"
    got=$(skopeo inspect --tls-verify="$TLS_VERIFY" --raw "docker://$REPO:$FLAVOR" | sha256sum | cut -d' ' -f1)
    [ "sha256:$got" = "$DIGEST" ] || die "$REPO:$FLAVOR resolves to sha256:$got, expected $DIGEST"
    echo "[+] $REPO:$FLAVOR -> $DIGEST"
    ;;

  *) die "unknown command $CMD" ;;
esac
