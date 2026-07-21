#!/bin/sh
#
# Omarchy ZFSBootMenu unlock screen: branded passphrase prompt.
#
# Runs before ZBM's default `zfs load-key` prompt. If this hook successfully
# unlocks the filesystem (key status becomes "available"), ZBM's default
# prompt is skipped.
#
# Receives from ZBM:
#   ZBM_LOCKED_FS        -- the locked filesystem
#   ZBM_ENCRYPTION_ROOT  -- the encryption root to unlock

# Tokyo Night ANSI colors
RED='\033[38;2;247;118;142m'
GREEN='\033[38;2;158;206;106m'
CYAN='\033[38;2;125;207;255m'
BLUE='\033[38;2;122;162;247m'
PURPLE='\033[38;2;187;154;247m'
YELLOW='\033[38;2;224;175;104m'
FG='\033[38;2;192;202;245m'
DIM='\033[38;2;65;72;104m'
RESET='\033[0m'
BOLD='\033[1m'

# Clear screen, move cursor to top-left
tput clear 2>/dev/null || printf '\033[2J\033[H'

# Center-ish layout (terminal is typically 110+ cols due to ZBM's autosize font)
printf '\n\n'
printf '    %b%b' "$BLUE" "$BOLD"
cat <<'LOGO'
     ██████╗ ███╗   ███╗ █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗
    ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝
    ██║   ██║██╔████╔██║███████║██████╔╝██║     ███████║ ╚████╔╝
    ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝
    ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║
     ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝
LOGO
printf '%b' "$RESET"
printf '\n'
printf '    %bEncrypted ZFS filesystem%b\n' "$CYAN" "$RESET"
printf '    %b%s%b\n' "$DIM" "$ZBM_ENCRYPTION_ROOT" "$RESET"
printf '\n'

# Up to 3 attempts; ZBM will fall through to its own prompt if this fails
attempt=1
max_attempts=3
while [ "$attempt" -le "$max_attempts" ]; do
  printf '    %b◆%b %bPassphrase:%b ' "$PURPLE" "$RESET" "$FG" "$RESET"
  if zfs load-key -L prompt "$ZBM_ENCRYPTION_ROOT"; then
    printf '\n    %b✓%b Unlocked\n\n' "$GREEN" "$RESET"
    sleep 1
    exit 0
  fi
  printf '    %b✗%b Incorrect passphrase (attempt %d/%d)\n\n' "$RED" "$RESET" "$attempt" "$max_attempts"
  attempt=$((attempt + 1))
done

# Give up -- ZBM will take over with its default prompt
exit 1
