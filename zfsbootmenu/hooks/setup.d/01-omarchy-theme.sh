#!/bin/sh
#
# Omarchy ZFSBootMenu theme: Tokyo Night palette for the fzf-based menu.
#
# Installed to /etc/zfsbootmenu/hooks/setup.d/ and baked into the ZBM image
# via `generate-zbm`, OR loaded at boot via `zbm.hookroot=<device>//path` for
# live updates without rebuilding ZBM.
#
# Runs just before the boot-environment menu is displayed.

# Use Tokyo Night accent colors (hex) where supported. Falls back to the
# 16-color terminal palette on consoles that don't support 24-bit color.
export FZF_DEFAULT_OPTS="\
--color=bg:#1a1b26,fg:#c0caf5,bg+:#24283b,fg+:#7aa2f7 \
--color=hl:#bb9af7,hl+:#bb9af7 \
--color=info:#7dcfff,border:#414868,prompt:#7aa2f7 \
--color=pointer:#f7768e,marker:#9ece6a,spinner:#e0af68 \
--color=header:#9ece6a \
--prompt='omarchy ❯ ' \
--pointer='▶' \
--marker='✓'"
