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

echo ">>> [zfs] adding ZFS to the live environment package list"
# zfs-dkms-git, NOT archzfs's zfs-dkms: the live ISO boots linux-t2 tracking
# current Arch kernels (7.x), and archzfs's zfs release lags them — observed:
# dkms install zfs/2.3.3 -k 7.1.8-...-t2 exited 1, a WARNING pacman ignores,
# shipping a live env with no zfs module. AUR git HEAD tracks new kernels
# (same reason the workstation runs zfs-dkms-git). The module builds during
# mkarchiso's airootfs install; headers must be present for the dkms hook,
# and build.sh hard-verifies zfs.ko afterwards.
for pkg in zfs-dkms-git zfs-utils-git linux-t2-headers; do
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
# python trio: zfs-utils-git's makedepends.
pacman --noconfirm -Sy --needed git base-devel perl-module-build \
  python python-cffi python-setuptools >/dev/null

# omarchy-zfs comes from the local checkout baked in by iso/build.sh — the ISO
# always carries the exact working-tree version, not whatever the AUR has.
build_one omarchy-zfs /builder/omarchy-zfs-src

for aur_pkg in perl-config-inifiles sanoid zfs-utils-git zfs-dkms-git perl-boolean zfsbootmenu; do
  su builder -c "git clone --depth=1 'https://aur.archlinux.org/$aur_pkg.git' '$build_work/$aur_pkg-aur'"
  build_one "$aur_pkg" "$build_work/$aur_pkg-aur"
done

# Purge previous builds of these packages from the persistent mirror cache
# first: the -git pair hard-pins exact pkgvers (zfs-dkms-git requires
# zfs-utils-git=<same rev>), so a stale copy from an earlier run poisons
# dependency resolution. Same pattern as upstream build-omarchy-packages.sh.
for stale in omarchy-zfs perl-config-inifiles sanoid zfs-utils-git zfs-dkms-git perl-boolean zfsbootmenu; do
  rm -f "$zfs_repo_dir/$stale"-[0-9]*.pkg.tar.* "$zfs_repo_dir/$stale"-[0-9]*.pkg.tar.*.sig
  # Also the pacman cache (bind-mounted from the host): a rebuild at the same
  # git rev produces same-name different-bytes packages, and pacman then
  # rejects the stale cached copy against the new db checksum ("invalid or
  # corrupted package"), failing the airootfs install.
  rm -f "/var/cache/pacman/pkg/$stale"-[0-9]*.pkg.tar.*
done
cp "$build_work"/*.pkg.tar.* "$zfs_repo_dir/"

echo ">>> [zfs] downloading target-side ZFS stack into the zfs mirror"
# The target's zfs comes from the zfs-*-git packages built above (DKMS floats
# with the kernel; archzfs's prebuilt modules and even its zfs-dkms release
# lag Arch kernels too much to bake into an ISO). This list is the remaining
# closure: headers for the target kernel plus omarchy-zfs/sanoid runtime deps
# not guaranteed to be in the stock offline mirror.
zfs_target_packages=(
  linux linux-headers dkms
  perl-capture-tiny perl-list-moreutils perl-io-stringy libunwind
  efibootmgr dosfstools iwd
  # zfsbootmenu runtime deps not in the stock mirror closure (perl-boolean is
  # AUR-built above; openssl/ncurses/bash are already in base)
  kexec-tools fzf mbuffer perl-sort-versions perl-yaml-pp
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

# Three confs need the [zfs-offline] repo:
#   - airootfs/etc/pacman.conf: the booted live env + its pacstrap
#   - pacman-offline.conf: profiledef.sh pins mkarchiso's airootfs install to
#     it, so the live-env zfs packages above resolve from here
# And like upstream's offline mirror, the file:// URL must resolve inside the
# container, hence the symlink.
ln -sfn "$zfs_repo_dir" /var/cache/omarchy/mirror/zfs
for conf in "$build_cache_dir/airootfs/etc/pacman.conf" "$build_cache_dir/pacman-offline.conf"; do
  grep -q '^\[zfs-offline\]' "$conf" || cat >> "$conf" <<'EOF'

[zfs-offline]
SigLevel = Never
Server = file:///var/cache/omarchy/mirror/zfs
EOF
done

echo ">>> [zfs] baking in the ZFSBootMenu EFI image"
zbm_dir="$build_cache_dir/airootfs/usr/share/omarchy-zfs/zbm"
mkdir -p "$zbm_dir"
curl -fsSL --location -o "$zbm_dir/vmlinuz.EFI" "https://get.zfsbootmenu.org/efi"
[[ -s "$zbm_dir/vmlinuz.EFI" ]] || { echo "ERROR: ZBM EFI download is empty" >&2; exit 1; }

echo ">>> [zfs] done"
