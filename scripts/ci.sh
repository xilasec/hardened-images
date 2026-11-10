#!/bin/bash
# CI driver: decide what needs building, build and gate only that.
#
# Usage: scripts/ci.sh <mode> [image|all]
#   scan  rescan published images; rebuild only those with fixable findings
#   diff  rebuild every image; keep only those whose digests changed
#   all   rebuild and gate everything (pull requests)
#
# A rebuild re-locks against the current Alpine/Wolfi index. If the result is
# byte-identical to what is published (the fix is not packaged yet), it is
# skipped. Writes $OUTDIR/publish.json: [{image, flavor}] that passed all gates.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

MODE=${1:?usage: ci.sh scan|diff|all [image]}
SEL=${2:-all}
case "$MODE" in scan|diff|all) ;; *) die "unknown mode $MODE" ;; esac

check_parity
for f in $FLAVORS; do for a in $(flavor_archs "$f"); do scripts/packages.sh "$f" "$a" --check; done; done

images=$(all_images)
[ "$SEL" = all ] || { grep -qx "$SEL" <<<"$images" || die "unknown image $SEL"; images=$SEL; }
mkdir -p "$OUTDIR"

# Fixable findings in a published image, summed over its architectures.
fixable_published() {
  local image=$1 flavor=$2 arch n total=0 vex=()
  for v in $(vex_files_of "images/$image/$flavor.yaml"); do vex+=(--vex "$v"); done
  for arch in $(flavor_archs "$flavor"); do
    n=$(grype "registry:$REGISTRY/$image:$flavor" --platform "linux/$(oci_arch "$arch")" \
          -q "${vex[@]}" -o json | jq '[.matches[] | select(.vulnerability.fix.state == "fixed")] | length')
    total=$((total + n))
  done
  echo "$total"
}

gate() {
  local image=$1 flavor=$2 arch
  need syft grype trivy opa dockle
  for arch in $(flavor_archs "$flavor"); do
    if [ "$(apk_arch host)" != "$arch" ] && [ ! -e "/proc/sys/fs/binfmt_misc/qemu-$arch" ]; then
      ${DOCKER:-docker} run --privileged --rm \
        docker.io/tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0 \
        --install "$(oci_arch "$arch")" >/dev/null
    fi
    scripts/sbom.sh "$image" "$flavor" "$arch" &&
      scripts/scan.sh "$image" "$flavor" "$arch" &&
      scripts/verify.sh "$image" "$flavor" "$arch" &&
      scripts/compliance.sh "$image" "$flavor" "$arch" &&
      scripts/test.sh "$image" "$flavor" "$arch" || return 1
  done
}

need apko
publish=()
failed=()
for image in $images; do
  for flavor in $FLAVORS; do
    id="$image:$flavor"
    published=$(index_manifests "$REGISTRY/$id" 2>/dev/null || true)

    if [ "$MODE" = scan ] && [ -n "$published" ]; then
      need grype
      n=$(fixable_published "$image" "$flavor")
      if [ "$n" -eq 0 ]; then echo "[=] $id: no fixable findings, skip"; continue; fi
      echo "[+] $id: $n fixable findings, rebuilding"
    fi

    scripts/lock.sh "$image" "$flavor" >/dev/null
    built=""
    for arch in $(flavor_archs "$flavor"); do
      scripts/build.sh "$image" "$flavor" "$arch" >/dev/null
      built+="$(oci_arch "$arch") $(cat "$OUTDIR/$(stem "$image" "$flavor" "$arch").digest")"$'\n'
    done
    built=$(sort <<<"$built" | grep .)

    if [ "$MODE" != all ] && [ "$built" = "$published" ]; then
      echo "[=] $id: rebuild is identical to the published image, skip"
      continue
    fi

    echo "[+] $id: gating"
    if gate "$image" "$flavor"; then
      publish+=("$image $flavor")
    else
      echo "[-] $id: failed gates"
      failed+=("$id")
    fi
  done
done

printf '%s\n' "${publish[@]}" | jq -Rnc '[inputs | select(length > 0) | split(" ") | {image: .[0], flavor: .[1]}]' \
  > "$OUTDIR/publish.json"
echo "[+] to publish: $(cat "$OUTDIR/publish.json")"
[ ${#failed[@]} -eq 0 ] || die "failed: ${failed[*]}"
