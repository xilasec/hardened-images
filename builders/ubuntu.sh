#!/bin/bash
set -euo pipefail

CONFIG=$1
TAG=$3

OUT=$2

# debootstrap scratch rootfs. Override with WORKDIR to put it on a writable
# native filesystem - debootstrap needs a real writable fs and won't work on a
# read-only host mount (e.g. a Lima virtiofs mount); keeping it off virtiofs/9p
# is also much faster.
ROOTFS="${WORKDIR:-./tmp}"

echo "[+] Parsing config"
VERSION=$(yq '.version' $CONFIG)
ENTRYPOINT_UID=$(yq -r '.entrypoint.uid' $CONFIG)
ENTRYPOINT=$(yq -r '.entrypoint.command' $CONFIG)

# Target architecture: the ARCH env var overrides, otherwise the host arch.
# This lets one config build natively on amd64 (CI / x86 hosts) and arm64
# (e.g. Apple Silicon) with no per-arch config files and no emulation.
HOST_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${ARCH:-$HOST_ARCH}" in
  amd64|x86_64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "[-] Unsupported architecture: ${ARCH:-$HOST_ARCH}"; exit 1 ;;
esac

# Refuse to build an arch the config doesn't declare (`arch:` may be a scalar
# like `amd64` or a list like `[amd64, arm64]`).
SUPPORTED=$(yq e '[.arch] | flatten | .[]' "$CONFIG")
if ! printf '%s\n' $SUPPORTED | grep -qx "$ARCH"; then
  echo "[-] $CONFIG does not support arch '$ARCH' (declares: $(echo $SUPPORTED | tr '\n' ' '))"
  exit 1
fi

# Ubuntu serves amd64/i386 from archive+security.ubuntu.com and every other
# port (arm64, ...) from ports.ubuntu.com - pick the right mirrors per arch.
case "$ARCH" in
  amd64) APT_BASE="http://archive.ubuntu.com/ubuntu";      APT_SEC="http://security.ubuntu.com/ubuntu" ;;
  *)     APT_BASE="http://ports.ubuntu.com/ubuntu-ports";  APT_SEC="http://ports.ubuntu.com/ubuntu-ports" ;;
esac

LOCAL_PKGS=$(ARCH=$ARCH PWD=$PWD yq '.local-packages | map(strenv(PWD) + "/pkg/" + . + "_" + strenv(ARCH) + ".deb") | .[]' $CONFIG)

echo "[+] Running debootstrap (reproducible) $ARCH $VERSION $ROOTFS $APT_BASE ${LOCAL_PKGS}"
sudo debootstrap \
  --variant=minbase \
  --arch="$ARCH" \
  --exclude=e2fsprogs,sensible-utils,sysvinit-utils \
  "$VERSION" \
  "$ROOTFS" \
  "$APT_BASE"


echo "[+] Injecting and installing local packages"
if [ -n "${LOCAL_PKGS}" ]; then
  sudo mkdir -p "$ROOTFS/tmp/local-pkgs"
  for deb in ${LOCAL_PKGS}; do
      echo "  -> Copying $deb"
      sudo cp "$deb" "$ROOTFS/tmp/local-pkgs/"
  done
  sudo chroot "$ROOTFS" sh -c "dpkg -i /tmp/local-pkgs/*.deb"
  sudo rm -rf "$ROOTFS/tmp/local-pkgs"
fi

echo "[+] Configuring apt sources"
sudo tee "$ROOTFS/etc/apt/sources.list" > /dev/null <<EOF
deb ${APT_BASE} ${VERSION} main restricted universe multiverse
deb ${APT_SEC} ${VERSION}-security main restricted universe multiverse
deb ${APT_BASE} ${VERSION}-updates main restricted universe multiverse
EOF

# Prevent docs, locales, and recommends from ever being written to disk.
# Applies to all subsequent apt/dpkg operations, including the upgrade step.
sudo tee "$ROOTFS/etc/dpkg/dpkg.cfg.d/01_nodoc" > /dev/null <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*
EOF

sudo tee "$ROOTFS/etc/apt/apt.conf.d/01norecommends" > /dev/null <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF

echo "[+] Installing packages"
sudo chroot "$ROOTFS" apt-get update
PKGS=$(yq '.packages[]' $CONFIG | tr '\n' ' ')
sudo chroot "$ROOTFS" apt-get install -y $PKGS
sudo chroot "$ROOTFS" apt-get upgrade -y

echo "[+] Cleaning"
sudo chroot "$ROOTFS" apt-get autoremove --purge -y
sudo chroot "$ROOTFS" apt-get clean
sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*
sudo rm -rf "$ROOTFS/var/cache/apt/"*

echo "[+] Fetching upstream tarballs (pinned by sha256)"
# Optional `.tarballs` section: fetch an upstream binary tarball, verify it
# against a pinned sha256, and extract it into the rootfs. This keeps software
# that the distro doesn't package (e.g. Node.js 24) reproducible and auditable
# without adding third-party apt repositories.
num_tarballs=$(yq e '.tarballs | length' "$CONFIG" 2>/dev/null || echo 0)
[ "$num_tarballs" = "null" ] && num_tarballs=0
for ((t=0; t<num_tarballs; t++)); do
  # url/sha256 may be a scalar (single arch) or a per-arch map keyed by
  # amd64/arm64 - `.url.${ARCH} // .url` resolves both forms.
  url=$(yq e ".tarballs[$t].url.${ARCH} // .tarballs[$t].url" "$CONFIG")
  sha=$(yq e ".tarballs[$t].sha256.${ARCH} // .tarballs[$t].sha256" "$CONFIG")
  strip=$(yq e ".tarballs[$t].strip-components // 0" "$CONFIG")
  dest=$(yq e ".tarballs[$t].dest // \"/\"" "$CONFIG")
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "[-] tarballs[$t] has no url for arch '$ARCH'"; exit 1
  fi
  tmpf=$(mktemp)
  echo "  -> Downloading $url"
  curl -sfL "$url" -o "$tmpf"
  echo "  -> Verifying sha256 $sha"
  echo "${sha}  ${tmpf}" | sha256sum -c -
  echo "  -> Extracting into ${dest} (strip-components=${strip})"
  sudo mkdir -p "${ROOTFS%/}${dest}"
  sudo tar -C "${ROOTFS%/}${dest}" --strip-components="${strip}" -xf "$tmpf"
  rm -f "$tmpf"
done

echo "[+] Creating users"
num_users=$(yq e '.accounts.users | length' $CONFIG)

for ((i=0; i<$num_users; i++)); do
  user=$(yq e ".accounts.users[$i].username" $CONFIG)
  uid=$(yq e ".accounts.users[$i].uid" $CONFIG)
  num_groups=$(yq e ".accounts.users[$i].groups | length" $CONFIG)
  for ((j=0; j<$num_groups; j++)); do
    gname=$(yq e ".accounts.users[$i].groups[$j].groupname" $CONFIG)
    gid=$(yq e ".accounts.users[$i].groups[$j].gid" $CONFIG)
    if ! sudo chroot "$ROOTFS" getent group "$gname" > /dev/null; then
      if [ "$gid" != "null" ]; then
        sudo chroot "$ROOTFS" groupadd -g "$gid" "$gname"
      else
        sudo chroot "$ROOTFS" groupadd "$gname"
      fi
    fi
    if ! sudo chroot "$ROOTFS" id "$user" > /dev/null 2>&1; then
      sudo chroot "$ROOTFS" useradd -u "$uid" -g "$gname" "$user"
    else
      sudo chroot "$ROOTFS" usermod -aG "$gname" "$user"
    fi
  done
done

echo "[+] Hardening"
sudo rm -rf "$ROOTFS/usr/share/doc"
sudo rm -rf "$ROOTFS/usr/share/man"
sudo rm -rf "$ROOTFS/usr/share/info"
sudo rm -rf "$ROOTFS/usr/share/lintian"
sudo rm -rf "$ROOTFS/usr/share/common-licenses"
sudo find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 \
  ! -name 'en' ! -name 'en_US' -exec sudo rm -rf {} +
sudo rm -rf "$ROOTFS/var/log/"*
sudo rm -rf "$ROOTFS/tmp/"*

echo "[+] Minimizing image size"

sudo rm -f "$ROOTFS/usr/lib/locale/locale-archive"

# Keep *.list so syft maps filesystem paths to packages; keep *.md5sums so syft can
# verify file ownership and grype uses Ubuntu OVAL data instead of upstream NVD.
sudo find "$ROOTFS/var/lib/dpkg/info" -type f ! -name "*.list" ! -name "*.md5sums" -delete 2>/dev/null || true
sudo rm -rf "$ROOTFS/var/lib/dpkg/triggers"

# Removing the package manager also shrinks the attack surface
sudo rm -f \
  "$ROOTFS/usr/bin/apt" \
  "$ROOTFS/usr/bin/apt-get" \
  "$ROOTFS/usr/bin/apt-cache" \
  "$ROOTFS/usr/bin/apt-config" \
  "$ROOTFS/usr/bin/apt-cdrom" \
  "$ROOTFS/usr/bin/apt-key" \
  "$ROOTFS/usr/bin/apt-mark"
sudo rm -rf "$ROOTFS/usr/lib/apt"

sudo find "$ROOTFS/usr/lib" -name "*.a" -delete 2>/dev/null || true


# Stripping .so files causes syft's binary cataloger to fingerprint them with the
# raw upstream version (e.g. "openssl 3.0.13"), overriding the dpkg cataloger result
# that carries the Ubuntu epoch/backport suffix. Without that suffix grype falls back
# to upstream NVD data and flags already-patched CVEs as unresolved.
#
# `node` is the exception: it comes from a pinned upstream tarball, not dpkg, so
# there is no dpkg version to preserve. We deliberately leave it unstripped so
# syft's binary cataloger can fingerprint the Node runtime version and grype can
# scan it for CVEs - stripping it would hide the runtime from the SBOM.
sudo find "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin" \
  -maxdepth 1 -type f ! -name node \
  -exec strip --strip-unneeded {} + 2>/dev/null || true

echo "[+] Clearing device nodes from rootfs"
# debootstrap populates dev/ with real device nodes (console, null, urandom, …).
# OCI image layers cannot store device files the runtime recreates /dev at
# container startup from the runtime spec. Copying them with buildah add fails
# with EPERM on runners that lack CAP_MKNOD (e.g. GitHub Actions ubuntu-slim).
sudo find "$ROOTFS/dev" -maxdepth 1 \( -type b -o -type c \) -delete 2>/dev/null || true

echo "[+] Building OCI image with buildah"

# Pass storage driver as flags rather than writing /etc/containers/storage.conf,
# which would conflict with any pre-existing storage DB.
if command -v fuse-overlayfs &>/dev/null && [ -c /dev/fuse ]; then
  BSTORE=(--storage-driver overlay --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs)
else
  BSTORE=(--storage-driver vfs)
fi

container=$(sudo buildah "${BSTORE[@]}" from scratch)

sudo buildah "${BSTORE[@]}" add "$container" "$ROOTFS" /

env_keys=$(yq eval '.environment | keys | .[]' "$CONFIG" 2>/dev/null || true)
for key in $env_keys; do
  value=$(yq eval ".environment.$key" "$CONFIG")
  sudo buildah "${BSTORE[@]}" config --env "$key=$value" "$container"
done

sudo buildah "${BSTORE[@]}" config \
  --user "${ENTRYPOINT_UID}" \
  --entrypoint "[\"$ENTRYPOINT\"]" \
  "$container"

sudo buildah "${BSTORE[@]}" commit --format oci "$container" "$TAG"

# Save as a docker-archive so the build output is a single, docker-loadable tar
# - the same format apko emits - so one set of tooling (docker load / syft /
# dockle / buildah pull docker-archive) works for both build paths. The image
# pushed to the registry is still OCI (see the push step); this only affects the
# local archive.
#
# Remove any previous archive first: the docker-archive transport appends to an
# existing file rather than overwriting it ("doesn't support modifying existing
# images"), which breaks repeated local builds.
echo "[+] Saving docker-archive"
sudo rm -f "$OUT"
sudo buildah "${BSTORE[@]}" push "$TAG" "docker-archive:$OUT:$TAG"
echo "[+] Done: $TAG"
