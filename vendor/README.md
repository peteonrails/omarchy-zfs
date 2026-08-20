# Vendored mkinitcpio hooks

These are third-party mkinitcpio hooks baked into the **ZFSBootMenu** image (not
the OS initramfs) by `omarchy-zfs-remote-unlock-setup`. They are vendored rather
than declared as dependencies because neither is in the Arch binary repos, and
`omarchy-zfs` must remain installable with plain `pacman -S` (same reasoning as
the `zfsbootmenu` optdepend — see the comment in `PKGBUILD`).

Files are **verbatim copies** of upstream. Do not edit them here; re-vendor from
upstream and update the commit below so the diff stays reviewable.

| Directory | Upstream | Commit | License |
|---|---|---|---|
| `mkinitcpio-dropbear/` | https://github.com/ahesford/mkinitcpio-dropbear | `2670f819f23f1c80b209928b748148ade2f51290` (2023-09-09) | BSD-2-Clause, © 2015 Giancarlo Razzolini |
| `mkinitcpio-rclocal/` | https://github.com/ahesford/mkinitcpio-rclocal | `f3e39cb274d5e0810454159beeae19de7c4e044c` (2022-01-24) | BSD-2-Clause, © 2021 Andrew J. Hesford |

Both are the forks recommended by the
[ZFSBootMenu remote-access guide](https://docs.zfsbootmenu.org/en/latest/guides/general/remote-access.html).
The `ahesford` dropbear fork is required (not the AUR `mkinitcpio-dropbear`)
because it honours `dropbear_listen` in `/etc/dropbear/dropbear.conf`, which is
how we move the unlock listener off port 22.

## Install layout

`PKGBUILD` installs these to `/usr/share/omarchy-zfs/initcpio/{install,hooks}/`.
`omarchy-zfs-remote-unlock-setup` copies them into
`/etc/zfsbootmenu/initcpio/{install,hooks}/` and registers that directory via
`Global: InitCPIOHookDirs` in `/etc/zfsbootmenu/config.yaml` — `generate-zbm`
does **not** search `/etc/zfsbootmenu/initcpio` implicitly.

## Re-vendoring

```bash
for r in mkinitcpio-dropbear mkinitcpio-rclocal; do
  curl -fsSL "https://github.com/ahesford/$r/archive/refs/heads/master.tar.gz" | tar -xz -C /tmp
  cp /tmp/$r-master/{LICENSE,*_hook,*_install} "vendor/$r/"
done
```
