#!/bin/bash
# Bump melange recipes to their latest upstream release.
# Usage: scripts/update.sh
#
# Uses each recipe's `update:` block (github or release-monitor, with an
# optional version prefix). `melange bump` sets the version, resets the epoch
# and refreshes checksums. Prints "<recipe> <old> <new>" per bump.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

latest() {
  local r=$1 gh rm prefix strip
  gh=$(yq -r '.update.github.identifier // ""' "$r")
  rm=$(yq -r '.update.release-monitor.identifier // ""' "$r")
  if [ -n "$gh" ]; then
    prefix=$(yq -r '.update.github.tag-filter-prefix // ""' "$r")
    strip=$(yq -r '.update.github.strip-prefix // ""' "$r")
    curl -sfL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
      "https://api.github.com/repos/$gh/releases?per_page=100" \
      | jq -r --arg p "$prefix" '.[] | select(.prerelease | not) | .tag_name | select(startswith($p))' \
      | sed "s|^$strip||" | sort -V | tail -n1
  elif [ -n "$rm" ]; then
    prefix=$(yq -r '.update.release-monitor.version-filter-prefix // ""' "$r")
    curl -sfL "https://release-monitoring.org/api/v2/versions/?project_id=$rm" \
      | jq -r --arg p "$prefix" '.stable_versions[] | select(startswith($p))' | sort -V | tail -n1
  fi
}

for r in melange/*.yaml; do
  [ "$(yq -r '.update.enabled // false' "$r")" = true ] || continue
  cur=$(yq -r .package.version "$r")
  new=$(latest "$r")
  [ -n "$new" ] || { echo "[!] $r: no upstream version found" >&2; continue; }
  [ "$new" = "$cur" ] && continue
  [ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -n1)" = "$new" ] || continue
  cp "$r" "$r.bak"
  if melange bump "$r" "$new" >/dev/null 2>&1; then
    rm "$r.bak"
    echo "$(basename "$r" .yaml) $cur $new"
  else
    mv "$r.bak" "$r"
    echo "[!] $r: bump to $new failed (source URL changed?)" >&2
  fi
done
