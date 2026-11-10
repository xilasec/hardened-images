#!/bin/bash
# Publish one tested image flavor as a multi-arch index.
#
# Usage:
#   scripts/publish.sh push    <image> <flavor>
#   scripts/publish.sh promote <image> <flavor> <index-digest>
#
# push: rebuild from the tested lockfile, refuse unless every per-arch digest
# equals the tested one, push under the immutable tag <flavor>-YYYY-MM-DD
# (<flavor>-YYYY-MM-DD-HHMM if that day already has one), then sign and attest
# SBOMs, VEX and the lockfile.
# promote: move <flavor> to the digest. Runs last, so it never points at an
# unsigned image.
#
# SIGN=false skips signing (local registries). TLS_VERIFY=false allows HTTP.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

CMD=${1:?usage: publish.sh push|promote <image> <flavor> [digest]}
IMAGE=${2:?}
FLAVOR=${3:?}
check_flavor "$FLAVOR"
REPO="$REGISTRY/$IMAGE"
SIGN=${SIGN:-true}

output() {
  echo "    $1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

case "$CMD" in
  push)
    CFG=$(image_config "$IMAGE" "$FLAVOR")
    LOCK=$(image_lock "$IMAGE" "$FLAVOR")
    [ -f "$LOCK" ] || die "missing tested lockfile $LOCK"
    tested=""
    for arch in $(flavor_archs "$FLAVOR"); do
      s=$(stem "$IMAGE" "$FLAVOR" "$arch")
      [ -f "$OUTDIR/$s.digest" ] || die "no tested digest for $s"
      tested+="$(oci_arch "$arch") $(cat "$OUTDIR/$s.digest")"$'\n'
    done
    tested=$(sort <<<"$tested" | grep .)

    TAG="$FLAVOR-$(date -u +%F)"
    if skopeo inspect --tls-verify="$TLS_VERIFY" --raw "docker://$REPO:$TAG" >/dev/null 2>&1; then
      TAG="$TAG-$(date -u +%H%M)"
    fi

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    apko build --sbom=false --vcs=false --lockfile "$LOCK" --cache-dir "$TMP/cache" \
      "$CFG" "$REPO:$TAG" "$TMP/index.tar" >/dev/null
    tar -xOf "$TMP/index.tar" index.json > "$TMP/index.json"
    built=$(jq -r '.manifests[] | "\(.platform.architecture) \(.digest)"' "$TMP/index.json" | sort)
    [ "$built" = "$tested" ] || die "rebuild differs from tested digests:"$'\n'"$tested"$'\n'"vs"$'\n'"$built"
    DIGEST="sha256:$(sha256sum < "$TMP/index.json" | cut -d' ' -f1)"

    echo "[+] Publishing $REPO:$TAG ($DIGEST)"
    ref=$(apko publish --sbom=false --vcs=false --lockfile "$LOCK" "$CFG" "$REPO:$TAG" | tail -n1)
    [ "${ref##*@}" = "$DIGEST" ] || die "apko publish pushed '$ref', expected $DIGEST"
    [ "$(index_manifests "$REPO@$DIGEST")" = "$tested" ] || die "registry serves different manifests"

    if [ "$SIGN" = true ]; then
      cosign sign --yes --recursive "$REPO@$DIGEST"
      for arch in $(flavor_archs "$FLAVOR"); do
        s=$(stem "$IMAGE" "$FLAVOR" "$arch")
        cosign attest --yes --type spdxjson --predicate "$OUTDIR/sbom-$s.spdx.json" \
          "$REPO@$(cat "$OUTDIR/$s.digest")"
      done
      for v in $(vex_files_of "$CFG"); do
        cosign attest --yes --type openvex --predicate "$v" "$REPO@$DIGEST"
      done
      cosign attest --yes --type https://apko.dev/lockfile/v1 --predicate "$LOCK" "$REPO@$DIGEST"
    fi

    output "repository=$REPO"
    output "digest=$DIGEST"
    output "tag=$TAG"
    ;;

  promote)
    DIGEST=${4:?usage: publish.sh promote <image> <flavor> <index-digest>}
    skopeo copy -q --all --preserve-digests \
      --src-tls-verify="$TLS_VERIFY" --dest-tls-verify="$TLS_VERIFY" \
      "docker://$REPO@$DIGEST" "docker://$REPO:$FLAVOR"
    got="sha256:$(skopeo inspect --tls-verify="$TLS_VERIFY" --raw "docker://$REPO:$FLAVOR" | sha256sum | cut -d' ' -f1)"
    [ "$got" = "$DIGEST" ] || die "$REPO:$FLAVOR resolves to $got, expected $DIGEST"
    echo "[+] $REPO:$FLAVOR -> $DIGEST"
    ;;

  *) die "unknown command $CMD" ;;
esac
