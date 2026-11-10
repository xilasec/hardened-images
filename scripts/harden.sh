#!/bin/bash
# ELF hardening report for a built archive.
# Usage: scripts/harden.sh <image> <flavor> [arch]
#
# Blocks on critical gaps: executable stack, writable+executable segments,
# text relocations. Reports PIE, full RELRO and stack protector usage.
# Writes $OUTDIR/harden-<stem>.json.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

STEM=$(stem "${1:?usage: harden.sh <image> <flavor> [arch]}" "${2:?}" "${3:-host}")
TAR="$OUTDIR/$STEM.tar"
REPORT="$OUTDIR/harden-$STEM.json"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

layer=$(tar -tf "$TAR" | grep '\.tar\.gz$' | head -n1)
tar -xOf "$TAR" "$layer" | tar -xz -C "$ROOT" 2>/dev/null || true

: > "$ROOT/.report"
while IFS= read -r -d '' f; do
  head -c4 "$f" 2>/dev/null | grep -q ELF || continue
  type=$(readelf -hW "$f" 2>/dev/null | awk '/Type:/ {print $2}')
  case "$type" in EXEC|DYN) ;; *) continue ;; esac
  ph=$(readelf -lW "$f" 2>/dev/null)
  dyn=$(readelf -dW "$f" 2>/dev/null)
  syms=$(readelf --dyn-syms -W "$f" 2>/dev/null)
  jq -nc \
    --arg file "${f#"$ROOT"/}" \
    --argjson pie "$([ "$type" = DYN ] && echo true || echo false)" \
    --argjson relro "$(grep -q GNU_RELRO <<<"$ph" && echo true || echo false)" \
    --argjson now "$(grep -qE 'BIND_NOW|FLAGS.*\bNOW\b' <<<"$dyn" && echo true || echo false)" \
    --argjson execstack "$(grep -E 'GNU_STACK' <<<"$ph" | grep -q 'RWE' && echo true || echo false)" \
    --argjson rwx "$(grep -E '^\s*LOAD' <<<"$ph" | grep -q 'RWE' && echo true || echo false)" \
    --argjson textrel "$(grep -q TEXTREL <<<"$dyn" && echo true || echo false)" \
    --argjson canary "$(grep -q __stack_chk_fail <<<"$syms" && echo true || echo false)" \
    '{file: $file, pie: $pie, full_relro: ($relro and $now), execstack: $execstack, rwx: $rwx, textrel: $textrel, canary: $canary}' \
    >> "$ROOT/.report"
done < <(find "$ROOT" -type f -perm /111 -print0 -o -type f -name '*.so*' -print0)

jq -s '{files: ., summary: {
  elf: length,
  no_pie: map(select(.pie | not)) | length,
  no_full_relro: map(select(.full_relro | not)) | length,
  no_canary: map(select(.canary | not)) | length,
  critical: map(select(.execstack or .rwx or .textrel)) | map(.file)}}' "$ROOT/.report" > "$REPORT"

jq -r '.summary | "[+] ELF: \(.elf) files, \(.no_pie) without PIE, \(.no_full_relro) without full RELRO, \(.no_canary) without stack protector"' "$REPORT"
crit=$(jq -r '.summary.critical[]' "$REPORT")
[ -z "$crit" ] || die "critical hardening gaps (exec stack, W+X segment or text relocations):"$'\n'"$crit"
