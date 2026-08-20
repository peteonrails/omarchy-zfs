#!/bin/bash
# Functional test for lib/remote-unlock.sh config editing.
# Runs entirely on fixtures in /tmp; sudo is stubbed to a no-op passthrough.
set -uo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Stub sudo BEFORE sourcing so the lib's sudo calls stay in userspace.
sudo() { "$@"; }
export -f sudo 2>/dev/null || true

source "$(dirname "$(readlink -f "$0")")/../lib/remote-unlock.sh"

# Redirect the lib's targets at our fixtures.
ZBM_ETC="$WORK/etc/zfsbootmenu"
ZBM_CONFIG="$ZBM_ETC/config.yaml"
ZBM_MKINITCPIO="$ZBM_ETC/mkinitcpio.conf"
ZBM_INITCPIO_DIR="$ZBM_ETC/initcpio"
mkdir -p "$ZBM_ETC"

PASS=0; FAIL=0
ok()   { echo "  ok   $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1"; printf '       want: %q\n       got:  %q\n' "$3" "$2"; fi; }

# Real omarchy config.yaml, as omarchy-bootstrap-zfs writes it.
cat > "$ZBM_CONFIG" <<'EOF'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  InitCPIO: true
  PreHooksDir: /etc/zfsbootmenu/hooks

Components:
  Enabled: false

EFI:
  Enabled: true
  ImageDir: /boot/efi/EFI/zbm
  Versions: 2

Kernel:
  CommandLine: quiet loglevel=0 zbm.skip_hooks=
EOF
ORIGINAL_CONFIG=$(cat "$ZBM_CONFIG")

echo "== ensure_zbm_mkinitcpio_conf =="
ensure_zbm_mkinitcpio_conf >/dev/null
[[ -f $ZBM_MKINITCPIO ]] && ok "seeded mkinitcpio.conf" || bad "seeded mkinitcpio.conf"
grep -q '^HOOKS=(base udev autodetect' "$ZBM_MKINITCPIO" && ok "HOOKS baseline present" || bad "HOOKS baseline present"

echo "== ensure_zbm_hook_dirs =="
ensure_zbm_hook_dirs
grep -q 'InitCPIOHookDirs:' "$ZBM_CONFIG" && ok "InitCPIOHookDirs added" || bad "InitCPIOHookDirs added"
# Must land INSIDE the Global: mapping, i.e. before Components:
gl=$(grep -n '^Global:' "$ZBM_CONFIG" | cut -d: -f1)
hd=$(grep -n 'InitCPIOHookDirs:' "$ZBM_CONFIG" | cut -d: -f1)
cp=$(grep -n '^Components:' "$ZBM_CONFIG" | cut -d: -f1)
[[ $gl -lt $hd && $hd -lt $cp ]] && ok "block is inside Global: mapping" || bad "block is inside Global: mapping (Global=$gl hookdirs=$hd Components=$cp)"
# YAML must still parse and keep the keys reachable under Global.
if command -v python3 >/dev/null; then
  python3 - "$ZBM_CONFIG" <<'PY' && ok "config.yaml still valid YAML with keys under Global" || bad "config.yaml still valid YAML with keys under Global"
import sys
try:
    import yaml
except ImportError:
    print("  (pyyaml missing, skipping parse check)"); sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
assert d["Global"]["InitCPIO"] is True, d["Global"]
assert isinstance(d["Global"]["InitCPIOHookDirs"], list), d["Global"]["InitCPIOHookDirs"]
assert d["Global"]["PreHooksDir"] == "/etc/zfsbootmenu/hooks"
PY
fi

echo "== idempotency: ensure_zbm_hook_dirs twice =="
ensure_zbm_hook_dirs
count=$(grep -c 'InitCPIOHookDirs:' "$ZBM_CONFIG")
check "InitCPIOHookDirs appears exactly once" "$count" "1"

echo "== zbm_conf_add =="
zbm_conf_add "remote-unlock" "MODULES+=(igb)" "BINARIES+=(ip)" "HOOKS+=(rclocal)" "HOOKS+=(dropbear)" "rclocal_hook=$ZBM_INITCPIO_DIR/rc.local"
# HOOKS order matters: networking must precede dropbear.
rc=$(grep -n 'HOOKS+=(rclocal)' "$ZBM_MKINITCPIO" | cut -d: -f1)
db=$(grep -n 'HOOKS+=(dropbear)' "$ZBM_MKINITCPIO" | cut -d: -f1)
[[ $rc -lt $db ]] && ok "rclocal ordered before dropbear" || bad "rclocal ordered before dropbear"
# And the file must still be sourceable as shell, with the arrays accumulating.
# FILES is declared because the seeded conf sets it; only the others are asserted.
# shellcheck disable=SC2034,SC1090
( set -e; MODULES=(); BINARIES=(); FILES=(); HOOKS=(); source "$ZBM_MKINITCPIO"
  [[ ${MODULES[*]} == "igb" ]] || { echo "MODULES=${MODULES[*]}"; exit 1; }
  [[ ${BINARIES[*]} == "ip" ]] || { echo "BINARIES=${BINARIES[*]}"; exit 1; }
  [[ ${HOOKS[*]} == *"rclocal dropbear" ]] || { echo "HOOKS=${HOOKS[*]}"; exit 1; }
) && ok "mkinitcpio.conf sources cleanly with expected arrays" || bad "mkinitcpio.conf sources cleanly with expected arrays"

echo "== idempotency: zbm_conf_add twice =="
zbm_conf_add "remote-unlock" "MODULES+=(igb)" "BINARIES+=(ip)" "HOOKS+=(rclocal)" "HOOKS+=(dropbear)"
count=$(grep -c 'HOOKS+=(dropbear)' "$ZBM_MKINITCPIO")
check "dropbear hook added exactly once" "$count" "1"

echo "== coexistence: a second tag =="
zbm_conf_add "netkey" "BINARIES+=(curl)" "FILES+=(/etc/omarchy-netkey.conf)"
grep -q 'HOOKS+=(dropbear)' "$ZBM_MKINITCPIO" && ok "netkey block preserved remote-unlock block" || bad "netkey block preserved remote-unlock block"
grep -q 'BINARIES+=(curl)' "$ZBM_MKINITCPIO" && ok "netkey block written" || bad "netkey block written"

echo "== selective removal =="
managed_block_remove "$ZBM_MKINITCPIO" "netkey"
grep -q 'BINARIES+=(curl)' "$ZBM_MKINITCPIO" && bad "netkey block removed" || ok "netkey block removed"
grep -q 'HOOKS+=(dropbear)' "$ZBM_MKINITCPIO" && ok "remote-unlock block survived netkey removal" || bad "remote-unlock block survived netkey removal"

echo "== zbm_cmdline_add =="
zbm_cmdline_add "remote-unlock-cmdline" "ip=:::::eth0:dhcp" >/dev/null
grep -q 'ip=:::::eth0:dhcp' "$ZBM_CONFIG" && ok "ip= appended to CommandLine" || bad "ip= appended to CommandLine"
grep -q '#restore:  CommandLine: quiet loglevel=0 zbm.skip_hooks=' "$ZBM_CONFIG" && ok "original CommandLine stashed" || bad "original CommandLine stashed"
count=$(grep -cE '^[[:space:]]*CommandLine:' "$ZBM_CONFIG")
check "exactly one active CommandLine line" "$count" "1"
if command -v python3 >/dev/null; then
  python3 - "$ZBM_CONFIG" <<'PY' && ok "CommandLine parses with ip= present" || bad "CommandLine parses with ip= present"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
cl = d["Kernel"]["CommandLine"]
assert "ip=:::::eth0:dhcp" in cl, cl
assert "zbm.skip_hooks=" in cl, cl
PY
fi

echo "== idempotency: zbm_cmdline_add twice =="
zbm_cmdline_add "remote-unlock-cmdline" "ip=:::::eth0:dhcp" >/dev/null
count=$(grep -c 'ip=:::::eth0:dhcp' "$ZBM_CONFIG")
check "ip= present once (not stacked)" "$count" "1"

echo "== full restore =="
managed_block_remove "$ZBM_CONFIG" "remote-unlock-cmdline"
managed_block_remove "$ZBM_CONFIG" "hookdirs"
if [[ "$(cat "$ZBM_CONFIG")" == "$ORIGINAL_CONFIG" ]]; then
  ok "config.yaml restored byte-for-byte"
else
  bad "config.yaml restored byte-for-byte"
  diff <(echo "$ORIGINAL_CONFIG") "$ZBM_CONFIG" | sed 's/^/       /'
fi

echo "== pre-existing InitCPIOHookDirs is respected, not duplicated =="
CUSTOM="$WORK/custom.yaml"
cat > "$CUSTOM" <<'EOF'
Global:
  ManageImages: true
  InitCPIO: true
  InitCPIOConfig: /etc/zfsbootmenu/mkinitcpio.conf
  InitCPIOHookDirs:
    - /etc/zfsbootmenu/initcpio
    - /usr/lib/initcpio
Kernel:
  CommandLine: quiet
EOF
( ZBM_CONFIG="$CUSTOM" ZBM_MKINITCPIO="/etc/zfsbootmenu/mkinitcpio.conf" \
  ZBM_INITCPIO_DIR="/etc/zfsbootmenu/initcpio" ensure_zbm_hook_dirs >/dev/null 2>&1 )
count=$(grep -c 'InitCPIOHookDirs:' "$CUSTOM")
check "existing InitCPIOHookDirs not duplicated" "$count" "1"
grep -qF '>>> omarchy-zfs hookdirs' "$CUSTOM" && bad "no managed block added over existing key" || ok "no managed block added over existing key"

echo "== pre-existing InitCPIOHookDirs missing our dir -> must refuse =="
BADCFG="$WORK/bad.yaml"
printf 'Global:\n  InitCPIO: true\n  InitCPIOHookDirs:\n    - /some/other/dir\n' > "$BADCFG"
out=$( ZBM_CONFIG="$BADCFG" ZBM_INITCPIO_DIR="/etc/zfsbootmenu/initcpio" \
       bash -c 'source "$1"; ZBM_CONFIG="$2"; ZBM_INITCPIO_DIR="/etc/zfsbootmenu/initcpio"; ensure_zbm_hook_dirs' \
       _ "$(dirname "$(readlink -f "$0")")/../lib/remote-unlock.sh" "$BADCFG" 2>&1 )
grep -q 'does not include' <<<"$out" && ok "refused a hook dir list that excludes ours" || bad "refused a hook dir list that excludes ours ($out)"

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
