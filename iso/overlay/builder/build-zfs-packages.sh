#!/bin/bash
# omarchy-zfs ISO: runs inside the build container, injected into
# builder/build-iso.sh right before mkarchiso by iso/build.sh.
#
# Adds everything ZFS to the stock Omarchy ISO build:
#   1. ZFS in the live environment (zfs-dkms built against linux-omarchy)
#   2. a second offline mirror [zfs-offline] carrying the target-side ZFS
#      stack: zfs-dkms + zfs-utils, linux-omarchy-headers, omarchy-zfs and
#      its AUR-only deps (sanoid, perl-config-inifiles), zfsbootmenu
#   3. the prebuilt ZFSBootMenu EFI, baked in for fully offline installs
#
# Usage: build-zfs-packages.sh <build_cache_dir>
set -euo pipefail

build_cache_dir="$1"
[[ -d $build_cache_dir ]] || { echo "usage: $0 <build_cache_dir>" >&2; exit 1; }

zfs_repo_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/zfs"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
# What the ISO's stock mirror actually ships. Since 4.5 the build cache holds
# every package, but only the ones the root image does not already contain go
# on the ISO, listed here. De-duplicating against the cache dropped
# linux-omarchy-headers from [zfs-offline] while the stock mirror did not
# ship it either.
shipped_list="$build_cache_dir/airootfs/usr/share/omarchy-iso/offline-mirror.shipped"
# Rebuilt from scratch every time: the repo lives in the persistent build
# cache, and leftovers from earlier builds (two versions of one package, old
# -git debug packages) let repo-add index the wrong copy.
rm -rf "$zfs_repo_dir"
mkdir -p "$zfs_repo_dir"

echo ">>> [zfs] adding ZFS to the live environment package list"
# Since Omarchy 4.5 the live ISO boots linux-omarchy (linux-t2 only on a Mac),
# and the installer puts linux-omarchy on the target. Both are 7.2 kernels.
# OpenZFS 2.4.4 is the first release whose Linux-Maximum covers 7.2, so the
# release packages replace the zfs-*-git snapshots this ISO used to carry:
# same kernel coverage, and a version that does not move between builds.
# archzfs is no help: its zfs-dkms is still 2.3.3, which builds for no 7.x
# kernel. The module builds during mkarchiso's airootfs install; headers must
# be present for the dkms hook, and build.sh hard-verifies zfs.ko afterwards.
for pkg in zfs-dkms zfs-utils linux-omarchy-headers; do
  grep -qxF "$pkg" "$build_cache_dir/packages.x86_64" ||
    echo "$pkg" >> "$build_cache_dir/packages.x86_64"
done

echo ">>> [zfs] building AUR-source packages (omarchy-zfs, sanoid, zfs, zfsbootmenu)"
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
  # The one build-time dep that is not in base-devel (perl-module-build) is
  # preinstalled below, so --nodeps is safe. Runtime deps resolve at install
  # time across the two offline repos.
  # --nocheck: perl-config-inifiles ships tests broken under current perl;
  # upstream Arch would patch them, we just skip the suite.
  su builder -c "cd '$dst' && PKGDEST='$build_work' makepkg --noconfirm --nodeps --nocheck -f"
}

# perl-module-build: perl-config-inifiles' makedepends (Build.PL needs it).
pacman --noconfirm -Sy --needed git base-devel perl-module-build >/dev/null

# zfs-utils and zfs-dkms verify the OpenZFS release tarball's signature.
# Fetch the two release signers they list (validpgpkeys) for the builder.
for key in 4F3BA9AB6D1F8D683DC2DFB56AD860EED4598027 C33DF142657ED1F7C328A2960AB9E991C6AF658B; do
  su builder -c "gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys $key" ||
    su builder -c "gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys $key"
done

# omarchy-zfs comes from the local checkout baked in by iso/build.sh — the ISO
# always carries the exact working-tree version, not whatever the repo has.
build_one omarchy-zfs /builder/omarchy-zfs-src

for aur_pkg in perl-config-inifiles sanoid zfs-utils zfs-dkms perl-boolean zfsbootmenu; do
  su builder -c "git clone --depth=1 'https://aur.archlinux.org/$aur_pkg.git' '$build_work/$aur_pkg-aur'"
  build_one "$aur_pkg" "$build_work/$aur_pkg-aur"
done

# Purge previous builds of these packages from the persistent mirror cache
# first: zfs-dkms requires zfs-utils=<same version>, so a stale copy from an
# earlier run poisons dependency resolution. Same pattern as upstream
# build-omarchy-packages.sh. The -git names go too, for caches left by ISOs
# built before 4.5.
for stale in omarchy-zfs perl-config-inifiles sanoid zfs-utils zfs-dkms zfs-utils-git zfs-dkms-git perl-boolean zfsbootmenu; do
  rm -f "$zfs_repo_dir/$stale"-[0-9]*.pkg.tar.* "$zfs_repo_dir/$stale"-[0-9]*.pkg.tar.*.sig
  # Also the pacman cache (bind-mounted from the host): a rebuild of the same
  # version produces same-name different-bytes packages, and pacman then
  # rejects the stale cached copy against the new db checksum ("invalid or
  # corrupted package"), failing the airootfs install.
  rm -f "/var/cache/pacman/pkg/$stale"-[0-9]*.pkg.tar.*
done
# makepkg splits out -debug packages when the container's makepkg.conf asks
# for them. Nothing installs those.
find "$build_work" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*-debug-*' -exec cp -t "$zfs_repo_dir/" {} +

echo ">>> [zfs] downloading target-side ZFS stack into the zfs mirror"
# The target's zfs comes from the zfs-dkms/zfs-utils built above, building for
# linux-omarchy in the chroot. This list is the remaining closure: headers for
# the target kernel plus omarchy-zfs/sanoid/zfsbootmenu runtime deps not
# guaranteed to be in the stock offline mirror.
zfs_target_packages=(
  linux-omarchy linux-omarchy-headers dkms
  perl-capture-tiny perl-list-moreutils perl-io-stringy libunwind
  efibootmgr dosfstools iwd
  # zfsbootmenu runtime deps not in the stock mirror closure (perl-boolean is
  # AUR-built above; openssl/ncurses/bash are already in base)
  kexec-tools fzf mbuffer perl-sort-versions perl-yaml-pp
)
# Download from the channel's own config, as upstream's mirror build does, so
# linux-omarchy-headers matches the linux-omarchy in the offline mirror. The
# container's /etc/pacman.conf has [omarchy] too, but default Arch mirrors.
online_conf="/configs/pacman-online-${OMARCHY_MIRROR:-stable}.conf"
[[ -r $online_conf ]] || online_conf=/etc/pacman.conf
rm -rf /tmp/zfsdb
mkdir -p /tmp/zfsdb
pacman --config "$online_conf" --noconfirm -Syw "${zfs_target_packages[@]}" \
  --cachedir "$zfs_repo_dir/" --dbpath /tmp/zfsdb

# Drop anything the stock offline mirror ships (dep closure overlap) so the
# ISO doesn't carry the same package twice. Only what it ships: a file in the
# build cache but not in the shipped list is not on the ISO. Signatures are
# useless in a SigLevel=Never repo; drop them too.
# The download above resolves against an empty db, so it also pulls the whole
# closure (glibc and friends). The root image already holds most of that, and
# upstream leaves a copy of the image's local db behind for exactly this kind
# of question (OMARCHY_IMAGE_LOCALDB_COPY in build-iso.sh). A package the
# image contains at the same version is never installed from here.
image_localdb=/tmp/omarchy-root-image-localdb
declare -A in_image=()
for d in "$image_localdb"/local/*/ "$image_localdb"/*/; do
  [[ -f ${d}desc ]] && in_image[$(basename "$d")]=1
done
echo ">>> [zfs] root image db: ${#in_image[@]} packages"
rm -f "$zfs_repo_dir"/*.sig
for f in "$zfs_repo_dir"/*.pkg.tar.*; do
  base="${f##*/}"
  stem="${base%-*.pkg.tar.*}"   # name-pkgver-pkgrel
  if [[ -v in_image[$stem] ]]; then
    rm -f "$f"
  elif [[ -r $shipped_list ]]; then
    if grep -qxF "$base" "$shipped_list"; then rm -f "$f"; fi
  elif [[ -e "$offline_mirror_dir/$base" ]]; then
    rm -f "$f"
  fi
done

echo ">>> [zfs] indexing [zfs-offline] repo"
rm -f "$zfs_repo_dir"/zfs-offline.db* "$zfs_repo_dir"/zfs-offline.files*
find "$zfs_repo_dir" -name '*.pkg.tar.*' ! -name '*.sig' -print0 |
  xargs -0 repo-add "$zfs_repo_dir/zfs-offline.db.tar.gz"

# Two confs need the [zfs-offline] repo:
#   - airootfs/etc/pacman.conf: the booted live env + its pacstrap
#   - pacman-offline.conf: profiledef.sh pins mkarchiso's airootfs install to
#     it, so the live-env zfs packages above resolve from here
# And like upstream's offline mirror, the file:// URL must resolve inside the
# container, hence the symlink.
#
# [zfs-offline] goes AHEAD of [offline]. Since 4.5 the stock repo's db still
# lists every package (~1200) while the ISO ships only the ~130 the root image
# lacks, and pacman takes a package from the first repo that lists it. Behind
# [offline], iwd and ell resolved to files that are not on the ISO even though
# [zfs-offline] carries both, and the install died there. First, our copies
# win for the handful of packages both repos list.
ln -sfn "$zfs_repo_dir" /var/cache/omarchy/mirror/zfs
zfs_section='[zfs-offline]
SigLevel = Never
Server = file:///var/cache/omarchy/mirror/zfs
'
for conf in "$build_cache_dir/airootfs/etc/pacman.conf" "$build_cache_dir/pacman-offline.conf"; do
  grep -q '^\[zfs-offline\]' "$conf" && continue
  if grep -q '^\[offline\]' "$conf"; then
    awk -v sect="$zfs_section" '/^\[offline\]/ { print sect } { print }' "$conf" > "$conf.zfs"
    mv "$conf.zfs" "$conf"
  else
    printf '\n%s' "$zfs_section" >> "$conf"
  fi
done

echo ">>> [zfs] baking in the ZFSBootMenu EFI image"
zbm_dir="$build_cache_dir/airootfs/usr/share/omarchy-zfs/zbm"
mkdir -p "$zbm_dir"
curl -fsSL --location -o "$zbm_dir/vmlinuz.EFI" "https://get.zfsbootmenu.org/efi"
[[ -s "$zbm_dir/vmlinuz.EFI" ]] || { echo "ERROR: ZBM EFI download is empty" >&2; exit 1; }

echo ">>> [zfs] done"
