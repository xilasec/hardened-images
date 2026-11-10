#!/bin/bash
# Build the OpenVEX document published with an image.
# Usage: scripts/vex.sh <image> <flavor> <repository> <index-digest>
#
# Products are the image itself in the two forms scanners look up
# (`pkg:oci/...` for trivy --vex oci, `<repo>@<digest>` for grype), with the
# affected packages as subcomponents. Statements:
#   - every hand-written statement from vex/ (fixed, not_affected)
#   - every finding still reported after the gates: affected, with the reason
# Writes $OUTDIR/vex-<image>-<flavor>.openvex.json.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

IMAGE=${1:?usage: vex.sh <image> <flavor> <repository> <index-digest>}
FLAVOR=${2:?}
REPO=${3:?}
DIGEST=${4:?}
OUT="$OUTDIR/vex-$IMAGE-$FLAVOR.openvex.json"

reports=()
for arch in $(flavor_archs "$FLAVOR"); do
  s=$(stem "$IMAGE" "$FLAVOR" "$arch")
  for r in "$OUTDIR/grype-$s.json" "$OUTDIR/grype-xdistro-$s.json"; do
    [ -f "$r" ] && reports+=("$r")
  done
done
[ ${#reports[@]} -gt 0 ] || die "no grype reports for $IMAGE:$FLAVOR"

hand=$(vex_files | xargs -r jq -s '[.[].statements[]]')
[ -n "$hand" ] || hand='[]'
# Package URLs present in the image, to keep only hand statements that apply.
present=$(for arch in $(flavor_archs "$FLAVOR"); do
  jq -r '.packages[].externalRefs[]? | select(.referenceType == "purl") | .referenceLocator | sub("\\?.*$"; "")' \
    "$OUTDIR/sbom-$(stem "$IMAGE" "$FLAVOR" "$arch").spdx.json"
done | sort -u | jq -R . | jq -s .)

jq -s \
  --arg image "$IMAGE" --arg repo "$REPO" --arg digest "$DIGEST" \
  --arg now "$(date -u +%FT%TZ)" --argjson hand "$hand" --argjson present "$present" '
  def base(p): p | sub("\\?.*$"; "");
  def products(subs): [
    {"@id": "pkg:oci/\($image)@\($digest)?repository_url=\($repo)", subcomponents: subs},
    {"@id": "\($repo)@\($digest)", subcomponents: subs}];
  ([.[].matches[]] | map({id: .vulnerability.id, purl: base(.artifact.purl),
      sev: .vulnerability.severity}) | unique) as $open
  | {
      "@context": "https://openvex.dev/ns/v0.2.0",
      "@id": "https://github.com/xilasec/hardened-images/vex/\($image)/\($digest)",
      author: "xilasec",
      timestamp: $now,
      version: 1,
      statements: (
        [ $hand[]
          | ([.products[] | .["@id"] | select(IN($present[]))] | map({"@id": .})) as $subs
          | select($subs | length > 0)
          | . + {products: products($subs)} ]
        + [ $open | group_by(.id)[] | {
              vulnerability: {name: .[0].id},
              products: products([.[] | {"@id": .purl}] | unique),
              status: "affected",
              action_statement: "No fixed version is available upstream. The image is rescanned daily and rebuilt as soon as one ships.",
              status_notes: "Severity \(.[0].sev). Below the blocking threshold (Critical, or High with CVSS > 8.0 or listed in CISA KEV)."
            } ]
      )
    }' "${reports[@]}" > "$OUT"

echo "[+] $OUT: $(jq '.statements | length' "$OUT") statements"
