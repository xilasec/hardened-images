#!/bin/bash
# Resolve and pin every package (name, version, checksum) of an image flavor.
#
# Usage: scripts/lock.sh [image|all] [flavor|all]
#
# Writes images/<image>/<flavor>.lock.json. Builds always use the lockfile, so
# an image only changes when its lock does. Refresh by re-running this (CI
# does it nightly in .github/workflows/update-locks.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGES=${1:-all}
FLAVOR_SEL=${2:-all}
[ "$IMAGES" = all ] && IMAGES=$(all_images)
[ "$FLAVOR_SEL" = all ] && FLAVOR_SEL=$FLAVORS

for image in $IMAGES; do
  for flavor in $FLAVOR_SEL; do
    check_flavor "$flavor"
    cfg=$(image_config "$image" "$flavor")
    lock=$(image_lock "$image" "$flavor")
    echo "[+] Locking $cfg -> $lock"
    apko lock "$cfg" --output "$lock.tmp"
    # apko silently falls back to the upstream package when `<name>@local` has
    # no build for an arch; refuse such a lock.
    if ! wrong=$(misresolved_local_packages "$cfg" "$lock.tmp" "$flavor"); then
      rm -f "$lock.tmp"
      die "$cfg: @local packages resolved outside packages/$flavor (build them with scripts/packages.sh $flavor <arch>):"$'\n'"$wrong"
    fi
    mv "$lock.tmp" "$lock"
  done
done
