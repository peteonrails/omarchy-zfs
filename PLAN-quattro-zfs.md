# Omarchy Quattro + ZFS — Full Migration & Distribution Plan

Status: DRAFT for review — 2026-07-21. All technical claims below are validated against the
live system and the `basecamp/omarchy@quattro` branch unless marked ❓.

---

## 0. Why we're pivoting

Today the ZFS fork delivers its functionality *by being the omarchy source tree* (a git checkout
at `~/.local/share/omarchy` on branch `omarchy-zfs-shell-merge`, `4.0.0.alpha`). Quattro serves
omarchy entirely from Arch **packages**; running the stock `upgrade-to-quattro` script as-is would:

- `--overwrite` the unowned `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` (which carries our `zfs`
  hook) with the package's zfs-less version → **latent unbootable root** on the next initramfs regen;
- move the git checkout to `.bak` and dangle `/usr/local/bin/omarchy-zfs-*` symlinks →
  kernel guard, scrub, and ZFS-snapshot commands stop working;
- leave future `omarchy update` pulling upstream, never re-applying our ZFS layer.

**The pivot:** ship an `omarchy-zfs` package that `depends` on stock Quattro and re-homes every ZFS
piece as real, package-owned files + pacman hooks. This is the Arch-native "omarchy plus ZFS,"
and it closes every failure mode because packages own real files — nothing dangles.

### Validated current state
- Root on `rpool/omarchy/root`; `linux 7.0.9.arch2-1` + `zfs-dkms-git`/`zfs-utils-git` 2.4.2 (from `[archzfs]`).
- Boots **ZFSBootMenu** (EFI `BootOrder`: `0006 ZFSBootMenu` first, `0005` backup-SSD ZBM); two ESPs (EFI1 `nvme1p1`, EFI2 `nvme2p1`). Initramfs comes from plain `mkinitcpio` (`90-mkinitcpio-install.hook`) → `/boot/initramfs-linux.img`, which ZBM kexecs from inside the dataset.
- `sddm` in use (stock Quattro also uses sddm — no conflict).
- Live hooks already present: `/etc/pacman.d/hooks/00-zfs-autosnap.hook`, `90-omarchy-zfs-kernel-guard.hook`.
- **No** `limine`/`limine-*`/`snapper` installed.

---

## 1. The `omarchy-zfs` package

### 1.1 Dependencies (validated)
`omarchy-dev` has `Provides: omarchy` + `Conflicts: omarchy`, so a single `depends=(omarchy)` is
satisfied on any channel (today only `omarchy-dev` exists; a real `omarchy` will provide it later).

```
depends=(
  omarchy                       # pulls the whole Quattro stack (settings, nvim, shell, …)
  zfs-dkms-git zfs-utils-git    # from [archzfs]
  zfsbootmenu
  sanoid                        # + syncoid etc. — existing fork ZFS pkg set (see install/omarchy-fs-zfs.packages)
)
```
Pulling `omarchy` also drags in `limine limine-mkinitcpio-hook limine-snapper-sync snapper` (stock
hard-deps). On ZFS these are **inert/cosmetic** — the Limine UKI they build on the ESP is never read
by ZBM. Plan: leave them installed, `systemctl mask limine-snapper-sync.service`, leave `snapper`
unconfigured. ❓ Verify at test time that installing `limine` doesn't insert an EFI NVRAM entry ahead
of ZBM; if it does, re-assert `BootOrder` (ZBM first) in the `.install`.

Decision open: **hard-dep `omarchy`** (one-command install, drags limine/snapper) vs **leaf-only deps**
(`zfs-dkms-git zfs-utils-git zfsbootmenu`, admin installs omarchy separately). Leaning hard-dep.

### 1.2 Payload — fork-only files (no collision; ship as real files)
| Source (fork) | Package destination |
|---|---|
| `bin/omarchy-bootstrap-zfs` | `/usr/bin/` |
| `bin/omarchy-fs-type`, `omarchy-fs-zfs`, `omarchy-fs-btrfs` | `/usr/bin/` |
| `bin/omarchy-cmdline-add` | `/usr/bin/` |
| `bin/omarchy-refresh-zbm` | `/usr/bin/` |
| `bin/omarchy-zfs-snapshot`, `omarchy-zfs-scrub`, `omarchy-zfs-kernel-compat-check` | `/usr/bin/` |
| `default/pacman-hooks/90-omarchy-zfs-kernel-guard.hook` | `/usr/share/libalpm/hooks/` |
| (new) `00-zfs-autosnap.hook` | `/usr/share/libalpm/hooks/` |
| `default/systemd/system/omarchy-zfs-scrub.{service,timer}` | `/usr/lib/systemd/system/` |
| `default/zfsbootmenu/config.yaml.example`, `hooks/**` | `/etc/zfsbootmenu/` (+ example) |
| (new) `zz-omarchy-zfs-ensure-mkinitcpio.hook` + `omarchy-zfs-ensure-mkinitcpio` | see 1.4 |

Note: the kernel-guard hook currently execs `/usr/local/bin/omarchy-zfs-kernel-compat-check`; update
it to `/usr/bin/omarchy-zfs-kernel-compat-check` (package path).

### 1.3 Collisions with the stock package (validated — cannot co-own these paths)
- **`omarchy-snapshot`** → **do not ship.** The fork already split ZFS logic into `omarchy-zfs-snapshot`;
  stock `omarchy-snapshot` `exit 127`s (no-op) when snapper is absent, which `omarchy update` ignores.
  ZFS snapshots come from our `00-zfs-autosnap.hook` (pre-transaction) + `omarchy-zfs-snapshot` (manual).
- **`omarchy-update-system-pkgs`** → **do not ship.** Its only fork delta was to run
  `zfs-archzfs-repo.sh`, `zfs-kernel-guard.sh`, and `omarchy-zfs-snapshot` before upgrade — all three
  are now package-native (`.install` scriptlet + shipped guard hook + autosnap hook). Drop the patch.
- **`omarchy-hibernation-{setup,remove,available}`** → the one real collision (VALIDATED: stock only
  skips when `limine-mkinitcpio` is absent, but our `omarchy` dep pulls `limine-mkinitcpio-hook`, so
  stock proceeds to `btrfs subvolume create /swap` and **fails on ZFS**). Fork versions do ZFS
  zvol-swap, so **ours must win**. Two options:
  - (A) Shadow: install to `/usr/local/bin/` — validated that `/usr/local/bin` precedes `/usr/bin`
    in PATH. Clean win, but `/usr/local` is against strict Arch packaging policy.
  - (B) Rename to `omarchy-zfs-hibernation-*` and document. Loses muscle-memory / menu wiring.
  - **DECIDED: (B) rename to `omarchy-zfs-hibernation-*`.** Don't ship the stock names; update fork menu wiring.

### 1.4 The mkinitcpio self-healing hook (chosen approach)
Validated necessity: `omarchy update` runs `pacman -Syu --overwrite '…/omarchy_hooks.conf'` **every
time**, re-clobbering our zfs hook — so a static one-time edit would be undone. The hook *derives* the
correct HOOKS from upstream's current file, so upstream hook additions are inherited automatically.

`/usr/share/libalpm/hooks/zz-omarchy-zfs-ensure-mkinitcpio.hook` (zz- → runs LAST, after
`90-mkinitcpio-install` and any limine hook):
```
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = etc/mkinitcpio.conf.d/omarchy_hooks.conf
Target = etc/mkinitcpio.conf
Target = usr/lib/modules/*/vmlinuz
[Action]
Description = Ensuring ZFS hook is present in initramfs (omarchy-zfs)…
When = PostTransaction
Exec = /usr/bin/omarchy-zfs-ensure-mkinitcpio
NeedsTargets
```
`omarchy-zfs-ensure-mkinitcpio` logic:
1. Read the effective `HOOKS=(…)` from `omarchy_hooks.conf`.
2. If `zfs` isn't already before `filesystems`, insert it there.
3. Write the corrected full line to **our own** drop-in `/etc/mkinitcpio.conf.d/zz-omarchy-zfs.conf`
   (sorts after `omarchy_hooks.conf`, so a `HOOKS=` reassignment wins). Do **not** edit
   `omarchy_hooks.conf` itself (avoids `.pacnew` ownership fights).
4. Run `mkinitcpio -P` (final regen wins) and `omarchy-refresh-zbm` (both ESPs).
Runs `OMARCHY_ALLOW_DIRECT_PACMAN`-safe (no pacman calls inside).

### 1.5 `.install` scriptlet
- `post_install` / `post_upgrade`: configure `[archzfs]` (idempotent — `zfs-archzfs-repo.sh` already
  checks for an existing ZFS repo), enable `omarchy-zfs-scrub.timer`, ensure `/etc/hostid` exists
  (`zgenhostid` if missing — hardens pool import, borrowed from rival #5938), run
  `omarchy-zfs-ensure-mkinitcpio` once, `systemctl mask limine-snapper-sync.service`, and re-assert
  ZBM `BootOrder` if needed.
- All internal `pacman` calls set `OMARCHY_ALLOW_DIRECT_PACMAN=1` to pass the Quattro update guard.

---

## 2. Local system migration (this workstation)

**Golden rule: do the VM/BE dry-run in §5 first. Do not run on metal until the VM boots clean.**

1. **Snapshot everything.** `omarchy-zfs-snapshot create` (or `zfs snapshot -r rpool@pre-quattro`);
   confirm ZBM can see it. Confirm both ESP ZBM images boot.
2. **Stage the mkinitcpio guard first.** Pre-place `zz-omarchy-zfs.conf` (with `zfs`) so that even if
   the migration regenerates initramfs before `omarchy-zfs` is installed, `zfs` is present.
3. **Run the stock migration**, but expect and accept that it clobbers `omarchy_hooks.conf`:
   `omarchy-upgrade-to-quattro --dev` (edge). Do **not** reboot yet.
4. **Install `omarchy-zfs`** from our repo (§3): `sudo pacman -S omarchy-zfs`. Its `.install`
   re-asserts the zfs hook, regenerates initramfs, refreshes ZBM, re-adds `[archzfs]`, enables scrub.
5. **Verify before reboot** (§5 checklist): `lsinitcpio /boot/initramfs-linux.img | grep zfs`, guard
   script resolves (`readlink -f $(command -v omarchy-zfs-kernel-compat-check)`), `BootOrder` still
   ZBM-first, scrub timer enabled, plugins + shell.json intact.
6. **Reboot.** If it fails: ZBM → select `rpool@pre-quattro` → rollback.
7. Remove the `~/.local/share/omarchy.*.bak` checkout only after a few clean days.

---

## 3. The shareable package repo

### 3.1 Build
- Author `PKGBUILD` + `omarchy-zfs.install` (stock Quattro has no in-tree PKGBUILDs — standard Arch
  PKGBUILD). `pkgver` from the fork tag scheme (`v<upstream>-zfs.N`). Build with `makepkg`.
- Sign packages: `makepkg --sign` (our packaging GPG key; all commits already GPG-signed).

### 3.2 Repo database
```
repo-add --sign omarchy-zfs.db.tar.zst omarchy-zfs-*.pkg.tar.zst
```
Produces `omarchy-zfs.db` / `.files`. Host the directory over HTTPS (or a local `file://` mirror for
just this box).

### 3.3 Consumption
`/etc/pacman.conf`:
```
[omarchy-zfs]
SigLevel = Required   # or Optional TrustAll for a local unsigned mirror
Server = https://<host>/omarchy-zfs/$arch
```
Validated: the Quattro pacman guard does **not** police `pacman.conf`/repos, so this survives, and
`omarchy update` (`pacman -Syu` across all repos) auto-updates `omarchy-zfs`. For zero-touch on fresh
installs, distribute via Quattro's `omarchy/hooks/pre-refresh-pacman.d/add-custom-repo.sample`.

---

## 4. The ZFS installer ISO

Needed because the stock Quattro ISO installs btrfs/ext4 via archinstall + Limine and cannot lay down
root-on-ZFS. Ours must bootstrap the pool/datasets/ZBM then install the package set.

- Reuse `bootstrap/iso-zfs.sh` + `bin/omarchy-bootstrap-zfs` (existing fork logic: pool + dataset
  layout, `/var/cache` & `/var/log` child datasets, ZBM install to ESP(s), keystore/unlock).
- **Layout default (directive 2026-07-21): the package + ISO DEFAULT to the archzfs / Arch-wiki
  dataset layout (pool `zroot`, `zroot/ROOT/default`, `zroot/data/{home,root,srv}`, `zroot/var/...`),
  even though this workstation runs the legacy `rpool/omarchy/root`.** Runtime tooling
  (`omarchy-fs-*`, scrub, snapshot, refresh-zbm) must stay layout-agnostic — discover pool/dataset
  dynamically — so legacy `rpool/omarchy/*` installs keep working unchanged. Greenfield = zroot.
- Flow: boot ISO → partition + create `rpool` + datasets → `pacstrap` base + `zfs-dkms-git`/utils +
  `zfsbootmenu` + `omarchy-zfs` (pulls `omarchy-dev`) → install ZBM to both ESPs → set `bootfs` +
  `org.zfsbootmenu:commandline` → first-boot.
- ❓ Decide ISO build tooling: `archiso` profile vs. whatever Quattro's ISO pipeline becomes. Track
  upstream's Quattro ISO story before committing.
- This ISO is also our disaster-recovery media.

---

## 5. Validation / test plan (do this before §2 on metal)

Fastest safe loop = `zfs clone` a pre-upgrade snapshot into a throwaway boot environment, or a ZFS-root VM.

Go/No-Go checklist after a dry-run migration + `omarchy-zfs` install, **before reboot**:
- [ ] `lsinitcpio /boot/initramfs-linux.img | grep -q zfs` (THE boot-safety signal)
- [ ] `/etc/hostid` exists and is embedded in the initramfs (`lsinitcpio … | grep hostid`)
- [ ] `diff` old vs new `omarchy_hooks.conf`; confirm our `zz-omarchy-zfs.conf` overrides it
- [ ] `readlink -f "$(command -v omarchy-zfs-kernel-compat-check)"` resolves to `/usr/bin/…` (not dangling)
- [ ] kernel-guard hook fires on a dummy `linux` `-Syu` (test with a compatible + an incompatible kernel)
- [ ] `efibootmgr` — `BootOrder` still ZBM-first; `limine` did not steal the top entry
- [ ] `systemctl is-enabled omarchy-zfs-scrub.timer` = enabled
- [ ] Quickshell widgets present: `~/.config/omarchy/plugins/peteonrails.{weather,calendar,next-meeting}` + `shell.json`
- [ ] Voxtype OSD works (`voxtype-bin` standalone — expected unaffected)
- [ ] `omarchy update` completes and does NOT strip the zfs hook (the self-heal hook fires last)
- [ ] ZBM boots the pre-upgrade snapshot (rollback path proven)

---

## 6. Competitive positioning

**Rival:** Berend de Boer (`berenddeboer`), a cold-open, non-collaborative contributor (self-disclosed
AI-generated). Live status as of 2026-07-21:
- `basecamp/omarchy#5637` "Recognize ZFS root installs" — **CLOSED unmerged** (2026-05-21).
- `basecamp/omarchy#5938` "Gracefully handle installations on ZFS file systems" — **OPEN but stale**
  (created 2026-05-21, 0 comments, no maintainer engagement in 2 months, +120/-39). Root-*recognition*
  only — "does not enable or install" ZFS. **Limine + mkinitcpio hooks, not ZBM.**
- `omacom-io/omarchy-iso#80` "Add experimental ZFS install support" — **OPEN but cold** (last touched
  2026-05-15). His only *install* path: **/home-only ZFS encryption** (unencrypted pool, per-user
  `zroot/data/home/$USER` unlocked by PAM), **Limine** direct boot, custom archiso.

**Reading of the race:** upstream has committed to **no** ZFS direction; the rival's work is stalled
and unengaged. Nobody has shipped a complete **root-on-ZFS** solution for Quattro. The field is open.

**Our differentiation (keep and lead with):**
- **Whole-pool encryption** (stolen-laptop threat model covers `/etc`, `/var/log`, `/var/lib`, creds,
  machine-id — not just `/home`) vs his per-user-home encryption.
- **ZFSBootMenu** (boot-environment selection, snapshot rollback at boot) vs his Limine direct boot.
- **Package + repo + ISO** distribution native to Quattro vs a single stalled archiso PR.

**Borrow from #5938 (legitimate, convert to our idiom):**
- **Embed `/etc/hostid` in the initramfs.** VALIDATED GAP: this box has no `/etc/hostid`, and the zfs
  mkinitcpio install hook only embeds it `if [[ -f /etc/hostid ]]` — so ours is currently absent.
  Add `zgenhostid` to `omarchy-bootstrap-zfs` + the package `.install`; it hardens pool import.
- Skip btrfs-only hibernation on non-btrfs roots — aligns with our hibernation collision fix (§1.3).
- `[archzfs]` preservation — we already do this.

**Stance:** per our upstream-watch rule (`loop-prompt-upstream-watch.md`) we do **not** comment on or
PR against `basecamp/omarchy`. "Winning" = being the definitive ZFS-on-Omarchy *fork/distribution*
for Quattro, not getting merged upstream. (Revisit only if you want to change that posture.)

---

## 7. Decisions (resolved 2026-07-21)
1. **Dependency model: hard-dep `omarchy`** — `depends=(omarchy zfs-dkms-git zfs-utils-git zfsbootmenu …)`. One-command install; inert limine/snapper accepted.
2. **Hibernation: rename to `omarchy-zfs-hibernation-{setup,remove,available}`** — distinct commands, policy-clean, no PATH fragility. Do NOT ship the stock names. Update any fork menu wiring to the new names.
3. **Repo: phased** — build once; serve `file://` (`/var/cache/omarchy-zfs-repo`) for the local migration + VM test; publish to public HTTPS (GitHub Pages leaning) when ready to share.
4. **ISO: build our own archiso, as phase 4** — after package + repo are done and VM-tested; `zroot` default + `pacstrap omarchy-zfs`; reuse `bootstrap/iso-zfs.sh`.
5. Limine/snapper coexistence: mask-and-ignore (mask `limine-snapper-sync.service`, leave snapper unconfigured) — carried forward as the working plan; revisit only if BootOrder testing shows interference.

## 7a. Repo structure (resolved 2026-07-21)
- **New standalone repo `peteonrails/omarchy-zfs`** — NOT a branch/fork of `omarchy-on-zfs`.
  - `main`: `PKGBUILD`, `omarchy-zfs.install`, `omarchy-zfs-*` scripts, libalpm hooks, systemd units,
    ZBM config, `bootstrap/`, archiso profile.
  - `gh-pages` (or Releases): built + signed pacman repo → the shareable `[omarchy-zfs]`.
- **Retire the upstream-merge treadmill.** `omarchy-zfs` depends on stock omarchy *packages*, so we no
  longer mirror/merge the omarchy source tree. Kills the chronic-conflict pain (rr-cache, the 5
  conflict files, `v<upstream>-zfs.N` tagging).
- **Freeze `omarchy-on-zfs`** as legacy reference + the "edge = git-checkout" fallback. Stop merging
  upstream into it once the package ships. Migrate ~20 ZFS-only files out (optionally `git log
  --follow` to preserve provenance); drop the upstream *patches* (omarchy-snapshot,
  update-system-pkgs) that the package hooks/drop-ins now replace.
- ❓ Phase-2 validation (repo-agnostic): does stock Quattro first-run/preflight choke on a ZFS root
  (Berend #5938's target)? If so, ship neutralizing hooks/drop-ins in the package.

## Build order
Phase 1 — create `omarchy-zfs` repo (local first, no push); PKGBUILD + `.install` +
  `omarchy-zfs-ensure-mkinitcpio` hook/script; migrate ZFS files; build locally.
Phase 2 — local `file://` repo; VM/BE dry-run per §5 checklist.
Phase 3 — on-metal migration (§2); publish HTTPS repo; freeze `omarchy-on-zfs`.
Phase 4 — archiso (`zroot` default).
