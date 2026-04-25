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

echo "[+] Installing packages"
sudo chroot "$ROOTFS" apt-get update
PKGS=$(yq '.packages[]' $CONFIG | tr '\n' ' ')
sudo chroot "$ROOTFS" apt-get install -y --no-install-recommends $PKGS

echo "[+] Cleaning"
sudo chroot "$ROOTFS" apt-get clean
sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*

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

echo "[+] Building OCI image with buildah"

container=$(sudo buildah from scratch)

sudo buildah add $container "$ROOTFS" /

env_keys=$(yq eval '.environment | keys | .[]' "$CONFIG" 2>/dev/null || true)
for key in $env_keys; do
  value=$(yq eval ".environment.$key" "$CONFIG")
  sudo buildah config --env "$key=$value" "$container"
done

sudo buildah config \
  --user "${ENTRYPOINT_UID}" \
  --entrypoint "[\"$ENTRYPOINT\"]" \
  $container

sudo buildah commit $container "$TAG"

echo "[+] Saving OCI archive"
sudo buildah push "$TAG" "oci-archive:$OUT"
RES=$(docker load -i "$OUT")
IMAGE_SHA=${RES##*sha256:}
docker tag "${IMAGE_SHA}" "$TAG"
echo "[+] Done: $TAG"
