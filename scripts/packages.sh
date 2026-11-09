#!/bin/bash
# Build the melange packages a flavor's images request as `<name>@local`.
#
# Usage: scripts/packages.sh <flavor> [arch] [--check]
#
# Packages are immutable, committed artifacts under packages/<flavor>/<arch>/,
# pinned by checksum in the image lockfiles. Each one carries a stamp file
# (<name>.inputs) recording the version and a hash of everything that
# determines its contents: the recipe, its source dir (patches) and the
# flavor's upstream repositories. A package is rebuilt only when that stamp is
# missing or stale, and a rebuild with an unchanged version is refused: bump
# package.epoch so the new bytes get a new version.
#
# --check only reports stale packages (exit 1), without building.
#
# Signing key: $MELANGE_SIGNING_KEY (path), default
# melange/xilasec@hardned-images.rsa (gitignored).
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

inputs_of() {
  local pkg=$1
  {
    sha256sum "melange/$pkg.yaml"
    [ -d "melange/$pkg" ] && find "melange/$pkg" -type f -print0 | sort -z | xargs -0 sha256sum
    flavor_repositories "$FLAVOR"
  } | sha256sum | cut -d' ' -f1
}

stale=()
for pkg in $(local_packages_for_flavor "$FLAVOR"); do
  recipe="melange/$pkg.yaml"
  [ -f "$recipe" ] || die "images request $pkg@local but $recipe does not exist"
  ver="$(yq -r .package.version "$recipe")-r$(yq -r .package.epoch "$recipe")"
  want="$ver $(inputs_of "$pkg")"
  have=$(cat "$OUT/$pkg.inputs" 2>/dev/null || true)
  if [ "$want" = "$have" ] && [ -f "$OUT/$pkg-$ver.apk" ]; then
    echo "[=] $FLAVOR/$ARCH $pkg-$ver up to date"
    continue
  fi
  if [ -n "$have" ] && [ "${have%% *}" = "$ver" ]; then
    die "$pkg inputs changed but version is still $ver: bump package.epoch in $recipe"
  fi
  stale+=("$pkg")
done

if [ ${#stale[@]} -eq 0 ]; then exit 0; fi
if $CHECK; then
  die "stale packages for $FLAVOR/$ARCH: ${stale[*]} (run scripts/packages.sh $FLAVOR $ARCH)"
fi

[ -f "$KEY" ] || die "signing key not found at $KEY (set MELANGE_SIGNING_KEY)"

repo_args=()
for r in $(flavor_repositories "$FLAVOR"); do repo_args+=(--repository-append "$r"); done
for k in $(flavor_keyrings "$FLAVOR"); do repo_args+=(--keyring-append "$k"); done

mkdir -p "$OUT"
for pkg in "${stale[@]}"; do
  recipe="melange/$pkg.yaml"
  ver="$(yq -r .package.version "$recipe")-r$(yq -r .package.epoch "$recipe")"
  # Deterministic timestamps: the last commit touching the recipe (or 0 for an
  # uncommitted recipe). Same inputs -> byte-identical .apk.
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct -- "$recipe" "melange/$pkg" 2>/dev/null || true)
  export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

  src_args=()
  [ -d "melange/$pkg" ] && src_args=(--source-dir "melange/$pkg")

  echo "[+] melange: $FLAVOR/$ARCH $pkg-$ver (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
  rm -f "$OUT/$pkg"-[0-9]*.apk
  melange build "$recipe" \
    --arch "$ARCH" \
    --namespace xilasec \
    --signing-key "$KEY" \
    --generate-index=false \
    "${src_args[@]}" \
    "${repo_args[@]}" \
    --out-dir "$REPO_DIR"
  echo "$ver $(inputs_of "$pkg")" > "$OUT/$pkg.inputs"
done

echo "[+] Indexing $OUT"
melange index --signing-key "$KEY" --output "$OUT/APKINDEX.tar.gz" "$OUT"/*.apk
