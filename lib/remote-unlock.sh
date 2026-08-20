#!/bin/bash
# shellcheck shell=bash
#
# Shared helpers for omarchy-zfs remote unlock (ZFSBootMenu SSH + network key).
#
# Sourced by:
#   omarchy-zfs-remote-unlock-setup / -remove   (Phase 1: dropbear in ZBM)
#   omarchy-zfs-netkey-setup / -remove          (Phase 2: network key fetch)
#
# Everything here edits ZFSBootMenu's OWN config -- /etc/zfsbootmenu/* -- never
# the OS initramfs config in /etc/mkinitcpio.conf.d. Those are separate images:
# the ZBM image lives on the unencrypted ESP and must never contain the pool
# key; the OS image lives inside the encrypted pool and may embed it.

ZBM_ETC="/etc/zfsbootmenu"
ZBM_CONFIG="$ZBM_ETC/config.yaml"
ZBM_MKINITCPIO="$ZBM_ETC/mkinitcpio.conf"
ZBM_INITCPIO_DIR="$ZBM_ETC/initcpio"
OMARCHY_ZFS_SHARE="/usr/share/omarchy-zfs"

# Markers must be valid comments in BOTH shell (mkinitcpio.conf) and YAML
# (config.yaml). '#' works for both. Every block carries a tag so the two
# features (and the config bits they share) can be added and removed
# independently -- an empty tag would match every block and remove all of them.
marker_begin() { echo "# >>> omarchy-zfs $1 >>>"; }
marker_end()   { echo "# <<< omarchy-zfs $1 <<<"; }

die() {
  echo "Error: $*" >&2
  exit 1
}

warn() { echo "Warning: $*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Remote unlock requires a LOCALLY GENERATED ZBM image. The prebuilt EFI from
# get.zfsbootmenu.org (which omarchy-bootstrap-zfs falls back to) is a fixed
# binary -- there is no way to inject dropbear, a NIC driver or a load-key hook
# into it. Fail loudly with the fix rather than silently doing nothing.
require_local_zbm() {
  if ! command -v generate-zbm &>/dev/null; then
    cat >&2 <<'EOF'
Error: generate-zbm not found.

Remote unlock bakes an SSH server (and/or a key-fetch hook) into the
ZFSBootMenu image, so ZBM must be built on this machine. This install is
using a prebuilt ZBM EFI image, which cannot be modified.

To switch to a locally generated ZBM:

  1. Install ZBM from the AUR:      yay -S zfsbootmenu
  2. Seed its config:               sudo cp /etc/zfsbootmenu/config.yaml.example \
                                            /etc/zfsbootmenu/config.yaml
  3. Rebuild:                       sudo omarchy-refresh-zbm
  4. Reboot and confirm you still reach the ZFSBootMenu prompt
  5. Re-run this command

EOF
    exit 1
  fi

  [[ -f $ZBM_CONFIG ]] || die "$ZBM_CONFIG not found. Copy $ZBM_ETC/config.yaml.example to $ZBM_CONFIG and run 'sudo omarchy-refresh-zbm' first."

  # InitCPIO: true is what makes the mkinitcpio path (and these hooks) apply.
  # A dracut-based ZBM needs entirely different modules, which we don't ship.
  if ! grep -qE '^[[:space:]]*InitCPIO:[[:space:]]*true' "$ZBM_CONFIG"; then
    die "$ZBM_CONFIG does not set 'InitCPIO: true'. omarchy-zfs remote unlock supports the mkinitcpio ZBM path only (see $ZBM_ETC/config.yaml.example)."
  fi
}

# ---------------------------------------------------------------------------
# Managed blocks
# ---------------------------------------------------------------------------

# Every edit we make to a ZBM config file goes between markers so that:
#   * re-running setup is idempotent (block is replaced, never appended twice)
#   * remove restores the file exactly
# $1 = file, $2 = tag (distinguishes remote-unlock from netkey blocks)
managed_block_present() {
  local file="$1" tag="$2"
  [[ -f $file ]] && grep -qF "$(marker_begin "$tag")" "$file"
}

# Strip a managed block from a file. Also un-comments any "original:" line the
# block stashed, restoring the value we overwrote.
managed_block_remove() {
  local file="$1" tag="$2"
  [[ -f $file ]] || return 0
  managed_block_present "$file" "$tag" || return 0

  local begin; begin=$(marker_begin "$tag")
  local end; end=$(marker_end "$tag")

  # Inside the block, a line of the form "#restore:<text>" means <text> is the
  # original content we replaced; emit it in place of the block.
  sudo awk -v b="$begin" -v e="$end" '
    index($0, b) { inblock = 1; next }
    index($0, e) { inblock = 0; next }
    inblock {
      if ($0 ~ /^[[:space:]]*#restore:/) {
        sub(/^[[:space:]]*#restore:/, "")
        print
      }
      next
    }
    { print }
  ' "$file" | sudo tee "$file.omz-new" >/dev/null

  sudo mv "$file.omz-new" "$file"
}

# Insert a managed block immediately after the first line matching $3 (anchor).
# Content comes from stdin. Replaces any existing block with the same tag.
#   managed_block_insert_after <file> <tag> <anchor-regex> <<'EOF'
managed_block_insert_after() {
  local file="$1" tag="$2" anchor="$3"
  local body
  body=$(cat)

  managed_block_remove "$file" "$tag"

  local begin; begin=$(marker_begin "$tag")
  local end; end=$(marker_end "$tag")

  grep -qE "$anchor" "$file" || die "could not find '$anchor' in $file to anchor the $tag block"

  sudo awk -v anchor="$anchor" -v b="$begin" -v e="$end" -v body="$body" '
    { print }
    !done && $0 ~ anchor {
      print b
      print body
      print e
      done = 1
    }
  ' "$file" | sudo tee "$file.omz-new" >/dev/null

  sudo mv "$file.omz-new" "$file"
}

# Append a managed block to the end of a file. Content from stdin.
managed_block_append() {
  local file="$1" tag="$2"
  local body
  body=$(cat)

  managed_block_remove "$file" "$tag"

  {
    marker_begin "$tag"
    echo "$body"
    marker_end "$tag"
  } | sudo tee -a "$file" >/dev/null
}

# ---------------------------------------------------------------------------
# ZBM mkinitcpio.conf
# ---------------------------------------------------------------------------

# ZBM's mkinitcpio.conf is separate from the OS one. If the ZBM package didn't
# ship it, seed a minimal one -- generate-zbm adds the zfsbootmenu hook itself
# via the command line, so HOOKS only needs the boot-time essentials.
ensure_zbm_mkinitcpio_conf() {
  [[ -f $ZBM_MKINITCPIO ]] && return 0

  echo "Seeding $ZBM_MKINITCPIO (ZFSBootMenu's own mkinitcpio config)"
  sudo mkdir -p "$ZBM_ETC"
  sudo tee "$ZBM_MKINITCPIO" >/dev/null <<'EOF'
# ZFSBootMenu mkinitcpio configuration -- SEPARATE from /etc/mkinitcpio.conf.
# Seeded by omarchy-zfs. generate-zbm appends the zfsbootmenu hook itself.
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard)
EOF
}

# Point config.yaml at the ZBM mkinitcpio.conf and add our hook directory to
# the search path. generate-zbm does NOT look in /etc/zfsbootmenu/initcpio
# implicitly -- without InitCPIOHookDirs the hooks are silently ignored and you
# get an image with no dropbear and no warning.
ensure_zbm_hook_dirs() {
  local tag="hookdirs"

  # A hand-rolled ZBM setup may already declare these. Inserting ours anyway
  # would create duplicate YAML keys -- silently last-wins, or a parse error --
  # so defer to the existing config and just check it points somewhere we can
  # install into.
  if ! managed_block_present "$ZBM_CONFIG" "$tag" &&
     grep -qE '^[[:space:]]*InitCPIOHookDirs:' "$ZBM_CONFIG"; then
    echo "$ZBM_CONFIG already sets InitCPIOHookDirs; leaving it alone."
    if ! grep -qF "$ZBM_INITCPIO_DIR" "$ZBM_CONFIG"; then
      die "InitCPIOHookDirs in $ZBM_CONFIG does not include $ZBM_INITCPIO_DIR.
Add it (keeping /usr/lib/initcpio in the list) and re-run -- otherwise
generate-zbm will not find the hooks and will build an image without them:

  InitCPIOHookDirs:
    - $ZBM_INITCPIO_DIR
    - /usr/lib/initcpio"
    fi
    # Same for the config path: we edit $ZBM_MKINITCPIO, so that must be the
    # file generate-zbm actually reads.
    local declared
    declared=$(grep -E '^[[:space:]]*InitCPIOConfig:' "$ZBM_CONFIG" | head -1 | sed 's/.*InitCPIOConfig:[[:space:]]*//')
    if [[ -n $declared && $declared != "$ZBM_MKINITCPIO" ]]; then
      die "$ZBM_CONFIG sets InitCPIOConfig to '$declared', but these tools edit $ZBM_MKINITCPIO.
Point InitCPIOConfig at $ZBM_MKINITCPIO (moving your settings across) and re-run."
    fi
    return 0
  fi

  managed_block_insert_after "$ZBM_CONFIG" "$tag" '^Global:' <<EOF
  InitCPIOConfig: $ZBM_MKINITCPIO
  InitCPIOHookDirs:
    - $ZBM_INITCPIO_DIR
    - /usr/lib/initcpio
EOF
}

# Install a vendored hook pair (install/ + hooks/) into ZBM's hook dir.
# $1 = hook name as mkinitcpio refers to it in HOOKS (e.g. "dropbear")
install_vendored_hook() {
  local name="$1"
  local src="$OMARCHY_ZFS_SHARE/initcpio"

  [[ -f "$src/install/$name" ]] || die "missing $src/install/$name (reinstall omarchy-zfs)"
  [[ -f "$src/hooks/$name" ]]   || die "missing $src/hooks/$name (reinstall omarchy-zfs)"

  sudo install -Dm644 "$src/install/$name" "$ZBM_INITCPIO_DIR/install/$name"
  sudo install -Dm755 "$src/hooks/$name"   "$ZBM_INITCPIO_DIR/hooks/$name"
}

# Add shell array entries (HOOKS/MODULES/BINARIES/FILES) to ZBM's
# mkinitcpio.conf inside one managed block. Pass every line in a single call:
# HOOKS order is load order, so networking must be listed before dropbear.
# Usage: zbm_conf_add <tag> <line> [<line>...]
zbm_conf_add() {
  local tag="$1"; shift
  printf '%s\n' "$@" | managed_block_append "$ZBM_MKINITCPIO" "$tag"
}

# ---------------------------------------------------------------------------
# Kernel command line (config.yaml Kernel: CommandLine:)
# ---------------------------------------------------------------------------

# Append parameters to ZBM's kernel command line, stashing the original so
# remove restores it byte-for-byte. Idempotent.
zbm_cmdline_add() {
  local tag="$1" params="$2"

  # Restore any previous version of our edit first so we never stack params.
  managed_block_remove "$ZBM_CONFIG" "$tag"

  local current
  current=$(grep -E '^[[:space:]]*CommandLine:' "$ZBM_CONFIG" | head -1)
  [[ -n $current ]] || die "no 'CommandLine:' found under Kernel: in $ZBM_CONFIG"

  # Already carries the params (hand-edited)? Leave the file alone.
  if [[ $current == *"$params"* ]]; then
    echo "ZBM kernel command line already contains: $params"
    return 0
  fi

  local indent value
  indent="${current%%[![:space:]]*}"
  value="${current#*CommandLine:}"
  value="${value# }"
  # Strip surrounding quotes if the existing value is quoted.
  value="${value%\"}"; value="${value#\"}"

  local begin; begin=$(marker_begin "$tag")
  local end; end=$(marker_end "$tag")

  # Replace the CommandLine line with a managed block that stashes the original
  # as "#restore:<original line>" so managed_block_remove can put it back.
  sudo awk -v cur="$current" -v b="$begin" -v e="$end" \
           -v new="${indent}CommandLine: \"${value} ${params}\"" '
    !done && $0 == cur {
      print b
      print "  #restore:" cur
      print new
      print e
      done = 1
      next
    }
    { print }
  ' "$ZBM_CONFIG" | sudo tee "$ZBM_CONFIG.omz-new" >/dev/null

  sudo mv "$ZBM_CONFIG.omz-new" "$ZBM_CONFIG"
}

# ---------------------------------------------------------------------------
# Pool / key helpers
# ---------------------------------------------------------------------------

# The pool that hosts the running root filesystem.
root_pool() {
  zfs list -H -o name / 2>/dev/null | cut -d/ -f1
}

# The encryption root for the running system, or empty if unencrypted.
root_encryption_root() {
  local rootds encroot
  rootds=$(zfs list -H -o name / 2>/dev/null) || return 0
  [[ -n $rootds ]] || return 0
  encroot=$(zfs get -H -o value encryptionroot "$rootds" 2>/dev/null)
  [[ $encroot == "-" ]] && return 0
  echo "$encroot"
}

# Absolute path of the pool keyfile, if keylocation is file-based.
pool_keyfile() {
  local encroot loc
  encroot=$(root_encryption_root)
  [[ -n $encroot ]] || return 0
  loc=$(zfs get -H -o value keylocation "$encroot" 2>/dev/null)
  [[ $loc == file://* ]] || return 0
  echo "${loc#file://}"
}

# ---------------------------------------------------------------------------
# Image verification
# ---------------------------------------------------------------------------

# Path of the most recently written ZBM EFI image.
newest_zbm_image() {
  local imagedir
  imagedir=$(grep -E '^[[:space:]]*ImageDir:' "$ZBM_CONFIG" | head -1 | sed 's/.*ImageDir:[[:space:]]*//')
  [[ -n $imagedir ]] || return 0
  sudo find "$imagedir" -maxdepth 1 -type f \( -iname '*.EFI' \) -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -1 | cut -d' ' -f2-
}

# Assert the built ZBM image contains what we asked for -- and NOT the pool key.
# An image that silently lacks dropbear looks fine until the box is in a colo
# and won't answer on 2222, so check before the reboot rather than after.
# Usage: verify_zbm_image <expected-path> [<expected-path>...]
verify_zbm_image() {
  local image
  image=$(newest_zbm_image)

  if [[ -z $image || ! -f $image ]]; then
    warn "could not locate the generated ZBM image; skipping verification"
    return 0
  fi

  if ! command -v lsinitcpio &>/dev/null; then
    warn "lsinitcpio not available; skipping ZBM image verification"
    return 0
  fi

  echo
  echo "Verifying $image"

  local listing rc=0
  # ZBM EFI images are UKIs; lsinitcpio can't read them directly, so pull the
  # initramfs section out with objcopy when available.
  listing=$(lsinitcpio "$image" 2>/dev/null) || listing=""
  if [[ -z $listing ]] && command -v objcopy &>/dev/null; then
    local tmp
    tmp=$(mktemp)
    if sudo objcopy -O binary --only-section=.initrd "$image" "$tmp" 2>/dev/null && [[ -s $tmp ]]; then
      listing=$(lsinitcpio "$tmp" 2>/dev/null) || listing=""
    fi
    rm -f "$tmp"
  fi

  if [[ -z $listing ]]; then
    warn "could not read the contents of $image; skipping verification"
    return 0
  fi

  local want
  for want in "$@"; do
    if grep -qF "$want" <<<"$listing"; then
      echo "  ok      $want"
    else
      echo "  MISSING $want" >&2
      rc=1
    fi
  done

  # The hard invariant: the pool key must never reach the ESP. omarchy-refresh-zbm
  # checks the ESP as a whole; this checks the image we just built.
  local keyfile
  keyfile=$(pool_keyfile)
  if [[ -n $keyfile ]]; then
    if grep -qF "${keyfile#/}" <<<"$listing"; then
      echo "  LEAK    ${keyfile} is inside the ZBM image on the unencrypted ESP" >&2
      rc=1
    else
      echo "  ok      pool key absent from ZBM image"
    fi
  fi

  return $rc
}
