# omarchy-zfs ISO

The official Omarchy ISO, plus a root-on-ZFS + ZFSBootMenu install path.
Upstream (`omacom-io/omarchy-iso`) is **not forked** — `build.sh` clones it at
the ref pinned in `UPSTREAM_REF`, applies `overlay/`, makes three anchored
edits, and runs the stock build. If upstream moves an anchor, the build fails
loudly instead of producing a silently-wrong ISO.

## Build

```sh
iso/build.sh                 # output: iso/out/omarchy-zfs-*.iso
```

Host needs docker, git, and ~15GB free. Extra args pass through to upstream's
`omarchy-iso-make` (e.g. `--no-cache`). Override the pin with
`OMARCHY_ISO_UPSTREAM_REF=<ref>`.

Use the rootful docker daemon. Upstream's build cache under
`~/.cache/omarchy/iso_<channel>/` is root-owned, and a rootless container
cannot replace a stale package there: pacman reports it as corrupted and the
build dies before mkarchiso. If the account is not in the `docker` group, put a
`docker` wrapper that runs `sudo -n /usr/bin/docker "$@"` first on `PATH`.

## What's different from the stock ISO

| Change | Mechanism |
|---|---|
| ZFS in the live environment | `zfs-dkms` + `zfs-utils` 2.4.4 and `linux-omarchy-headers` added to `packages.x86_64`; the module builds against the live `linux-omarchy` kernel during the ISO build (a build-time failure, never a boot-time one). A Mac boots `linux-t2`, which gets no module, so the ZFS offer is skipped there |
| ZFS install path | boot prompt (15s timeout, defaults to stock) → `omarchy-zfs-install` → `omarchy-bootstrap-zfs` in offline mode: pool/datasets/encryption wizard, pacstrap of full Omarchy + omarchy-zfs, ZBM install, finalizers |
| `[zfs-offline]` mirror on the ISO | `zfs-dkms`/`zfs-utils` built from the AUR (OpenZFS 2.4.4 is the first release that builds for the 7.2 kernels Omarchy 4.5 ships; archzfs is stuck at 2.3.3) plus `linux-omarchy-headers` for the target, `omarchy-zfs` built from this working tree, `sanoid` + `perl-config-inifiles` + `zfsbootmenu` built from the AUR, plus deps the stock mirror lacks |
| ZFSBootMenu | prebuilt release EFI baked at `/usr/share/omarchy-zfs/zbm/vmlinuz.EFI`, so installs are fully offline |
| Stock installs | untouched — same configurator, orchestrator, cidata autoinstall |

## Updating the upstream pin

The pin follows Omarchy's release branches (`v4-5-1` today), not `quattro`,
so the image matches a published Omarchy release:

```sh
git -C iso/.work/omarchy-iso fetch origin v4-5-1
git -C iso/.work/omarchy-iso rev-parse origin/v4-5-1 > iso/UPSTREAM_REF
iso/build.sh    # anchored edits fail loudly if upstream restructured
```

## Status / validation

Each published image goes through an untouched run in QEMU (UEFI, virtio,
fresh disk, fresh NVRAM, no manual repair) ending at a logged-in desktop.
Last run: the 2026.11.07 image (Omarchy 4.5.1 base), 2026-11-07. Bootstrap
completed hands-off: root image copied into the dataset in under a minute,
only the missing packages pacstrapped, zfs-dkms 2.4.4 built for linux-omarchy
7.2.15 in the chroot. The branded ZFSBootMenu prompted once, SDDM accepted the
same passphrase, Quattro Hyprland desktop came up with no failed units and
`[omarchy-zfs]` in `pacman.conf`.

- [x] Build completes, and fails the build if `zfs.ko` is missing from the live airootfs
- [x] Live ISO boots; `zpool` works in the live environment
- [x] ZFS install end-to-end: wizard → root image + offline delta pacstrap → ZBM →
      passphrase → kexec → initramfs → encrypted ZFS root → systemd → SDDM → desktop
- [x] Encrypted whole-pool install (native ZFS encryption, no LUKS/LVM)
- [x] Untouched run on an image carrying every fix (no mid-install patching)
- [x] Login password matches the pool passphrase on a fresh install
- [x] Single passphrase prompt (pool key embedded in the in-pool initramfs,
      verified absent from the ESP image)
- [ ] Stock btrfs install still works from this ISO
- [ ] Hibernation on a zvol swap

### Known issues

- **SDDM user selection** is handled at install time by writing
  `/var/lib/sddm/state.conf` with the created user.
