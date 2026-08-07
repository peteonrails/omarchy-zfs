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
| `/usr/bin/omarchy-zfs-snapper-guard` | **self-heal**: drop stale non-btrfs snapper configs |
| `/usr/bin/omarchy-zfs-bootorder-guard` | **self-heal**: keep ZFSBootMenu first in the EFI BootOrder |
| `/usr/bin/omarchy-zfs-hibernation-{setup,remove,available}` | ZFS zvol swap hibernation |
| `/usr/bin/omarchy-bootstrap-zfs` | pool/dataset/ZBM bootstrap (installer/DR) |
| `/usr/share/libalpm/hooks/00-zfs-autosnap.hook` | PreTransaction snapshot |
| `/usr/share/libalpm/hooks/90-omarchy-zfs-kernel-guard.hook` | PreTransaction kernel guard |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-ensure-mkinitcpio.hook` | PostTransaction self-heal |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-snapper-guard.hook` | PostTransaction snapper self-heal |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-bootorder-guard.hook` | PostTransaction BootOrder self-heal |
| `/usr/lib/systemd/system/omarchy-zfs-scrub.{service,timer}` | monthly scrub |
| `/etc/zfsbootmenu/config.yaml.example`, `hooks/**` | ZBM reference config + branded unlock/theme |
| `/etc/omarchy-zfs/autosnap.conf` | autosnap tunables |
| `/etc/omarchy-zfs/bootorder.conf` | boot-order guard opt-out |

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

## The update-survivability guarantee

`omarchy update` begins with:

```sh
omarchy-snapshot create || (($? == 127))
```

Upstream's `omarchy-snapshot` only tolerates exit `127` ("snapper isn't
installed"). Because our `omarchy` dependency pulls snapper in transitively,
that escape hatch never fires. `omarchy-snapshot` then loops over every config
returned by `snapper list-configs` — and Omarchy's installer
(`install/config/snapper.sh`) leaves behind a `root` config whose template
hardcodes `FSTYPE="btrfs"` / `SUBVOLUME="/"`. On a ZFS root that yields:

```
Create system snapshot
IO Error (subvolume is not a btrfs subvolume).
Something went wrong during the update!
```

The update aborts before a single package is touched, so the system is
**permanently un-updatable** until it's fixed.

`omarchy-zfs-snapper-guard` removes snapper configs whose `SUBVOLUME` isn't
actually on btrfs. With no configs listed, `omarchy-snapshot`'s loop is empty
and it exits 0. Nothing is lost — the pre-upgrade snapshot safety net on ZFS is
`00-zfs-autosnap.hook` (PreTransaction), not snapper. Configs pointing at a
*genuine* btrfs filesystem are preserved, so a secondary btrfs pool keeps
working snapper coverage.

Two details matter:

- `snapper list-configs` is served by the **snapperd D-Bus daemon**, which
  caches the config list. Deleting the file alone is not enough on a running
  system; the guard restarts `snapperd`.
- Omarchy re-installs that config from a template whenever `snapper.sh` runs
  (`omarchy-setup-system`, `install/config/all.sh`, migration `1781984677`), so
  a one-shot cleanup would silently regress. `zz-omarchy-zfs-snapper-guard.hook`
  re-asserts it PostTransaction on every transaction (a cheap no-op when
  nothing is stale).

`limine-snapper-sync.service`, `snapper-cleanup.timer` and
`snapper-timeline.timer` are masked — inert on ZFS, and masking survives
`snapper.sh` trying to re-enable them.

## The boot-order guarantee

`limine` is a hard dependency of `omarchy` and cannot be removed.
`/usr/bin/limine-install` registers its own EFI entry via `efibootmgr` and can
front-load it, so an ordinary `omarchy update` can silently move Limine above
ZFSBootMenu in `BootOrder`. Observed in the wild:

```
BootOrder: 0000,0006,0005,...
Boot0000* Limine        ← next boot
Boot0006* ZFSBootMenu
```

On root-on-ZFS that is a **dead boot**, not a cosmetic problem.
`limine-entry-tool` generates a UKI entry whose cmdline carries no `root=` and
no `spl.spl_hostid=`, so the `zfs` hook has nothing to import and you land in
an emergency shell. Nothing warns you at update time — you find out on reboot.

`omarchy-zfs-bootorder-guard` runs PostTransaction on every transaction. If the
first entry in `BootOrder` isn't an active ZFSBootMenu entry, it moves the ZBM
entries back to the front (preserving their relative order). It **only ever
reorders** — it never deletes another bootloader's NVRAM entry, since that's the
admin's call. ZBM entries are matched by label *or* loader path
(`\EFI\ZBM\...`), and inactive entries don't count. If no active ZBM entry
exists at all it warns loudly rather than guessing.

Opt out with `OMARCHY_ZFS_BOOTORDER_GUARD=0` in `/etc/omarchy-zfs/bootorder.conf`.

This replaces the earlier warn-only check in the `.install` scriptlet, which
only ran at package install time and so never fired during the update that
actually caused the problem.

### Known residual risk

`snapper.sh` runs `snapper -c root create-config /` when the config file is
absent, which fails on ZFS (`do not know about fstype 'zfs'`). It runs under
`bash -euo pipefail`, so if a **future** Omarchy migration invokes it, that
migration — and the update — will abort at the migration step rather than at
the snapshot step. No currently-pending migration does this. The durable fix is
upstream: `omarchy-snapshot` should skip non-btrfs roots, and `snapper.sh`
should tolerate `create-config` failing.

## Build

```sh
makepkg -f            # or: makepkg -f --nodeps  (deps are runtime-only)
```

Then serve from a local repo and install (see `PLAN-quattro-zfs.md` §3).

## Status

Phase 1 (package). See `PLAN-quattro-zfs.md` for the full migration/distribution
plan, validation checklist, and competitive positioning.
