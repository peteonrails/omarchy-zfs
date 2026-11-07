#!/usr/bin/env bash
# Build the omarchy-zfs ISO: the official Omarchy ISO plus a root-on-ZFS +
# ZFSBootMenu install path, ZFS in the live environment, and all ZFS packages
# baked into the offline mirror.
#
# One command:   iso/build.sh
# Output:        iso/out/omarchy-zfs-*.iso
#
# Host requirements: docker (privileged builds), git, ~15GB free disk.
# Extra args are passed through to upstream's omarchy-iso-make
# (e.g. --no-cache). Override the upstream pin with OMARCHY_ISO_UPSTREAM_REF.
#
# How it works: clones omacom-io/omarchy-iso at the ref pinned in
# iso/UPSTREAM_REF, overlays iso/overlay/, injects builder/build-zfs-packages.sh
# into the stock build via anchored edits (failing loudly if upstream moved the
# anchors), and runs the stock build. Upstream stays unforked.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$here")"
upstream_url="https://github.com/omacom-io/omarchy-iso.git"
ref="${OMARCHY_ISO_UPSTREAM_REF:-$(cat "$here/UPSTREAM_REF")}"
work="$here/.work/omarchy-iso"
out="$here/out"
mkdir -p "$out"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

say "Syncing upstream omarchy-iso @ $ref"
if [[ ! -d $work/.git ]]; then
  mkdir -p "$work"
  git clone "$upstream_url" "$work"
fi
git -C "$work" fetch origin
# The checkout carries the previous build's anchored edits. It is ours and
# re-patched below every run, so a re-pin must discard them, or git refuses
# to switch commits.
git -C "$work" checkout --force --detach "$ref"
git -C "$work" reset --hard "$ref"
git -C "$work" clean -fdx

say "Applying omarchy-zfs overlay"
cp -r "$here/overlay/." "$work/"

# The bootstrap ships in the live environment; the full checkout ships in the
# builder so the container builds the omarchy-zfs package from this working
# tree (not the AUR), keeping ISO and repo in lockstep.
install -Dm755 "$repo_root/bin/omarchy-bootstrap-zfs" \
  "$work/configs/airootfs/usr/local/bin/omarchy-bootstrap-zfs"
mkdir -p "$work/builder/omarchy-zfs-src"
tar -C "$repo_root" \
  --exclude=.git --exclude=iso --exclude='*.pkg.tar.*' \
  --exclude=pkg --exclude=src \
  -cf - . | tar -xf - -C "$work/builder/omarchy-zfs-src"

say "Patching upstream build (anchored edits)"

# 1. profiledef.sh: declare our executables or upstream's permission lint
#    fails the build before it starts.
cat >> "$work/configs/profiledef.sh" <<'EOF'

# omarchy-zfs additions
file_permissions+=(
  ["/usr/local/bin/omarchy-zfs-install"]="0:0:755"
  ["/usr/local/bin/omarchy-bootstrap-zfs"]="0:0:755"
)
EOF

# 2. build-iso.sh: run our injector right before mkarchiso (after the offline
#    mirror is assembled and the airootfs pacman.conf is in place).
#    Since 4.5 the comment runs on ("# Build the ISO. profiledef.sh reads
#    OMARCHY_ARCH ..."), so match the line by its prefix, and insist on
#    exactly one. By this point upstream has pruned its offline mirror and
#    copied pacman-offline.conf into the live root, so neither undoes ours.
anchor='# Build the ISO.'
[[ $(grep -c '^# Build the ISO\.' "$work/builder/build-iso.sh") == 1 ]] || {
  echo "ERROR: anchor '$anchor' not found exactly once in upstream build-iso.sh — upstream moved; re-pin and adjust." >&2
  exit 1
}
sed -i '/^# Build the ISO\./i bash /builder/build-zfs-packages.sh "$build_cache_dir"\n' \
  "$work/builder/build-iso.sh"

#    ...and hard-verify the zfs module after mkarchiso: the dkms hook only
#    WARNS when the module fails to compile against the live kernel, and a
#    live env without zfs.ko must never ship (observed with archzfs's
#    zfs 2.3.3 vs linux-t2 7.1.8). The live kernel is linux-omarchy since
#    4.5, so that is the module tree that has to have it.
anchor3='"$mkarchiso_command" -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"'
grep -qF "$anchor3" "$work/builder/build-iso.sh" || {
  echo "ERROR: mkarchiso anchor not found in upstream build-iso.sh — upstream moved; re-pin and adjust." >&2
  exit 1
}
cat >> "$work/builder/build-iso.sh" <<'EOF'

# [zfs] fail the build if the live env has no zfs kernel module
if ! ls "$build_cache_dir"/work/x86_64/airootfs/usr/lib/modules/*-omarchy/updates/dkms/zfs.ko* >/dev/null 2>&1; then
  echo "ERROR: [zfs] no zfs.ko for linux-omarchy in the live airootfs — the dkms build failed (check the dkms warnings above)" >&2
  exit 1
fi
echo ">>> [zfs] verified: zfs kernel module present for linux-omarchy in live airootfs"
EOF

# 3. .automated_script.sh: offer the ZFS path ahead of the stock configurator.
#    Times out to "No" so cidata/unattended installs behave exactly like stock.
boot_script="$work/configs/airootfs/root/.automated_script.sh"
anchor2='if /usr/local/bin/omarchy-cidata-load; then'
grep -qF "$anchor2" "$boot_script" || {
  echo "ERROR: anchor '$anchor2' not found in upstream .automated_script.sh — upstream moved; re-pin and adjust." >&2
  exit 1
}
python3 - "$boot_script" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "if /usr/local/bin/omarchy-cidata-load; then"
zfs_offer = """# omarchy-zfs: offer the root-on-ZFS + ZFSBootMenu install path. Unattended
# media always carry a cidata drive, so skip the offer instantly for them;
# an interactive boot has a human and waits for an answer (a 15s timeout
# cost a real user their choice in validation). Only offer it when the booted
# kernel has a zfs module: ZFS is built for linux-omarchy, and a Mac boots
# linux-t2 instead.
if lsblk -no LABEL 2>/dev/null | grep -qx cidata; then
  : # autoinstall drive present — stock unattended flow untouched
elif ! modinfo zfs >/dev/null 2>&1; then
  : # no zfs module for this live kernel — stock flow only
elif gum confirm --default=false "Install with root-on-ZFS + ZFSBootMenu (experimental)?"; then
  exec /usr/local/bin/omarchy-zfs-install
fi

"""
text = text.replace(anchor, zfs_offer + anchor, 1)
open(path, "w").write(text)
PYEOF

say "Building via upstream omarchy-iso-make"
(cd "$work" && ./bin/omarchy-iso-make --keep-pkg-cache --no-boot-offer "$@")

say "Collecting output"
built=$(ls -t "$work/release"/*.iso | head -n1)
final="$out/omarchy-zfs-${built##*/omarchy-}"
mv "$built" "$final"
printf '\n\033[1;32m✓ %s\033[0m\n' "$final"
