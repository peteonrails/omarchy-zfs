#!/bin/bash
# omarchy-zfs ISO: runs inside the build container, injected into
# builder/build-iso.sh right before mkarchiso by iso/build.sh.
#
# Adds everything ZFS to the stock Omarchy ISO build:
#   1. archzfs repo for the build container + the airootfs install
#   2. ZFS in the live environment (zfs-dkms built against linux-t2)
#   3. a second offline mirror [zfs-offline] carrying the target-side ZFS
#      stack: linux-lts + zfs-linux-lts (atomic pairing), omarchy-zfs and
#      its AUR-only deps (sanoid, perl-config-inifiles) built here
#   4. the prebuilt ZFSBootMenu EFI, baked in for fully offline installs
#
# Usage: build-zfs-packages.sh <build_cache_dir>
set -euo pipefail

build_cache_dir="$1"
[[ -d $build_cache_dir ]] || { echo "usage: $0 <build_cache_dir>" >&2; exit 1; }

zfs_repo_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/zfs"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p "$zfs_repo_dir"

echo ">>> [zfs] configuring archzfs repo"
archzfs_block='
[archzfs]
SigLevel = Never
Server = https://archzfs.com/$repo/$arch
Server = https://zxcvfdsa.com/archzfs/$repo/$arch
'
for conf in /etc/pacman.conf "$build_cache_dir/pacman.conf"; do
  [[ -f $conf ]] || continue
  grep -q '^\[archzfs\]' "$conf" || echo "$archzfs_block" >> "$conf"
done

echo ">>> [zfs] adding ZFS to the live environment package list"
# zfs-dkms builds against linux-t2 (the kernel the live ISO boots) during
# mkarchiso's airootfs install; headers must be present for the dkms hook.
for pkg in zfs-dkms zfs-utils linux-t2-headers; do
  grep -qxF "$pkg" "$build_cache_dir/packages.x86_64" ||
    echo "$pkg" >> "$build_cache_dir/packages.x86_64"
done

echo ">>> [zfs] building AUR-source packages (omarchy-zfs, sanoid, perl-config-inifiles)"
if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
build_work=/tmp/zfs-pkg-build
rm -rf "$build_work"
mkdir -p "$build_work"
chown builder:builder "$build_work"

build_one() {
  # $1 = package name, $2 = source dir (a ready PKGBUILD checkout)
  local name="$1" src="$2" dst="$build_work/$1"
  cp -a "$src" "$dst"
  chown -R builder:builder "$dst"
  # All three packages are arch=any script bundles; the one build-time dep
  # (perl-module-build) is preinstalled above, so --nodeps is safe. Runtime
  # deps resolve at install time across the two offline repos.
  # --nocheck: perl-config-inifiles ships tests broken under current perl;
  # upstream Arch would patch them, we just skip the suite.
  su builder -c "cd '$dst' && PKGDEST='$build_work' makepkg --noconfirm --nodeps --nocheck -f"
}

# perl-module-build: perl-config-inifiles' makedepends (Build.PL needs it).
pacman --noconfirm -Sy --needed git base-devel perl-module-build >/dev/null

# omarchy-zfs comes from the local checkout baked in by iso/build.sh — the ISO
# always carries the exact working-tree version, not whatever the AUR has.
build_one omarchy-zfs /builder/omarchy-zfs-src

for aur_pkg in perl-config-inifiles sanoid; do
  su builder -c "git clone --depth=1 'https://aur.archlinux.org/$aur_pkg.git' '$build_work/$aur_pkg-aur'"
  build_one "$aur_pkg" "$build_work/$aur_pkg-aur"
done

cp "$build_work"/*.pkg.tar.* "$zfs_repo_dir/"

echo ">>> [zfs] downloading target-side ZFS stack into the zfs mirror"
# zfs-dkms, NOT zfs-linux-lts: archzfs's prebuilt kernel modules hard-pin an
# exact linux-lts version that Arch's repos rotate out within weeks, which
# makes the download unresolvable (observed: zfs-linux-lts wanting
# linux-lts=6.12.29-1). DKMS floats: the mirror's linux + linux-headers and
# archzfs's zfs-dkms are mutually consistent at build time, and on the
# installed system omarchy-zfs's kernel guard prevents future skew.
# The rest are omarchy-zfs/sanoid runtime deps not guaranteed to be in the
# stock offline mirror's closure.
zfs_target_packages=(
  linux linux-headers
  zfs-dkms zfs-utils
  perl-capture-tiny perl-list-moreutils perl-io-stringy libunwind
  efibootmgr dosfstools iwd
)
rm -rf /tmp/zfsdb
mkdir -p /tmp/zfsdb
pacman --noconfirm -Syw "${zfs_target_packages[@]}" \
  --cachedir "$zfs_repo_dir/" --dbpath /tmp/zfsdb

# Drop anything the stock offline mirror already carries (dep closure overlap)
# so the ISO doesn't ship the same package twice. Signatures are useless in a
# SigLevel=Never repo; drop them too.
rm -f "$zfs_repo_dir"/*.sig
for f in "$zfs_repo_dir"/*.pkg.tar.*; do
  base="${f##*/}"
  if [[ -e "$offline_mirror_dir/$base" ]]; then
    rm -f "$f"
  fi
done

echo ">>> [zfs] indexing [zfs-offline] repo"
rm -f "$zfs_repo_dir"/zfs-offline.db* "$zfs_repo_dir"/zfs-offline.files*
find "$zfs_repo_dir" -name '*.pkg.tar.*' ! -name '*.sig' -print0 |
  xargs -0 repo-add "$zfs_repo_dir/zfs-offline.db.tar.gz"

# The live/airootfs pacman.conf is the offline conf copied just above our
# injection point; add the second mirror so pacstrap resolves across both.
airootfs_conf="$build_cache_dir/airootfs/etc/pacman.conf"
if ! grep -q '^\[zfs-offline\]' "$airootfs_conf"; then
  cat >> "$airootfs_conf" <<'EOF'

[zfs-offline]
SigLevel = Never
Server = file:///var/cache/omarchy/mirror/zfs
EOF
fi

echo ">>> [zfs] baking in the ZFSBootMenu EFI image"
zbm_dir="$build_cache_dir/airootfs/usr/share/omarchy-zfs/zbm"
mkdir -p "$zbm_dir"
curl -fsSL --location -o "$zbm_dir/vmlinuz.EFI" "https://get.zfsbootmenu.org/efi"
[[ -s "$zbm_dir/vmlinuz.EFI" ]] || { echo "ERROR: ZBM EFI download is empty" >&2; exit 1; }

echo ">>> [zfs] done"
