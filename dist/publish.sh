#!/usr/bin/env bash
# Publish the current release to the pacman repo at https://omarchy-zfs.com/repo/any.
#
# This replaced the AUR flow in October 2026: the AUR deleted omarchy-zfs
# because it requires Omarchy at runtime, and Omarchy only ships from a
# third-party repo. A package that needs a third-party repo belongs in one.
#
# Flow: bump pkgver, commit, `git tag -s vX.Y.Z`, then run this. It builds
# the package from the tagged tree, signs the package and the repo database
# with the release key, drops them into the sibling omarchy-zfs.com checkout,
# and commits there. GitHub Pages serves the result. Pushing is left to you.
#
# Usage: dist/publish.sh [--site DIR] [--no-commit]
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

site="$repo_root/../omarchy-zfs.com"
commit=1
while (( $# )); do
  case $1 in
    --site) site=$2; shift 2 ;;
    --no-commit) commit=0; shift ;;
    *) echo "usage: $0 [--site DIR] [--no-commit]" >&2; exit 2 ;;
  esac
done

source dist/lib.sh
repo_init "$site"

pkgname=$(sed -n 's/^pkgname=//p' PKGBUILD)
pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
pkgrel=$(sed -n 's/^pkgrel=//p' PKGBUILD)
tag="v$pkgver"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
  echo "error: tag $tag does not exist; tag the release first" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "error: working tree not clean" >&2; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse "$tag^{commit}") ]] || {
  echo "error: HEAD is not at $tag; a published build must match the tag" >&2; exit 1; }

# The bootstrap embeds the public key; refuse to publish if it drifted.
embedded_fpr=$(sed -n '/^-----BEGIN PGP PUBLIC KEY BLOCK-----/,/^-----END PGP PUBLIC KEY BLOCK-----/p' \
  bin/omarchy-bootstrap-zfs | gpg --with-colons --import-options show-only --import 2>/dev/null \
  | awk -F: '/^fpr/{print $10; exit}')
[[ $embedded_fpr == "$key_fpr" ]] || {
  echo "error: key embedded in bin/omarchy-bootstrap-zfs is ${embedded_fpr:-missing}, expected $key_fpr" >&2
  exit 1; }

echo ">>> building $pkgname $pkgver-$pkgrel"
rm -f "$pkgname-$pkgver-$pkgrel"-*.pkg.tar.*
PKGDEST="$repo_root" makepkg -f --noconfirm --sign --key "$key_fpr"
pkgfile=
for f in "$pkgname-$pkgver-$pkgrel"-*.pkg.tar.{zst,xz}; do
  [[ -f $f ]] && { pkgfile=$f; break; }
done
[[ -n $pkgfile && -f $pkgfile.sig ]] || { echo "error: build or signature missing" >&2; exit 1; }

echo ">>> updating repo at $repo_dir"
repo_add_packages "$pkgfile"

if (( commit )); then
  echo ">>> committing in $site"
  repo_commit "Publish $pkgname $pkgver-$pkgrel"
  echo ">>> done. Push $site to deploy, and push the $tag tag here."
else
  echo ">>> --no-commit: changes left staged-free in $site"
fi
