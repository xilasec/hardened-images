#!/bin/bash
# shellcheck disable=SC2086 # $RUN holds several docker flags
# Functional test for balanced: hardened busybox shell.
# Usage: test.sh <image-ref> (DOCKER, PLATFORM and RUN come from scripts/test.sh)
set -euo pipefail
REF=$1
D=${DOCKER:-docker}
run() { $D $RUN "$REF" -c "$1"; }

[ "$(run 'echo ok')" = ok ] || { echo "[-] /bin/sh does not run"; exit 1; }
[ "$(run 'id -u')" = 1000 ] || { echo "[-] shell is not running as uid 1000"; exit 1; }

# Applets removed at build time (melange/busybox.yaml) must stay removed.
for applet in telnetd httpd ftpd inetd tcpsvd udpsvd login su tc; do
  if run "busybox --list" | grep -qx "$applet"; then
    echo "[-] busybox still ships '$applet'"; exit 1
  fi
done
# No setuid/setgid files in any directory appuser can read (find exits
# non-zero on unreadable dirs such as a 0700 /root, hence `|| true`).
suid=$(run 'find / -xdev -perm /6000 -type f 2>/dev/null || true')
[ -z "$suid" ] || { echo "[-] setuid/setgid files: $suid"; exit 1; }
echo "[+] balanced: shell works as uid 1000, network daemons/su/login absent, no suid files"
