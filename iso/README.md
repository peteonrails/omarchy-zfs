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
| ZFS in the live environment | `zfs-dkms-git` + `linux-t2-headers` added to `packages.x86_64`; the module builds against the live kernel during the ISO build (a build-time failure, never a boot-time one) |
| ZFS install path | boot prompt (15s timeout, defaults to stock) → `omarchy-zfs-install` → `omarchy-bootstrap-zfs` in offline mode: pool/datasets/encryption wizard, pacstrap of full Omarchy + omarchy-zfs, ZBM install, finalizers |
| `[zfs-offline]` mirror on the ISO | `zfs-dkms-git`/`zfs-utils-git` built from the AUR (archzfs’s prebuilt modules and even its zfs-dkms release lag Arch kernels; git HEAD tracks them, the kernel guard prevents future skew) plus `linux-headers` for the target, `omarchy-zfs` built from this working tree, `sanoid` + `perl-config-inifiles` built from the AUR, plus deps the stock mirror lacks |
| ZFSBootMenu | prebuilt release EFI baked at `/usr/share/omarchy-zfs/zbm/vmlinuz.EFI`, so installs are fully offline |
| Stock installs | untouched — same configurator, orchestrator, cidata autoinstall |

## Updating the upstream pin

```sh
git -C iso/.work/omarchy-iso fetch origin quattro
git -C iso/.work/omarchy-iso rev-parse origin/quattro > iso/UPSTREAM_REF
iso/build.sh    # anchored edits fail loudly if upstream restructured
```

## Status / validation

Each published image goes through an untouched run in QEMU (UEFI, virtio,
fresh disk, fresh NVRAM, no manual repair) ending at a logged-in desktop.
Last run: the 2026.10.29 image, 2026-10-29. Bootstrap completed hands-off in
under ten minutes; ZFSBootMenu prompted once; SDDM accepted the same
passphrase; Quattro Hyprland desktop came up.

- [x] Build completes, and fails the build if `zfs.ko` is missing from the live airootfs
- [x] Live ISO boots; `zpool` works in the live environment
- [x] ZFS install end-to-end: wizard → offline pacstrap of full Omarchy → ZBM →
      passphrase → kexec → initramfs → encrypted ZFS root → systemd → SDDM → desktop
- [x] Encrypted whole-pool install (native ZFS encryption, no LUKS/LVM)
- [x] Untouched run on an image carrying every fix (no mid-install patching)
- [x] Login password matches the pool passphrase on a fresh install
- [x] Single passphrase prompt (pool key embedded in the in-pool initramfs,
      verified absent from the ESP image)
- [ ] Stock btrfs install still works from this ISO
- [ ] Hibernation on a zvol swap

### Known issues

- **`generate-zbm` output name.** ZFSBootMenu 3.1.0 writes
  `/boot/efi/EFI/zbm/vmlinuz-linux.EFI` (named after the kernel), while the
  bootstrap looks for `vmlinuz.EFI`, so it reports the generated image missing
  and installs the bundled prebuilt EFI instead. Boot works either way; the
  branded hooks from the package are only in the generated image. Seen on the
  2026.10.29 run.
- **Upstream drift.** `omarchy-iso` has moved far past the pin in
  `UPSTREAM_REF` and rewrote `builder/build-iso.sh`; the `# Build the ISO.`
  anchor no longer exists at upstream HEAD. Re-pinning means re-porting the
  overlay. Packages still come fresh from the Omarchy mirrors at build time,
  so the old pin produces a current Omarchy.
- **SDDM user selection** is handled at install time by writing
  `/var/lib/sddm/state.conf` with the created user.
