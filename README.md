# omarchy-zfs

Root-on-ZFS + [ZFSBootMenu](https://zfsbootmenu.org/) support layer for
[Omarchy](https://omarchy.org) (Quattro), packaged the Arch-native way.

Omarchy Quattro is served entirely from Arch packages. `omarchy-zfs` is a
package that **depends on** stock Omarchy and re-homes every ZFS piece as real,
package-owned files plus pacman hooks — so nothing dangles and `omarchy update`
can never silently strip the ZFS layer.

## What it installs

| Path | Purpose |
|---|---|
| `/usr/bin/omarchy-fs-{type,zfs,btrfs}` | root-filesystem detection |
| `/usr/bin/omarchy-cmdline-add` | bootloader-agnostic kernel cmdline edits (ZBM property on ZFS) |
| `/usr/bin/omarchy-refresh-zbm` | guarded `mkinitcpio -P` + `generate-zbm` |
| `/usr/bin/omarchy-zfs-snapshot` | manual create/restore system snapshots |
| `/usr/bin/omarchy-zfs-autosnap` | layout-agnostic pre-upgrade snapshots (+ retention) |
| `/usr/bin/omarchy-zfs-scrub` | `zpool scrub` all pools (monthly timer) |
| `/usr/bin/omarchy-zfs-kernel-compat-check` | block kernel upgrades zfs-dkms can't build |
| `/usr/bin/omarchy-zfs-ensure-mkinitcpio` | **self-heal**: re-assert the `zfs` mkinitcpio hook |
| `/usr/bin/omarchy-zfs-hibernation-{setup,remove,available}` | ZFS zvol swap hibernation |
| `/usr/bin/omarchy-bootstrap-zfs` | pool/dataset/ZBM bootstrap (installer/DR) |
| `/usr/share/libalpm/hooks/00-zfs-autosnap.hook` | PreTransaction snapshot |
| `/usr/share/libalpm/hooks/90-omarchy-zfs-kernel-guard.hook` | PreTransaction kernel guard |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-ensure-mkinitcpio.hook` | PostTransaction self-heal |
| `/usr/lib/systemd/system/omarchy-zfs-scrub.{service,timer}` | monthly scrub |
| `/etc/zfsbootmenu/config.yaml.example`, `hooks/**` | ZBM reference config + branded unlock/theme |
| `/etc/omarchy-zfs/autosnap.conf` | autosnap tunables |

## The boot-safety guarantee

`omarchy update` runs `pacman -Syu --overwrite '*/omarchy_hooks.conf'` on every
run, replacing Omarchy's mkinitcpio `HOOKS` drop-in with the stock (zfs-less)
version. The kernel's own mkinitcpio hook then rebuilds the initramfs — without
`zfs` — leaving an unbootable root on the next reboot.

`zz-omarchy-zfs-ensure-mkinitcpio.hook` runs **last** in every transaction. It
derives the effective `HOOKS` line, inserts `zfs` before `filesystems`, writes
it to our own `zz-omarchy-zfs.conf` drop-in (which sorts after — and therefore
overrides — `omarchy_hooks.conf`), and regenerates the initramfs + ZBM. Upstream
hook additions are inherited automatically; we only guarantee `zfs` placement.

## Build

```sh
makepkg -f            # or: makepkg -f --nodeps  (deps are runtime-only)
```

Then serve from a local repo and install (see `PLAN-quattro-zfs.md` §3).

## Status

Phase 1 (package). See `PLAN-quattro-zfs.md` for the full migration/distribution
plan, validation checklist, and competitive positioning.
