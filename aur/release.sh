#!/usr/bin/env bash
# Publish the current release to the AUR.
#
# Flow: tag vX.Y.Z on GitHub first (the tarball must exist), then run this.
# It derives the AUR PKGBUILD from the canonical repo PKGBUILD (only the
# source= line differs), fills in checksums, regenerates .SRCINFO, test-builds,
# and pushes to ssh://aur@aur.archlinux.org/omarchy-zfs.git.
#
# Usage: aur/release.sh [--no-push]
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

pkgname=$(sed -n 's/^pkgname=//p' PKGBUILD)
pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
tag="v$pkgver"

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "error: tag $tag does not exist — tag and push the release first" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo ">>> cloning AUR repo"
git clone "ssh://aur@aur.archlinux.org/${pkgname}.git" "$workdir/aur"

echo ">>> generating AUR PKGBUILD from repo PKGBUILD"
sed 's|^source=()$|source=("$pkgname-$pkgver.tar.gz::https://github.com/peteonrails/omarchy-zfs/archive/refs/tags/v$pkgver.tar.gz")\nsha256sums=('"'"'SKIP'"'"')|' \
  PKGBUILD > "$workdir/aur/PKGBUILD"
grep -q 'archive/refs/tags' "$workdir/aur/PKGBUILD" || {
  echo "error: source= substitution failed — PKGBUILD layout changed?" >&2
  exit 1
}
cp "${pkgname}.install" "$workdir/aur/"

cd "$workdir/aur"
echo ">>> filling in checksums"
updpkgsums

echo ">>> test build"
makepkg -f --noconfirm
namcap -i ./*.pkg.tar.* PKGBUILD || true   # advisory only

echo ">>> regenerating .SRCINFO"
makepkg --printsrcinfo > .SRCINFO

git add PKGBUILD .SRCINFO "${pkgname}.install"
git -c commit.gpgsign=true commit -S -m "Update to $pkgver"

if [[ "${1:-}" == "--no-push" ]]; then
  echo ">>> --no-push: AUR repo left at $workdir/aur (trap disabled)"
  trap - EXIT
else
  git push origin master
  echo ">>> pushed: https://aur.archlinux.org/packages/${pkgname}"
fi
