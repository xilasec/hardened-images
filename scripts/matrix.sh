#!/bin/bash
# Enforce flavor parity and print the CI build matrix.
#
# Usage: scripts/matrix.sh [image|all]
#
# Every images/<name>/ must provide, for every flavor in scripts/lib.sh:
#   <flavor>.yaml       including flavors/<flavor>.yaml
#   <flavor>.lock.json  (scripts/lock.sh) whose `<name>@local` packages all
#                       resolve to packages/<flavor>/ on every arch
# plus an executable test.sh. Anything missing fails, so an image can never
# ship in one libc only, or with an upstream fallback for a hardened package.
#
# Prints JSON: {"build":[{image,flavor,arch,runner}...],"publish":[{image,flavor}...]}
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

SEL=${1:-all}
errors=()
images=$(all_images)

for image in $images; do
  [ -x "images/$image/test.sh" ] || errors+=("images/$image/test.sh missing or not executable")
  for flavor in $FLAVORS; do
    cfg="images/$image/$flavor.yaml"
    if [ ! -f "$cfg" ]; then errors+=("$cfg missing"); continue; fi
    [ "$(yq -r '.include // ""' "$cfg")" = "flavors/$flavor.yaml" ] \
      || errors+=("$cfg must 'include: flavors/$flavor.yaml'")
    lock="images/$image/$flavor.lock.json"
    if [ ! -f "$lock" ]; then
      errors+=("$lock missing (scripts/lock.sh $image $flavor)")
    elif ! wrong=$(misresolved_local_packages "$cfg" "$lock" "$flavor"); then
      errors+=("$lock: @local packages resolved upstream: $(paste -sd, <<<"$wrong")")
    fi
  done
  for f in images/"$image"/*.yaml; do
    n=$(basename "$f" .yaml)
    case " $FLAVORS " in *" $n "*) ;; *) errors+=("$f is not a known flavor ($FLAVORS)") ;; esac
  done
done

if [ ${#errors[@]} -gt 0 ]; then
  printf '[-] %s\n' "${errors[@]}" >&2
  exit 1
fi

if [ "$SEL" != all ]; then
  grep -qx "$SEL" <<<"$images" || die "unknown image '$SEL' (have: $(paste -sd' ' <<<"$images"))"
  images=$SEL
fi

{
  for image in $images; do
    for flavor in $FLAVORS; do
      for arch in $(flavor_archs "$flavor"); do
        runner=ubuntu-24.04
        [ "$arch" = aarch64 ] && runner=ubuntu-24.04-arm
        jq -nc --arg i "$image" --arg f "$flavor" --arg a "$arch" --arg r "$runner" \
          '{image:$i, flavor:$f, arch:$a, runner:$r}'
      done
    done
  done
} | jq -sc '{build: ., publish: (map({image, flavor}) | unique)}'
