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
| ZFS in the live environment | `zfs-dkms` + `linux-t2-headers` added to `packages.x86_64`; the module builds against the live kernel during the ISO build (a build-time failure, never a boot-time one) |
| ZFS install path | boot prompt (15s timeout, defaults to stock) → `omarchy-zfs-install` → `omarchy-bootstrap-zfs` in offline mode: pool/datasets/encryption wizard, pacstrap of full Omarchy + omarchy-zfs, ZBM install, finalizers |
| `[zfs-offline]` mirror on the ISO | `zfs-dkms` + `linux-headers` for the target (archzfs's prebuilt `zfs-linux-lts` pins a kernel Arch rotates out too fast to bake into an ISO; DKMS floats and the kernel guard prevents future skew), `omarchy-zfs` built from this working tree, `sanoid` + `perl-config-inifiles` built from the AUR, plus deps the stock mirror lacks |
| ZFSBootMenu | prebuilt release EFI baked at `/usr/share/omarchy-zfs/zbm/vmlinuz.EFI`, so installs are fully offline |
| Stock installs | untouched — same configurator, orchestrator, cidata autoinstall |

## Updating the upstream pin

```sh
git -C iso/.work/omarchy-iso fetch origin quattro
git -C iso/.work/omarchy-iso rev-parse origin/quattro > iso/UPSTREAM_REF
iso/build.sh    # anchored edits fail loudly if upstream restructured
```

## Status / validation

- [ ] Build completes (docker run of the full pipeline)
- [ ] Live ISO boots and `zpool` works (QEMU: `iso/.work/omarchy-iso/bin/omarchy-iso-boot`)
- [ ] Stock btrfs install still works from this ISO
- [ ] ZFS install end-to-end in a VM (wizard → reboot → ZBM → Omarchy session)
- [ ] Encrypted ZFS install + hibernation

The ZFS install path reuses `bin/omarchy-bootstrap-zfs`, whose stage 15 was
rewritten for Quattro (packages + `omarchy-apply-system` +
`omarchy-provision-user`) in this change and needs the VM validation pass
above before any release.
