#!/bin/bash
# Build the melange recipes listed for a flavor in melange/flavors.yaml.
# Recipes build against the distro only.
#
# Usage: scripts/packages.sh <flavor> [arch] [--check]
#
# Output is committed under packages/<flavor>/<arch>/. A stamp per recipe
# (<recipe>.inputs) holds its version and a hash of the recipe (normalized),
# its source dir and the flavor repositories. Only stale recipes are rebuilt; changing inputs
# without a new version fails: bump package.epoch.
#
# --check only reports stale recipes (exit 1).
# Signing key: $MELANGE_SIGNING_KEY, default melange/xilasec@hardned-images.rsa.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

FLAVOR=${1:?usage: packages.sh <flavor> [arch] [--check]}
ARCH=$(apk_arch "${2:-host}")
CHECK=false
[ "${3:-}" = "--check" ] && CHECK=true
check_flavor "$FLAVOR"

REPO_DIR="packages/$FLAVOR"
OUT="$REPO_DIR/$ARCH"
KEY=${MELANGE_SIGNING_KEY:-melange/xilasec@hardned-images.rsa}

version_of() { echo "$(yq -r .package.version "melange/$1.yaml")-r$(yq -r .package.epoch "melange/$1.yaml")"; }

# Comments, formatting and the update: block do not change what is built.
inputs_of() {
  {
    yq -o json 'del(.update)' "melange/$1.yaml" | sha256sum
    [ -d "melange/$1" ] && find "melange/$1" -type f -print0 | sort -z | xargs -0 sha256sum
    flavor_repositories "$FLAVOR"
  } | sha256sum | cut -d' ' -f1
}

recipes=$(recipes_for_flavor "$FLAVOR")
stale=()
for r in $recipes; do
  ver=$(version_of "$r")
  wanted="$ver $(inputs_of "$r")"
  have=$(cat "$OUT/$r.inputs" 2>/dev/null || true)
  if [ "$wanted" = "$have" ] && [ -f "$OUT/$r-$ver.apk" ]; then
    echo "[=] $FLAVOR/$ARCH $r-$ver up to date"
    continue
  fi
  if [ -n "$have" ] && [ "${have%% *}" = "$ver" ]; then
    die "$r inputs changed but version is still $ver: bump package.epoch in melange/$r.yaml"
  fi
  stale+=("$r")
done

[ ${#stale[@]} -eq 0 ] && exit 0
$CHECK && die "stale recipes for $FLAVOR/$ARCH: ${stale[*]} (run scripts/packages.sh $FLAVOR $ARCH)"
[ -f "$KEY" ] || die "signing key not found at $KEY (set MELANGE_SIGNING_KEY)"

repo_args=()
for x in $(flavor_repositories "$FLAVOR"); do repo_args+=(--repository-append "$x"); done
for x in $(flavor_keyrings "$FLAVOR"); do repo_args+=(--keyring-append "$x"); done

mkdir -p "$OUT"
for r in "${stale[@]}"; do
  ver=$(version_of "$r")
  # Deterministic timestamps: last commit touching the recipe (0 if uncommitted).
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct -- "melange/$r.yaml" "melange/$r" 2>/dev/null || true)
  export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

  src_args=()
  [ -d "melange/$r" ] && src_args=(--source-dir "melange/$r")

  echo "[+] melange: $FLAVOR/$ARCH $r-$ver"
  for p in $(recipe_provides "melange/$r.yaml"); do rm -f "$OUT/$p"-[0-9]*.apk; done
  melange build "melange/$r.yaml" \
    --arch "$ARCH" \
    --namespace xilasec \
    --signing-key "$KEY" \
    --generate-index=false \
    "${src_args[@]}" "${repo_args[@]}" \
    --out-dir "$REPO_DIR"
  echo "$ver $(inputs_of "$r")" > "$OUT/$r.inputs"
  melange index --signing-key "$KEY" --output "$OUT/APKINDEX.tar.gz" "$OUT"/*.apk
done
