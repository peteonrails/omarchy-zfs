#!/usr/bin/env bash
# Mirror the AUR-only runtime dependencies of omarchy-zfs into the repo at
# https://omarchy-zfs.com/repo/any, so a plain `pacman -S omarchy-zfs` resolves.
#
# sanoid and perl-config-inifiles live only in the AUR. Each is built from the
# AUR commit pinned in dist/mirror/packages.txt, inside a throwaway Arch
# container so the host needs none of their build dependencies, then signed
# with the release key on the host and added to the repo database.
#
# Usage: dist/mirror.sh [--site DIR] [--no-commit] [--only NAME]
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"
source dist/lib.sh

site="$repo_root/../omarchy-zfs.com"
commit=1
only=
while (( $# )); do
  case $1 in
    --site) site=$2; shift 2 ;;
    --no-commit) commit=0; shift ;;
    --only) only=$2; shift 2 ;;
    *) echo "usage: $0 [--site DIR] [--no-commit] [--only NAME]" >&2; exit 2 ;;
  esac
done
repo_init "$site"
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/out"

names=()
while read -r name rev; do
  [[ -z $name || $name == \#* ]] && continue
  [[ -n $only && $only != "$name" ]] && continue
  echo ">>> fetching AUR $name @ ${rev:0:12}"
  git clone -q "https://aur.archlinux.org/$name.git" "$work/src/$name"
  git -C "$work/src/$name" checkout -q "$rev"
  names+=("$name")
done < dist/mirror/packages.txt
(( ${#names[@]} )) || { echo "error: nothing to build" >&2; exit 1; }

# One container builds them all in listed order; each build's output is
# installed before the next so later packages resolve earlier ones. The
# sources go in and results come out with `docker cp`, which writes them as
# the invoking user whether the daemon is rootless or not; a bind mount would
# leave the output owned by a subordinate uid, and a read-only bind mount
# breaks `docker cp` on a stopped rootless container.
# --nocheck: perl-config-inifiles ships tests broken under current perl.
echo ">>> building in an Arch container: ${names[*]}"
cid=$(docker create \
  -e "NAMES=${names[*]}" \
  archlinux:latest bash -euo pipefail -c '
    pacman -Syu --noconfirm --needed base-devel git >/dev/null
    useradd -m builder
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
    mkdir -p /out && chown builder /out
    for name in $NAMES; do
      echo ">>> [container] $name"
      cp -a "/src/$name" "/tmp/$name"
      chown -R builder:builder "/tmp/$name"
      su builder -c "cd /tmp/$name && PKGDEST=/out makepkg -s --noconfirm --nocheck -f"
      pacman -U --noconfirm /out/"$name"-*.pkg.tar.* >/dev/null
    done
  ')
trap 'docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$work"' EXIT
docker cp "$work/src/." "$cid:/src/"
docker start -a "$cid"
docker cp "$cid:/out/." "$work/out/"
docker rm "$cid" >/dev/null

built=("$work"/out/*.pkg.tar.*)
[[ -f ${built[0]} ]] || { echo "error: the container produced no packages" >&2; exit 1; }
echo ">>> signing and adding: ${built[*]##*/}"
repo_add_packages "${built[@]}"

if (( commit )); then
  repo_commit "Mirror ${names[*]} from the AUR"
  echo ">>> done. Push $site to deploy."
else
  echo ">>> --no-commit: $site/repo updated, not committed"
fi
