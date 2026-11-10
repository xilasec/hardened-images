# Shared helpers for scripts/*.sh. Source, don't execute.
# shellcheck shell=bash

# Every image ships in both flavors; check_parity enforces it.
#   musl  -> Alpine (flavors/musl.yaml)
#   glibc -> Wolfi  (flavors/glibc.yaml)
FLAVORS="musl glibc"

REGISTRY=${REGISTRY:-ghcr.io/xilasec}
OUTDIR=${OUTDIR:-dist}

# Image timestamps must be a function of the lockfile alone: without
# SOURCE_DATE_EPOCH apko uses the newest package build date. An inherited value
# would silently change every digest. (packages.sh sets its own for melange.)
unset SOURCE_DATE_EPOCH

die() { echo "[-] $*" >&2; exit 1; }

# Normalize any arch spelling (amd64/x86_64/arm64/aarch64/host/empty) to the
# apk name apko and melange use.
apk_arch() {
  local a=${1:-host}
  [ "$a" = host ] && a=$(uname -m)
  case "$a" in
    amd64|x86_64) echo x86_64 ;;
    arm64|aarch64) echo aarch64 ;;
    *) die "unsupported architecture: $a" ;;
  esac
}

# OCI platform architecture for an apk arch.
oci_arch() {
  case "$(apk_arch "$1")" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
  esac
}

check_flavor() {
  case " $FLAVORS " in
    *" $1 "*) ;;
    *) die "unknown flavor '$1' (expected one of: $FLAVORS)" ;;
  esac
}

# Image names: directories under images/.
all_images() {
  local d
  for d in images/*/; do d=${d%/}; echo "${d#images/}"; done
}

image_config() {
  local cfg="images/$1/$2.yaml"
  [ -f "$cfg" ] || die "missing $cfg"
  echo "$cfg"
}

image_lock() { echo "images/$1/$2.lock.json"; }

# Stable artifact stem for one image/flavor/arch, e.g. node24-musl-x86_64.
stem() { echo "$1-$2-$(apk_arch "$3")"; }

# Names requested as `<name>@local` by one image config.
local_packages_of() {
  { grep -oE '^[[:space:]]*-[[:space:]]*[A-Za-z0-9._+-]+@local' "$1" || true; } \
    | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/@local$//' | sort -u
}

# Names requested as `<name>@local` by any image of one flavor.
local_packages_for_flavor() {
  local f
  for f in images/*/"$1".yaml; do local_packages_of "$f"; done | sort -u
}

# Lock entries for `<name>@local` packages that did not resolve to
# packages/<flavor>/ (apko falls back to upstream when an arch has no local
# build). Prints "<name> <arch>: <url>" lines and returns 1 when any exist.
misresolved_local_packages() {
  local cfg=$1 lock=$2 flavor=$3 out
  out=$(local_packages_of "$cfg" | jq -R . | jq -rs --arg dir "./packages/$flavor/" --slurpfile lock "$lock" '
    . as $names | $lock[0].contents.packages[]
    | select((.name | IN($names[])) and (.url | startswith($dir) | not))
    | "\(.name) \(.architecture): \(.url)"')
  [ -z "$out" ] || { echo "$out"; return 1; }
}

# Upstream repositories / keyrings of a flavor (the @local repo is excluded:
# melange build environments only need the distro).
flavor_repositories() { yq -r '.contents.repositories[] | select(test("^@") | not)' "flavors/$1.yaml"; }
flavor_keyrings() { yq -r '.contents.keyring[]' "flavors/$1.yaml"; }
flavor_archs() { yq -r '.archs[]' "flavors/$1.yaml"; }

# OpenVEX documents that apply to an image: one per locally built package it
# installs (vex/<package>.openvex.json). Statements are scoped to the exact
# package URL + version, so they cannot suppress findings in upstream builds.
vex_files_of() {
  local p
  for p in $(local_packages_of "$1"); do
    [ -f "vex/$p.openvex.json" ] && echo "vex/$p.openvex.json"
  done
  return 0
}

# Digest of the single manifest inside an apko single-arch archive.
archive_manifest_digest() {
  tar -xOf "$1" index.json | jq -r '.manifests[0].digest'
}

TLS_VERIFY=${TLS_VERIFY:-true}

# "<oci-arch> <digest>" per manifest of a registry index, sorted. Fails when
# the reference does not exist.
index_manifests() {
  skopeo inspect --tls-verify="$TLS_VERIFY" --raw "docker://$1" \
    | jq -r '.manifests[] | "\(.platform.architecture) \(.digest)"' | sort
}

# Make sure tools exist. In CI (CI=true) missing ones are installed on
# demand, so runs that skip everything never download scanners.
need() {
  local t missing=()
  for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  [ "${CI:-}" = true ] || die "missing tools: ${missing[*]} (make tools)"
  scripts/install-tools.sh "${missing[@]}"
}

# Every image must define every flavor and ship a test.
check_parity() {
  local image flavor f errors=()
  for image in $(all_images); do
    [ -x "images/$image/test.sh" ] || errors+=("images/$image/test.sh missing or not executable")
    for flavor in $FLAVORS; do
      f="images/$image/$flavor.yaml"
      if [ ! -f "$f" ]; then errors+=("$f missing"); continue; fi
      [ "$(yq -r '.include // ""' "$f")" = "flavors/$flavor.yaml" ] \
        || errors+=("$f must 'include: flavors/$flavor.yaml'")
    done
  done
  [ ${#errors[@]} -eq 0 ] || { printf '[-] %s\n' "${errors[@]}" >&2; exit 1; }
}
