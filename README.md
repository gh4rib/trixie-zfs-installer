# trixie-zfs-installer

Two unattended installers for **Debian 13 (Trixie) with root on encrypted ZFS**, each faithful to a different upstream guide:

| Script | Bootloader | `/boot` | Upstream guide |
|---|---|---|---|
| `debian13-zbm-install.sh` | rEFInd → **ZFSBootMenu** | on the ZFS root dataset | [ZFSBootMenu — Debian (UEFI)](https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html) |
| `debian13-root-on-zfs-grub.sh` | **GRUB** | separate **ext4** partition | [OpenZFS — Debian Trixie Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html) |

Both scripts:

- use **ZFS native encryption** (`aes-256-gcm`, passphrase) — mandatory, not optional
- require the disk to be given as a stable `/dev/disk/by-id/…` path
- build the **same dataset hierarchy** with separate datasets for `/home`, `/root`, `/opt`, `/srv`, `/var/log`, `/var/spool`, `/var/tmp` and the container/VM stores
- create a `default` and a `baseline` boot environment
- install a **1 GiB encrypted swap partition** with a fresh random key each boot
- install KDE, GNOME, or nothing, selected by an environment variable
- install CPU microcode and a broad firmware set (including `firmware-iwlwifi`)
- leave boot messages **visible** — `quiet` is not set anywhere

Every step is tagged in the source with `[GUIDE]` (straight from the upstream document) or `[DEVIATION]` (with the reason inline), so you can audit either script against its guide.

---

## Table of contents

- [Introduction](#introduction)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Disk layouts](#disk-layouts)
- [Dataset hierarchy](#dataset-hierarchy)
- [Environment variables](#environment-variables)
- [What happens at boot](#what-happens-at-boot)
- [After installation](#after-installation)
- [Upgrading OpenZFS and the pool](#upgrading-openzfs-and-the-pool)
- [Recovery](#recovery)
- [Deviations from the upstream guides](#deviations-from-the-upstream-guides)
- [Safety notes](#safety-notes)
- [Credits](#credits)
- [License](#license)

---

# Introduction

### `debian13-zbm-install.sh` — ZFSBootMenu

ZFSBootMenu is a small Linux+initramfs bundled into a single EFI executable. It imports your pool, asks for the passphrase, lists every boot environment and snapshot it can find, and `kexec`s into the one you choose.

**Choose it if** you want boot environments to be a first-class, interactive feature: rolling back a bad upgrade is a menu selection at boot, not a rescue USB. You also get a snapshot browser, a diff viewer, a recovery shell, and pool health reporting before the OS ever starts.

**The cost:** ZFSBootMenu contains its own copy of the ZFS userland and module. If you `zpool upgrade` to feature flags your ZBM image doesn't understand, it cannot import the pool and the machine won't boot. This is manageable — see [Upgrading OpenZFS and the pool](#upgrading-openzfs-and-the-pool) — but it is a real constraint you have to remember forever.

### `debian13-root-on-zfs-grub.sh` — GRUB

GRUB reads the kernel and initramfs from a plain ext4 `/boot`. It never touches ZFS at all; the kernel's initramfs imports the pool and prompts for the passphrase.

**Choose it if** you want the boring, maximally robust option. Because GRUB never reads the root pool, `zpool upgrade rpool` is **always safe**, forever. Any Debian live ISO can rescue the system with no special tooling. This is also the closest thing to a "normal" Debian install that still has root on ZFS.

**The cost:** boot environments are not interactive. The script generates a GRUB entry for `baseline`, but switching to an arbitrary snapshot means editing the kernel command line at the GRUB prompt or booting a live ISO.

---

## Requirements

- A **64-bit UEFI** system (the GRUB script can also do legacy BIOS via `BOOT_MODE=bios`)
- A **whole disk** to erase — these scripts are not for dual-booting
- A **Debian 13 Live ISO**, booted in the matching firmware mode
  - The OpenZFS guide recommends a GUI image (e.g. GNOME) for the GRUB script
- Working internet in the live environment
- ≥ 4 GiB RAM recommended (ZFS is slow below 2 GiB)
- Patience: `zfs-dkms` compiles in the live environment on the ZFSBootMenu path, which takes several minutes before anything visible happens

---

## Quick start

```bash
# In the live environment
sudo -i
apt update && apt install -y git
git clone https://github.com/YOURNAME/debian-zfs-installers.git
cd debian-zfs-installers
chmod +x *.sh
```

**Find your disk.** Run either script with no `DISK` set and it lists the candidates and exits:

```bash
./debian13-zbm-install.sh
# Whole disks under /dev/disk/by-id/:
#   /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4    931.5G Samsung SSD 990 PRO
#   /dev/disk/by-id/ata-CT1000MX500SSD1_2015E2A0B1C2          931.5G CT1000MX500SSD1
```

**ZFSBootMenu install:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=kde \
./debian13-zbm-install.sh
```

**GRUB install:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=kde \
./debian13-root-on-zfs-grub.sh
```

Both scripts print a full configuration summary, then require you to type `ERASE` before touching the disk. Passwords are prompted interactively (root, admin user, ZFS passphrase) unless supplied as variables.

### Not sure about the keyboard layout?

Both scripts inherit the layout you picked at the ISO boot menu. To see the variants available for your layout:

```bash
LIST_KEYBOARD=yes ./debian13-zbm-install.sh
```

An empty `KEYBOARD_VARIANT` is normal and correct for most people — it means the standard layout for that country code.

---

## Disk layouts

### `debian13-zbm-install.sh` (ZFSBootMenu)

| Part | Size | Type | Purpose |
|---|---|---|---|
| 1 | 1024 MiB | `ef00` | ESP → `/boot/efi`, holds rEFInd + ZFSBootMenu |
| 2 | 1024 MiB | `8309` | encrypted swap |
| 3 | rest − 10 MiB | `bf00` | `zroot` |

The kernel and initramfs live on the ZFS root dataset, so they are snapshotted and rolled back along with everything else. That is the whole point of the design.

### `debian13-root-on-zfs-grub.sh` (GRUB)

| Part | Size | Type | Purpose |
|---|---|---|---|
| 1 | 1 MiB | `EF02` | BIOS boot (tiny; keeps the legacy path open) |
| 2 | 600 MiB | `EF00` | ESP → `/boot/efi` |
| 3 | 2048 MiB | `8300` | `/boot` — **ext4** |
| 4 | 1024 MiB | `8200` | encrypted swap |
| 5 | rest | `BF00` | `rpool` |

---

## Dataset hierarchy

Identical in both scripts (pool named `zroot` for ZFSBootMenu, `rpool` for GRUB, matching each guide's convention):

```
POOL/ROOT                       mountpoint=none   canmount=off
├── default                     mountpoint=/      canmount=noauto   ← active
└── baseline                    mountpoint=/      canmount=noauto   ← factory image
POOL/data                       mountpoint=none   canmount=off
├── home                        /home
│   ├── root                    /root
│   └── <username>              /home/<username>
├── opt                         /opt
├── srv                         /srv
└── var                         (container, canmount=off)
    ├── lib                     (container, canmount=off)
    │   ├── containers          /var/lib/containers      Podman
    │   ├── docker              /var/lib/docker          Docker
    │   ├── libvirt             /var/lib/libvirt         VMs
    │   └── lxc                 /var/lib/lxc             LXC
    ├── log                     /var/log
    ├── spool                   /var/spool
    └── tmp                     /var/tmp
```

The `ROOT`/`data` split is what makes boot environments useful: rolling back `ROOT/default` reverts the OS without touching home directories, logs, or VM images.

The container and VM datasets exist but **no daemons are installed**. Install `docker.io`, `podman`, `libvirt-daemon-system` or `lxc` when you need them and they land on their own datasets automatically.

### Optional tuning

With `DATASET_TUNING=yes` (the default), the scripts apply a light, conservative set of properties: `atime=off` across `data/var`, `setuid=off devices=off` on `/var/tmp`, `compression=zstd recordsize=64K` on `/var/log`, `recordsize=64K` on libvirt, `32K` on the container stores, and `com.sun:auto-snapshot=false` on the container/VM datasets. Set `DATASET_TUNING=no` to inherit pool defaults everywhere and tune it yourself.

---

## Environment variables

### Common to both scripts

| Variable | Default | Notes |
|---|---|---|
| `DISK` | — | **Required.** Must be a `/dev/disk/by-id/…` whole-disk path |
| `TARGET_HOSTNAME` | `debian-zbm` / `debian` | |
| `ADMIN_USER` | `admin` | Gets its own dataset and `sudo` |
| `ADMIN_FULLNAME` | `System Administrator` | GECOS field |
| `ADMIN_GROUPS` | see script | `sudo` is always added |
| `TIMEZONE` | `Etc/UTC` | Any zoneinfo name; validated |
| `LOCALE` | `en_US.UTF-8` | Must be UTF-8; `en_US.UTF-8` generated regardless |
| `KEYMAP` | inherited from live ISO | Validated against the XKB rules list |
| `KEYBOARD_VARIANT` | inherited from live ISO | Empty = standard layout. Pass `KEYBOARD_VARIANT=` to force none |
| `DESKTOP` | `kde` | `kde`, `gnome`, `none` |
| `DESKTOP_SIZE` | `minimal` | `minimal` or `full` |
| `SWAP_SIZE_MIB` | `1024` | `0` disables swap entirely |
| `SWAP_RANDOM_SOURCE` | `/dev/urandom` | See [note on swap](#a-note-on-random-key-swap) |
| `POOL_NAME` | `zroot` / `rpool` | |
| `BE_NAME` | `default` | Active boot environment |
| `BASELINE_NAME` | `baseline` | |
| `BASELINE_MODE` | `clone` | `clone`, `send`, `none` |
| `ASHIFT` | `12` | |
| `COMPRESSION` | `lz4` | |
| `DATASET_TUNING` | `yes` | |
| `SUITE` / `MIRROR` | `trixie` / deb.debian.org | |
| `COMPONENTS` | `main contrib non-free-firmware` | |
| `ENABLE_BACKPORTS` | `yes` | Adds the repo unpinned; installs nothing from it |
| `INSTALL_FIRMWARE` | `yes` | Microcode + probed firmware set |
| `EXTRA_PACKAGES` | — | Space-separated |
| `ROOT_PASSWORD` / `ADMIN_PASSWORD` / `ZFS_PASSPHRASE` | prompted | Passing these on the command line leaks them to `ps` |
| `FORCE` | `no` | `yes` skips **only** the `ERASE` confirmation |
| `LIST_KEYBOARD` | — | List variants and exit |

### ZFSBootMenu script only

| Variable | Default | Notes |
|---|---|---|
| `ESP_SIZE_MIB` | `1024` | |
| `SWAP_MODE` | `random` | `random`, `luks`, `none` |
| `ZBM_INSTALL` | `prebuilt` | `prebuilt` (download the EFI) or `source` (build with `generate-zbm`) |
| `ZBM_CMDLINE` | `loglevel=6` | ZFSBootMenu's **own** kernel command line |
| `KERNEL_CMDLINE` | `loglevel=6 systemd.show_status=yes` | What ZBM passes to Debian |
| `ZBM_TIMEOUT` | `10` | Countdown before booting `bootfs` |
| `ZBM_FALLBACK` | `yes` | Also install to `EFI/BOOT/BOOTX64.EFI` |
| `ENCRYPTION_ALGO` | `aes-256-gcm` | |
| `POOL_COMPAT` | *(empty)* | Set to `openzfs-2.3-linux` to pin feature flags |

> **`ZBM_CMDLINE` and `KERNEL_CMDLINE` are not the same thing.** The first configures ZFSBootMenu's own kernel (what you see while it imports the pool and asks for the passphrase). The second is stored in `org.zfsbootmenu:commandline` and configures Debian. Conflating them is the most common mistake with this setup.

### GRUB script only

| Variable | Default | Notes |
|---|---|---|
| `BOOT_MODE` | `uefi` | `uefi` or `bios` |
| `ESP_SIZE_MIB` | `600` | |
| `BOOT_SIZE_MIB` | `2048` | ext4 `/boot` |
| `GRUB_VERBOSE` | `yes` | Removes `quiet`, sets `GRUB_TERMINAL=console` |
| `GRUB_CMDLINE_DEFAULT` | `loglevel=6` | |
| `GRUB_TIMEOUT_SECS` | `5` | |
| `REMOVE_OS_PROBER` | `yes` | Avoids `update-grub` noise on single-boot systems |
| `DISABLE_LOG_COMPRESSION` | `yes` | `/var/log` is already a compressed dataset |
| `DNODESIZE` | `auto` | |
| `NORMALIZATION` | `formD` | **Cannot be changed after pool creation.** Implies `utf8only=on` |
| `INSTALL_SSH` | `no` | |
| `BLKDISCARD` | `no` | Full-disk TRIM before partitioning |

---

## What happens at boot

### ZFSBootMenu

```
firmware → rEFInd → ZFSBootMenu → zroot/ROOT/default
```

rEFInd offers four ways in, all using the same EFI image:

| Entry | Behaviour |
|---|---|
| Boot default | 10s countdown, then boots `bootfs` |
| Boot to menu | always show the boot-environment selector |
| Boot immediately | no menu, no countdown |
| Verbose debug | `loglevel=7`, ZBM's full internal tracing |

Inside ZFSBootMenu: `Ctrl-H` for help, `Ctrl-S` to browse snapshots of the selected environment, `Ctrl-R` for a recovery shell.

Change Debian's boot verbosity later without touching the bootloader:

```bash
sudo zfs set org.zfsbootmenu:commandline="loglevel=7 systemd.show_status=yes" zroot/ROOT
sudo zfs set org.zfsbootmenu:commandline="quiet loglevel=3" zroot/ROOT   # back to silent
```

The property is inherited by every environment under `ROOT`. `%{parent}` expands to the parent's value, so you can make just one environment verbose:

```bash
sudo zfs set org.zfsbootmenu:commandline="loglevel=7 %{parent}" zroot/ROOT/default
```

ZFSBootMenu's own verbosity and countdown live in `/boot/efi/EFI/ZBM/refind_linux.conf` — plain text, no regeneration needed.

### GRUB

```
firmware → GRUB (reads ext4 /boot) → kernel + initramfs → unlock rpool
```

The initramfs prompts for the passphrase. The GRUB menu has an entry for `rpool/ROOT/default` and one for `rpool/ROOT/baseline`, generated by `/etc/grub.d/11_baseline_be` (which re-runs on every `update-grub`, so it tracks kernel updates).

The OpenZFS guide suggests reverting the verbose settings once you've rebooted twice and are confident everything works:

```bash
sudo nano /etc/default/grub     # add 'quiet', comment out GRUB_TERMINAL
sudo update-grub
```

---

## After installation

### Creating a new boot environment

`canmount` is **not inheritable**, and two filesystems trying to mount at `/` will prevent the system from booting. Set it explicitly on every environment:

```bash
sudo zfs snapshot POOL/ROOT/default@pre-upgrade
sudo zfs clone -o canmount=noauto -o mountpoint=/ \
    POOL/ROOT/default@pre-upgrade POOL/ROOT/new
```

On ZFSBootMenu you can do this from the boot menu instead. On GRUB, copy `/etc/grub.d/11_baseline_be` as a template, or edit the kernel line at the GRUB prompt and change `root=ZFS=…`.

### Adding a user

A per-user dataset makes the home directory exist — and **`useradd` will not copy `/etc/skel` into a directory that already exists.** It prints `Not copying any file from skel directory into it` and carries on, leaving the account with no `.bashrc` or `.profile`. Do it explicitly:

```bash
sudo zfs create -o mountpoint=/home/NAME POOL/data/home/NAME
sudo useradd -M -d /home/NAME -s /bin/bash NAME
sudo cp -a /etc/skel/. /home/NAME/
sudo chown -R NAME:NAME /home/NAME && sudo chmod 0750 /home/NAME
sudo usermod -a -G sudo NAME
sudo passwd NAME
```

### Updating ZFSBootMenu

```bash
sudo curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
```

Leave `VMLINUZ-BACKUP.EFI` alone as your known-good image.

### Cleanup

Both scripts leave an `@install` or `@baseline` snapshot. Once you're happy:

```bash
sudo zfs list -t snapshot
sudo zfs destroy POOL/ROOT/default@install
sudo usermod -p '*' root          # disable the root password (optional)
```

If `BASELINE_MODE=clone`, the `@baseline` snapshot **cannot** be destroyed while the clone exists. That is deliberate — it's the guarantee a factory image should have.

---

## Upgrading OpenZFS and the pool

Both scripts add `trixie-backports` (unpinned, so nothing is pulled from it automatically).

### On the GRUB script

Nothing to think about. GRUB never reads the root pool, so:

```bash
sudo apt install -t trixie-backports zfs-dkms zfsutils-linux zfs-initramfs
sudo update-initramfs -c -k all
# reboot, verify `zfs version`, then:
sudo zpool upgrade rpool
```

### On the ZFSBootMenu script — order matters

ZFSBootMenu ships its own ZFS. **`zpool upgrade` is irreversible, and a ZBM image that predates a newly enabled feature flag cannot import the pool.** Follow this order:

1. **Install the newer ZFS in the OS:**
   ```bash
   sudo apt install -t trixie-backports zfs-dkms zfsutils-linux zfs-initramfs
   sudo update-initramfs -c -k all
   ```
   Reboot; confirm both userland and kmod report the new version with `zfs version`.

2. **Refresh ZFSBootMenu first.** Check which ZFS version a release embeds at
   [zbm-dev/zfsbootmenu/releases](https://github.com/zbm-dev/zfsbootmenu/releases), then download it.

3. **Reboot through the new ZBM image** and confirm it still imports the pool and boots. *Only then:*
   ```bash
   sudo zpool upgrade zroot
   ```

Note that once the pool is upgraded, `VMLINUZ-BACKUP.EFI` stops being a usable fallback unless it too has been refreshed.

The scripts create the pool with **no `compatibility=` pin**, so it has every feature flag the installing ZFS supports. Set `POOL_COMPAT=openzfs-2.3-linux` at install time if you'd rather have the guide's conservative default.

---

## Recovery

From any Debian live ISO:

```bash
sudo -i
apt update && apt install -y zfsutils-linux
zpool import -f -N -R /mnt POOL
zfs load-key -a                        # or: zfs load-key POOL
zfs mount POOL/ROOT/default
zfs mount -a
mount /dev/disk/by-id/…-partN /mnt/boot   # GRUB script only (ext4 /boot)

mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys
mount -t tmpfs tmpfs /mnt/run && mkdir /mnt/run/lock
chroot /mnt /bin/bash --login
mount /boot/efi
```

When done:

```bash
exit
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a
```

If either script recorded problems during installation, they are kept at `/root/INSTALL-WARNINGS.txt` on the installed system.

---

## Deviations from the upstream guides

Both scripts are annotated inline, but the ones worth knowing up front:

### ZFSBootMenu script

- **1024 MiB ESP** instead of 512, leaving room for several ZBM images and rEFInd.
- **The pool key file is created.** The guide's encrypted `zpool create` references `/etc/zfs/zroot.key` as a file "created in a previous step" — but the Debian page never shows that step. The script creates it before `zpool create`.
- **Encrypted export/import is spelled out.** The guide's encrypted tab omits it; the script does `zpool export` → `zpool import -N -R /mnt` → `zfs load-key` → mount, which is what the other guides in the same series actually do.
- **The vdev is referenced by PARTUUID**, so the pool doesn't care about device enumeration order.
- **`EFI/BOOT/BOOTX64.EFI` fallback**, for firmware that silently drops NVRAM boot entries. The guide flags this problem and links to its Portable ZFSBootMenu page but doesn't automate it.
- **Verbose command lines**, microcode, expanded firmware, and `zfs-zed` — none of which the guide covers.

### GRUB script

- **ext4 `/boot` instead of `bpool`.** This is the big one. The guide creates a second ZFS pool for `/boot` pinned to `-o compatibility=grub2`, because GRUB understands only a subset of pool features. Replacing it with ext4 removes that entire mechanism: no `bpool`, no feature-flag pin, no `zfs-import-bpool.service` (guide step 4.13), no `bpool` entry in `zfs-list.cache`. The consequence is that `zpool upgrade rpool` is permanently safe.
- **Non-interactive native encryption.** The guide's `-O keylocation=prompt` makes `zpool create` prompt interactively. The script creates the pool against a temporary key in `/dev/shm`, then runs `zfs set keylocation=prompt` and shreds the file — ending in exactly the state the guide describes.
- **Ubuntu-isms corrected.** Guide steps 1.6 and 4.7 name `linux-headers-generic` and `linux-image-generic`, which are Ubuntu metapackages that don't exist in Debian. The script probes the archive and falls back to the `-amd64` variants.
- **Swap on a partition, not a zvol.** The guide's step 7 uses a zvol and warns that under extreme memory pressure this can lock the system up. `RESUME=none` is set either way, per the guide.
- **`tasksel --new-install` replaced** by the `DESKTOP` variable, since tasksel is interactive.

---

## Safety notes

- **These scripts erase an entire disk.** They are not for dual-booting. Back up first.
- `FORCE=yes` skips **only** the `ERASE` confirmation. It does not skip password prompts, and all preflight validation still runs.
- Test in a VM before running on hardware you care about. For QEMU/KVM, set a unique serial on each virtual disk so `/dev/disk/by-id` aliases appear.
- **Your passphrase is likely the weakest link.** On the ZFSBootMenu path it is typed inside ZBM, which uses a basic keymap — prefer unshifted ASCII you can type blind.

### A note on random-key swap

The swap partition uses **plain dm-crypt with a fresh key drawn from `/dev/urandom` on every boot**, via crypttab's `swap` option. Nothing on it survives a reboot.

This is *not* LUKS, and cannot be: LUKS requires a persistent header with keyslots, which is incompatible with a per-boot random key. The consequence is that **hibernation is impossible**, which is why `RESUME=none` is configured.

If you need hibernation, the ZFSBootMenu script offers `SWAP_MODE=luks` — a persistent LUKS2 volume unlocked from a keyfile on the encrypted root. Note that the scripts do not configure a resume device; that is left to you.

`/dev/urandom` is the default rather than `/dev/random` because they are cryptographically identical on modern kernels and `/dev/urandom` never blocks. Set `SWAP_RANDOM_SOURCE=/dev/random` if you prefer.

---

## Credits

These scripts are automation wrappers. All the hard thinking belongs to the upstream projects.

### Upstream projects

- **[ZFSBootMenu](https://zfsbootmenu.org/)** — the boot environment manager the first script installs.
  Documentation: <https://docs.zfsbootmenu.org/> · Source: <https://github.com/zbm-dev/zfsbootmenu>
  Thanks to Zach Dykstra and the ZFSBootMenu team.

- **[OpenZFS](https://openzfs.org/)** — ZFS on Linux itself, and the *Root on ZFS* documentation series the second script follows.
  Documentation: <https://openzfs.github.io/openzfs-docs/> · Source: <https://github.com/openzfs/zfs>
  The Debian HOWTO is maintained by rlaager and contributors.

### Prior art and inspiration

Other projects solving the same problem, each worth reading before you write your own:

- **[Sithuk/ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu)** — a mature, far more featureful Ubuntu installer: native ZFS or LUKS encryption, single/mirror/raidz topologies, integrated sanoid snapshot management with automatic pruning, an optional encrypted data pool on a second drive, and remote unlocking over SSH at boot so you can roll back a headless machine without physical access. If you're on Ubuntu rather than Debian, use this instead of these scripts.

- **[okhsunrog/archinstall_zfs](https://github.com/okhsunrog/archinstall_zfs)** — a ZFS-first Arch Linux installer with both a graphical (Slint/KMS) and terminal (ratatui) UI. Notably, it validates kernel/ZFS compatibility against OpenZFS release data before installing, and falls back from prebuilt modules to DKMS automatically — a class of problem these Debian scripts sidestep only because Debian's kernel is frozen within a release.

- **[fnichol/cachyos-zfs-installer](https://github.com/fnichol/cachyos-zfs-installer)** — configures CachyOS with an optionally encrypted ZFS root, ZFSBootMenu, and automatic boot environments by reconfiguring Calamares to use ZFS + ZFSBootMenu instead of ext4 + systemd-boot. Its pacman hooks are the interesting part: a pre-hook snapshots the current boot environment whenever kernel or ZFS packages are about to update, and a post-hook prunes old environments by retention policy and regenerates the ZBM images. That is a genuinely better answer to "snapshot before upgrade" than doing it by hand.

---

## License

MIT. The upstream guides, ZFSBootMenu, and OpenZFS carry their own licenses — ZFS is CDDL.

## Contributing

Issues and pull requests welcome. Please test changes in a VM and say which guide section your change relates to, so the `[GUIDE]` / `[DEVIATION]` annotations in the scripts stay accurate.
