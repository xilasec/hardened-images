#!/bin/bash
# Functional test for base: no shell, so inspect the filesystem from outside.
# Usage: test.sh <image-ref> (DOCKER, PLATFORM and RUN come from scripts/test.sh)
set -euo pipefail
REF=$1
D=${DOCKER:-docker}

cid=$($D create --platform "$PLATFORM" "$REF" /nonexistent)
trap '$D rm "$cid" >/dev/null' EXIT
files=$($D export "$cid" | tar -t)

need() { grep -qxE "$1" <<<"$files" || { echo "[-] missing $1"; exit 1; }; }
deny() { ! grep -qxE "$1" <<<"$files" || { echo "[-] unexpected $1"; exit 1; }; }

need 'etc/os-release|usr/lib/os-release'
need 'etc/ssl/certs/ca-certificates.crt'
need 'etc/passwd'
need '(usr/)?lib(64)?/ld-(musl-[a-z0-9_]+|linux-[a-z0-9_-]+)\.so\.[0-9]'
deny 'bin/sh|usr/bin/sh'
deny 'sbin/apk|usr/bin/apk'
echo "[+] base: libc, CA bundle and os-release present; no shell, no package manager"
