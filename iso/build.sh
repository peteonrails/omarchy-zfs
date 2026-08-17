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
git -C "$work" checkout --detach "$ref"
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
anchor='# Build the ISO.'
grep -qxF "$anchor" "$work/builder/build-iso.sh" || {
  echo "ERROR: anchor '$anchor' not found in upstream build-iso.sh — upstream moved; re-pin and adjust." >&2
  exit 1
}
sed -i "s|^# Build the ISO\.\$|bash /builder/build-zfs-packages.sh \"\$build_cache_dir\"\n\n# Build the ISO.|" \
  "$work/builder/build-iso.sh"

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
zfs_offer = """# omarchy-zfs: offer the root-on-ZFS + ZFSBootMenu install path. Defaults to
# "No" after 15s so unattended (cidata) installs run the stock path untouched.
if gum confirm --timeout 15s --default=false "Install with root-on-ZFS + ZFSBootMenu (experimental)?"; then
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
