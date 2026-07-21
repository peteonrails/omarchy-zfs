#!/bin/bash

# Curl entry point for the omarchy-on-zfs bootstrap from an Arch live ISO.
#
# Usage (from the Arch live ISO, as root):
#   curl -fsSL https://raw.githubusercontent.com/peteonrails/omarchy-on-zfs/omarchy-zfs/bootstrap/iso-zfs.sh | bash
#
# Env overrides (rarely needed):
#   OMARCHY_BOOTSTRAP_REPO   git URL (default: peteonrails/omarchy-on-zfs)
#   OMARCHY_BOOTSTRAP_BRANCH git branch (default: omarchy-zfs)
#   OMARCHY_BOOTSTRAP_DIR    clone target (default: /root/omarchy-on-zfs)

set -euo pipefail

REPO="${OMARCHY_BOOTSTRAP_REPO:-https://github.com/peteonrails/omarchy-on-zfs.git}"
BRANCH="${OMARCHY_BOOTSTRAP_BRANCH:-omarchy-zfs}"
TARGET="${OMARCHY_BOOTSTRAP_DIR:-/root/omarchy-on-zfs}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: must run as root from the Arch live ISO" >&2
  exit 1
fi

if ! command -v git &>/dev/null; then
  pacman -Sy --noconfirm --needed git
fi

if [[ -d $TARGET/.git ]]; then
  echo "Repo already at $TARGET — refreshing"
  git -C "$TARGET" fetch origin "$BRANCH"
  git -C "$TARGET" checkout "$BRANCH"
  git -C "$TARGET" reset --hard "origin/$BRANCH"
else
  git clone --branch "$BRANCH" "$REPO" "$TARGET"
fi

exec bash "$TARGET/bin/omarchy-bootstrap-zfs" "$@"
