#!/bin/bash
set -euo pipefail

CONFIG=$1
TAG=$3

OUT=$2

ROOTFS=./tmp/

echo "[+] Parsing config"
ARCH=$(yq '.arch' $CONFIG)
VERSION=$(yq '.version' $CONFIG)
MIRROR=$(yq '.mirror' $CONFIG)
ENTRYPOINT_UID=$(yq -r '.entrypoint.uid' $CONFIG)
ENTRYPOINT=$(yq -r '.entrypoint.command' $CONFIG)
LOCAL_PKGS=$(PWD=$PWD yq '.arch as $a | .local-packages | map(strenv(PWD) + "/pkg/" + . + "_" + $a + ".deb") | .[]' $CONFIG)

echo "[+] Running debootstrap (reproducible) $VERSION $ROOTFS $MIRROR ${LOCAL_PKGS}"
sudo debootstrap \
  --variant=minbase \
  --arch="$ARCH" \
  --exclude=e2fsprogs,sensible-utils,sysvinit-utils \
  "$VERSION" \
  "$ROOTFS" \
  "$MIRROR"


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
deb http://archive.ubuntu.com/ubuntu ${VERSION} main restricted universe multiverse
deb https://security.ubuntu.com/ubuntu ${VERSION}-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${VERSION}-updates main restricted universe multiverse
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
sudo find "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin" \
  -maxdepth 1 -type f \
  -exec strip --strip-unneeded {} + 2>/dev/null || true

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

echo "[+] Saving OCI archive"
sudo buildah "${BSTORE[@]}" push "$TAG" "oci-archive:$OUT"
echo "[+] Done: $TAG"
