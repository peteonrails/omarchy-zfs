#!/bin/bash

# Curl entry point for the omarchy-zfs bootstrap from a live ISO.
#
# Usage (from a ZFS-capable Arch live ISO, as root):
#   curl -fsSL https://omarchy-zfs.com/install | bash
#   # or:
#   curl -fsSL https://raw.githubusercontent.com/peteonrails/omarchy-zfs/main/bootstrap/iso-zfs.sh | bash
#
# Env overrides (rarely needed):
#   OMARCHY_BOOTSTRAP_REPO   git URL (default: peteonrails/omarchy-zfs)
#   OMARCHY_BOOTSTRAP_REF    git branch or tag (default: main)
#   OMARCHY_BOOTSTRAP_DIR    clone target (default: /root/omarchy-zfs)

set -euo pipefail

REPO="${OMARCHY_BOOTSTRAP_REPO:-https://github.com/peteonrails/omarchy-zfs.git}"
REF="${OMARCHY_BOOTSTRAP_REF:-main}"
TARGET="${OMARCHY_BOOTSTRAP_DIR:-/root/omarchy-zfs}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: must run as root from a live ISO" >&2
  exit 1
fi

if ! command -v git &>/dev/null; then
  pacman -Sy --noconfirm --needed git
fi

if [[ -d $TARGET/.git ]]; then
  echo "Repo already at $TARGET — refreshing"
  git -C "$TARGET" fetch origin "$REF"
  git -C "$TARGET" checkout "$REF"
  git -C "$TARGET" reset --hard "origin/$REF" 2>/dev/null || true  # tags have no origin/ ref
else
  git clone --branch "$REF" "$REPO" "$TARGET"
fi

exec bash "$TARGET/bin/omarchy-bootstrap-zfs" "$@"
