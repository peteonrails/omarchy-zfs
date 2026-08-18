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

Validated in QEMU (UEFI, virtio) on 2026-08-18:

- [x] Build completes, and fails the build if `zfs.ko` is missing from the live airootfs
- [x] Live ISO boots; `zpool` works in the live environment
- [x] ZFS install end-to-end: wizard → offline pacstrap of full Omarchy → ZBM →
      passphrase → kexec → initramfs → encrypted ZFS root → systemd → SDDM → desktop
- [x] Encrypted whole-pool install (native ZFS encryption, no LUKS/LVM)
- [ ] Untouched run on an image carrying every fix (no mid-install patching)
- [ ] Login password matches the pool passphrase on a fresh install
- [ ] Single passphrase prompt (see Known issues)
- [ ] Stock btrfs install still works from this ISO
- [ ] Hibernation on a zvol swap

### Known issues

- **The initramfs passphrase prompt rejects a correct passphrase.** This is the
  one blocker. ZFSBootMenu unlocks the pool with the passphrase, kexecs, and then
  the target's initramfs prompts again and answers `Incorrect key provided` for
  the *same* string — which unlocks the pool without complaint from a live system
  or the host (verified both with and without a trailing newline, and with
  `keylocation` set to `prompt` rather than a keyfile). Everything outside the
  initramfs agrees on the key; only the initramfs disagrees.

  Prime suspect: the ISO builds ZFS from **git master** (`zfs-dkms-git` /
  `zfs-utils-git`, currently 2.4.99), so the initramfs carries master's userspace.
  archzfs's release packages lag current kernels, which is why git was chosen —
  that tradeoff needs revisiting. Next steps, cheapest first: reproduce the prompt
  in the live ISO (`zfs load-key -L prompt` there, same binaries) to confirm it is
  the userspace and not the console; if confirmed, pin a release ZFS for the
  target; independently, make `org.zfsbootmenu:keysource` actually inject the key
  so there is only one prompt at all. Embedding the key via `FILES+=` also works
  but must never reach the ESP's UKI.
- **No journal storage** was observed on an install whose ZFS units were disabled;
  enabling them (now done at install time) should restore persistent logs — verify.
- **SDDM ships no `/var/lib/sddm/state.conf`**, so the password-only Omarchy theme
  has no user selected. Writing `[Last] User=…` makes the greeter usable.

The ZFS install path reuses `bin/omarchy-bootstrap-zfs`, whose stage 15 was
rewritten for Quattro (packages + `omarchy-apply-system` +
`omarchy-provision-user`) in this change and needs the VM validation pass
above before any release.
