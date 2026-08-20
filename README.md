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
| `/usr/bin/omarchy-zfs-remote-unlock-{setup,remove}` | SSH into ZFSBootMenu to unlock a remote box |
| `/usr/bin/omarchy-zfs-netkey-{setup,remove}` | zero-touch unlock via a mutual-TLS keyserver |
| `/usr/bin/omarchy-bootstrap-zfs` | pool/dataset/ZBM bootstrap (installer/DR) |
| `/usr/share/libalpm/hooks/00-zfs-autosnap.hook` | PreTransaction snapshot |
| `/usr/share/libalpm/hooks/90-omarchy-zfs-kernel-guard.hook` | PreTransaction kernel guard |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-ensure-mkinitcpio.hook` | PostTransaction self-heal |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-snapper-guard.hook` | PostTransaction snapper self-heal |
| `/usr/share/libalpm/hooks/zz-omarchy-zfs-bootorder-guard.hook` | PostTransaction BootOrder self-heal |
| `/usr/lib/systemd/system/omarchy-zfs-scrub.{service,timer}` | monthly scrub |
| `/etc/zfsbootmenu/config.yaml.example`, `hooks/**` | ZBM reference config + branded unlock/theme/netkey |
| `/usr/share/omarchy-zfs/lib/remote-unlock.sh` | shared helpers for the remote-unlock tools |
| `/usr/share/omarchy-zfs/initcpio/**` | vendored `dropbear`/`rclocal` hooks for the ZBM image |
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

## Remote unlock (no remote hands)

On an encrypted pool, boot stops at ZFSBootMenu's passphrase prompt. That is one
interactive gate — after it, ZBM kexecs the in-pool kernel, whose initramfs
carries the keyfile, so there is no second prompt. But on a headless or colo box
nobody is there to satisfy it, and the machine sits unbooted until someone walks
to it.

Two layers, meant to be applied in order:

```sh
omarchy-zfs-remote-unlock-setup   # Phase 1: SSH to the ZBM prompt
omarchy-zfs-netkey-setup          # Phase 2: fetch the key, unlock unattended
```

**Phase 1 — SSH into ZFSBootMenu.** Puts `dropbear` (key-only, port 2222 by
default) and a NIC driver into the ZBM image, with either a static address baked
in via the `rclocal` hook or DHCP via `net` + `ip=`. The stalled box answers SSH;
you run `zfsbootmenu`, unlock, and it kexecs — your session dropping is the
success signal. A human is still involved, but no hands on hardware.

**Phase 2 — zero-touch.** `00-omarchy-netkey.sh` runs before the branded prompt
and fetches the pool key over mutual TLS from a keyserver you run
(`docs/netkey-server.md`). Success means an unattended reboot comes back on its
own; failure falls through to the Phase 1 prompt within ~40s. Phase 1 is
therefore a prerequisite — it supplies both the networking and the fallback.

### Requires a locally generated ZBM

Both phases modify the ZFSBootMenu image, so they need `zfsbootmenu` (AUR) and
`generate-zbm`. The prebuilt EFI from `get.zfsbootmenu.org` — which
`omarchy-bootstrap-zfs` falls back to — is a fixed binary and **cannot** be
used; the setup scripts refuse with instructions rather than half-configuring.

Note that `generate-zbm` does not search `/etc/zfsbootmenu/initcpio` on its own.
Setup registers it via `Global: InitCPIOHookDirs` in `config.yaml`; without that
the hooks are silently ignored and you get an image with no `dropbear` and no
warning. Every edit lives between `# >>> omarchy-zfs remote-unlock >>>` markers,
so re-running is idempotent and the `-remove` tools restore the originals.

### Security model

The ESP is unencrypted, so treat everything in the ZBM image as public. The
`-setup` scripts assert after each rebuild that the pool keyfile is **not** in
the image (alongside the existing whole-ESP check in `omarchy-refresh-zbm`).

| Enabled | Attacker with the disk | Attacker on the network |
|---|---|---|
| Phase 1 only | Gets a dropbear host key and your *public* key. Pool stays sealed. | Sees a closed port; auth is key-only, passwords disabled. |
| Phase 1 + 2 | Also gets the client certificate — usable to fetch the pool key **until you revoke**. | Must present a client cert signed by your pinned CA. |

Phase 2 deliberately trades "stolen disk is useless" for "stolen disk is useful
only while my keyserver still answers it". For a box that would otherwise stay
down until someone drives out, that is usually right — and still far better than
an unencrypted server. It is the wrong trade if your actual threat is seizure of
the hardware by someone who can also reach your keyserver. Revocation is
deletion: drop the served key or the firewall rule, then rotate with
`zfs change-key`.

### Before you rely on it

The failure mode is invisible until a reboot you cannot attend, so test all
three paths while you still have console access: keyserver reachable (boots
unattended), keyserver blocked (falls through to SSH), network down (lands at the
local prompt). Also confirm the box powers itself back on — remote unlock solves
unlocking, not power. Check BIOS restore-on-AC-loss, and that you have colo
IPMI/iKVM or a switched PDU, *before* shipping the hardware.

## Install

From the [AUR](https://aur.archlinux.org/packages/omarchy-zfs):

```sh
yay -S omarchy-zfs    # or paru, or makepkg from a manual AUR clone
```

Note: the `omarchy` dependency is satisfied by the real Omarchy package from
`pkgs.omarchy.org` (already installed on any Omarchy system). The AUR package
named `omarchy` is an unrelated third-party placeholder — don't build it.

## Build from source

```sh
makepkg -f            # or: makepkg -f --nodeps  (deps are runtime-only)
```

Then serve from a local repo and install (see `PLAN-quattro-zfs.md` §3).

## The ISO

For fresh machines: the official Omarchy ISO plus a root-on-ZFS install path,
built without forking upstream. See [`iso/README.md`](iso/README.md).

```sh
iso/build.sh    # → iso/out/omarchy-zfs-*.iso   (needs docker, ~15GB)
```

## Releasing to the AUR

```sh
git tag -s vX.Y.Z && git push origin vX.Y.Z
aur/release.sh        # derives the AUR PKGBUILD, test-builds, pushes
```

## Status

Phase 1 (package). See `PLAN-quattro-zfs.md` for the full migration/distribution
plan, validation checklist, and competitive positioning.
