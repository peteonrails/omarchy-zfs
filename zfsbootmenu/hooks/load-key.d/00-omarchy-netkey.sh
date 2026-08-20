#!/bin/sh
#
# Omarchy ZFSBootMenu network key fetch: unlock without anyone typing anything.
#
# Runs BEFORE 01-omarchy-unlock.sh (lexical order). If it succeeds, ZBM sees the
# key as available and skips every remaining load-key hook, so the branded
# passphrase prompt never appears. If it fails -- keyserver down, no route, cert
# rejected -- it exits non-zero and boot falls through to the normal prompt,
# which is reachable over SSH when omarchy-zfs-remote-unlock-setup has run.
#
# That fallthrough is the whole safety property: a dead keyserver must never
# turn into an unbootable machine. Hence the bounded retry budget below.
#
# Receives from ZBM:
#   ZBM_LOCKED_FS        -- the locked filesystem
#   ZBM_ENCRYPTION_ROOT  -- the encryption root to unlock
#
# Config is baked into the image at /etc/omarchy-netkey.conf by
# omarchy-zfs-netkey-setup:
#   NETKEY_URL       https:// URL serving the raw pool keyfile
#   NETKEY_CA        pinned CA cert that must have signed the server
#   NETKEY_CERT      client certificate presented to the server
#   NETKEY_KEY       client private key
#   NETKEY_TRIES     attempts (default 4)
#   NETKEY_TIMEOUT   per-attempt seconds (default 5)

CONF="/etc/omarchy-netkey.conf"
[ -r "$CONF" ] || exit 1
# shellcheck source=/dev/null
. "$CONF"

[ -n "$NETKEY_URL" ] || exit 1
[ -n "$ZBM_ENCRYPTION_ROOT" ] || exit 1

TRIES="${NETKEY_TRIES:-4}"
TIMEOUT="${NETKEY_TIMEOUT:-5}"

# Tokyo Night, matching 01-omarchy-unlock.sh
CYAN='\033[38;2;125;207;255m'
GREEN='\033[38;2;158;206;106m'
YELLOW='\033[38;2;224;175;104m'
DIM='\033[38;2;65;72;104m'
RESET='\033[0m'

printf '\n    %bFetching pool key from keyserver%b\n' "$CYAN" "$RESET"
printf '    %b%s%b\n' "$DIM" "$NETKEY_URL" "$RESET"

# tmpfs only -- the key must never touch a persistent filesystem. /tmp inside
# the initramfs is memory-backed and gone after kexec.
KEYTMP=$(mktemp /tmp/netkey.XXXXXX) || exit 1
chmod 600 "$KEYTMP"

cleanup() {
  # Truncate, then unlink. /tmp in the initramfs is tmpfs, so truncation frees
  # the pages outright -- there is no backing device to leave remnants on, which
  # is why this doesn't shell out to `dd`/`shred`. A stock ZBM image has neither
  # (verified: no dd, no wc, no busybox in a released ZBM image), so depending on
  # them would silently skip the wipe instead of doing it.
  : >"$KEYTMP" 2>/dev/null
  rm -f "$KEYTMP"
}
trap cleanup EXIT INT TERM

attempt=1
while [ "$attempt" -le "$TRIES" ]; do
  # Fail closed on TLS: --cacert pins the issuer, and the client cert is how the
  # server knows it's us. No --insecure, ever -- an attacker who can answer for
  # the keyserver address would otherwise be handed the pool key.
  if curl --fail --silent --show-error \
          --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 2))" \
          ${NETKEY_CA:+--cacert "$NETKEY_CA"} \
          ${NETKEY_CERT:+--cert "$NETKEY_CERT"} \
          ${NETKEY_KEY:+--key "$NETKEY_KEY"} \
          --output "$KEYTMP" \
          "$NETKEY_URL" 2>/dev/null && [ -s "$KEYTMP" ]; then

    if zfs load-key -L "file://$KEYTMP" "$ZBM_ENCRYPTION_ROOT" >/dev/null 2>&1; then
      printf '    %b✓%b Unlocked from keyserver\n\n' "$GREEN" "$RESET"
      exit 0
    fi

    # Reached the server but the key doesn't open the pool: the served key is
    # stale (passphrase rotated without updating the keyserver). Retrying cannot
    # fix that, so stop and let the operator type the real one.
    printf '    %b!%b Keyserver returned a key that does not unlock %s\n' "$YELLOW" "$RESET" "$ZBM_ENCRYPTION_ROOT"
    printf '    %bFalling through to the passphrase prompt%b\n\n' "$DIM" "$RESET"
    exit 1
  fi

  [ "$attempt" -lt "$TRIES" ] && printf '    %b·%b attempt %d/%d failed, retrying\n' "$DIM" "$RESET" "$attempt" "$TRIES"
  attempt=$((attempt + 1))
done

printf '    %b!%b Keyserver unreachable after %d attempts\n' "$YELLOW" "$RESET" "$TRIES"
printf '    %bFalling through to the passphrase prompt%b\n\n' "$DIM" "$RESET"
exit 1
