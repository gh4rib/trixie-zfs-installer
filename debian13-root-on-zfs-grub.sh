#!/usr/bin/env bash
#
#==============================================================================
# debian13-root-on-zfs-grub.sh     Debian 13 (Trixie) root on encrypted ZFS
#                                  GRUB version, ext4 /boot
#==============================================================================
#
# Automation of the OpenZFS HOWTO:
#   https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/
#          Debian%20Trixie%20Root%20on%20ZFS.html
#   (ZFS native encryption option)
#
# Guide steps are tagged [GUIDE] and follow the HOWTO's own numbering.
# Departures are tagged [DEVIATION] and justified inline.
#
#------------------------------------------------------------------------------
# THE ONE BIG DEVIATION: ext4 /boot instead of bpool
#------------------------------------------------------------------------------
# The HOWTO creates a second ZFS pool ("bpool") for /boot with
# -o compatibility=grub2, because GRUB understands only a subset of zpool
# features. This script uses a plain ext4 partition for /boot instead, which
# removes that entire mechanism:
#
#   * no bpool, no compatibility=grub2, no feature-flag juggling
#   * no /etc/systemd/system/zfs-import-bpool.service  (HOWTO step 4.13)
#   * no bpool entry in /etc/zfs/zfs-list.cache        (HOWTO step 5.7)
#   * `zpool upgrade rpool` stays safe forever, since GRUB never reads rpool
#   * GRUB only ever reads ext4; the kernel + initramfs handle ZFS and the
#     encryption passphrase prompt
#
# Everything else follows the HOWTO.
#
#------------------------------------------------------------------------------
# Disk layout on $DISK (a /dev/disk/by-id/... path; GPT, fully wiped)
#------------------------------------------------------------------------------
#   -part1   24K .. +1000K       EF02   BIOS boot (tiny; enables legacy boot)
#   -part2   1M  .. +600M        EF00   EFI System Partition -> /boot/efi
#   -part3        .. +2048M      8300   /boot  ext4
#   -part4        .. +1024M      8200   encrypted swap (random key per boot)
#   -part5        .. rest        BF00   rpool
#
#------------------------------------------------------------------------------
# Dataset hierarchy
#------------------------------------------------------------------------------
#   rpool/ROOT                    mountpoint=none  canmount=off
#   |-- default                   mountpoint=/     canmount=noauto  <- active
#   `-- baseline                  mountpoint=/     canmount=noauto  <- factory
#   rpool/data                    mountpoint=none  canmount=off
#   |-- home                      /home
#   |   |-- root                  /root
#   |   `-- <username>            /home/<username>
#   |-- opt                       /opt
#   |-- srv                       /srv
#   `-- var                       (container, canmount=off)
#       |-- lib                   (container, canmount=off)
#       |   |-- containers        /var/lib/containers    Podman
#       |   |-- docker            /var/lib/docker        Docker
#       |   |-- libvirt           /var/lib/libvirt       VMs
#       |   `-- lxc               /var/lib/lxc           LXC
#       |-- log                   /var/log
#       |-- spool                 /var/spool
#       `-- tmp                   /var/tmp
#
#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
# Boot a Debian 13 Live ISO (GNOME image recommended, per the HOWTO), then:
#
#   sudo -i
#   DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
#   TARGET_HOSTNAME=workstation ADMIN_USER=alireza \
#   TIMEZONE=Europe/Berlin DESKTOP=kde \
#   ./debian13-root-on-zfs-grub.sh
#
# Run with DISK unset to list candidate disks.
#
# THIS DESTROYS ALL DATA ON $DISK.
#==============================================================================

set -euo pipefail

#==============================================================================
# Keyboard detection from the live environment
#==============================================================================

_LIVE_XKBLAYOUT=""
_LIVE_XKBVARIANT=""
if [[ -r /etc/default/keyboard ]]; then
	_LIVE_XKBLAYOUT="$(. /etc/default/keyboard 2>/dev/null; printf '%s' "${XKBLAYOUT:-}")"
	_LIVE_XKBVARIANT="$(. /etc/default/keyboard 2>/dev/null; printf '%s' "${XKBVARIANT:-}")"
fi

XKB_LST="/usr/share/X11/xkb/rules/base.lst"

list_variants() {
	local layout="$1"
	if [[ ! -r "$XKB_LST" ]]; then
		echo "  (xkb-data not installed; cannot list)" >&2
		return 0
	fi
	printf '  %-18s %s\n' "(none)" "standard layout for '${layout}'" >&2
	awk -v l="${layout}:" '
		/^! variant/ { f = 1; next }
		/^!/         { f = 0 }
		f && NF > 1 && $2 == l {
			name = $1; $1 = ""; $2 = ""; sub(/^ +/, "")
			printf "  %-18s %s\n", name, $0
		}' "$XKB_LST" >&2
	return 0
}

if [[ -n "${LIST_KEYBOARD:-}" ]]; then
	_l="${LIST_KEYBOARD}"
	[[ "$_l" == "yes" ]] && _l="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
	echo "Keyboard variants for layout '${_l}':" >&2
	list_variants "$_l"
	exit 0
fi

#==============================================================================
# CONFIGURATION - override any of these as environment variables
#==============================================================================

#--- Target disk (REQUIRED) ---------------------------------------------------
# [GUIDE] "Always use the long /dev/disk/by-id/* aliases with ZFS. Using the
# /dev/sd* device nodes directly can cause sporadic import failures."
DISK="${DISK:-}"

#--- Firmware / boot mode -----------------------------------------------------
# uefi : install grub-efi-amd64 + shim-signed to the ESP  (default)
# bios : install grub-pc to the MBR
# A 1 MiB EF02 partition is created either way, so you can switch later.
BOOT_MODE="${BOOT_MODE:-uefi}"

#--- Partition sizes (MiB) ----------------------------------------------------
ESP_SIZE_MIB="${ESP_SIZE_MIB:-600}"     # [GUIDE] uses 512
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-2048}"  # [DEVIATION] ext4 /boot, guide: 1G bpool
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"  # 0 disables swap entirely

#--- Swap ---------------------------------------------------------------------
# [DEVIATION] The HOWTO's step 7 puts swap on a zvol, and warns:
#   "On systems with extremely high memory pressure, using a zvol for swap can
#    result in lockup, regardless of how much swap is still available."
# A dedicated partition avoids that failure mode entirely.
#
# Plain dm-crypt with a fresh random key every boot. Nothing on this partition
# survives a reboot, so hibernation is impossible -- which is why the guide's
# RESUME=none step is applied below regardless.
#
# (A per-boot random key cannot be LUKS: LUKS requires a persistent header
# with keyslots. crypttab's 'swap' option selects plain mode.)
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"     # 512 = AES-256 in XTS mode
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

#--- ZFS ----------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-rpool}"
BE_NAME="${BE_NAME:-default}"           # [GUIDE] uses rpool/ROOT/debian
BASELINE_NAME="${BASELINE_NAME:-baseline}"
# clone : baseline is a clone of default@baseline (cheap, shares blocks)
# send  : independent full copy (second copy of the OS)
# none  : no baseline boot environment
BASELINE_MODE="${BASELINE_MODE:-clone}"

ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
DNODESIZE="${DNODESIZE:-auto}"
# [GUIDE] "Setting normalization=formD eliminates some corner cases relating to
# UTF-8 filename normalization. It also implies utf8only=on, which means that
# only UTF-8 filenames are allowed." Set to empty to skip if you need to store
# non-UTF-8 filenames -- this cannot be changed after pool creation.
NORMALIZATION="${NORMALIZATION:-formD}"
DATASET_TUNING="${DATASET_TUNING:-yes}"

#--- Identity -----------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
# [GUIDE] step 6.7 group list
ADMIN_GROUPS="${ADMIN_GROUPS:-audio,cdrom,dip,floppy,netdev,plugdev,video}"

#--- Locale / time / keyboard -------------------------------------------------
# [GUIDE] "Even if you prefer a non-English system language, always ensure that
# en_US.UTF-8 is available." It is generated alongside your choice.
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
# Empty means "the standard layout for this country code" and is usually right.
# See options with:  LIST_KEYBOARD=yes ./debian13-root-on-zfs-grub.sh
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"

#--- Debian -------------------------------------------------------------------
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://deb.debian.org/debian-security}"
# [GUIDE] main contrib non-free-firmware
COMPONENTS="${COMPONENTS:-main contrib non-free-firmware}"
ENABLE_BACKPORTS="${ENABLE_BACKPORTS:-yes}"
INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
INSTALL_SSH="${INSTALL_SSH:-no}"        # [GUIDE] step 4.14, optional
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

#--- Desktop ------------------------------------------------------------------
# [DEVIATION] The HOWTO's step 8 runs `tasksel --new-install` interactively.
DESKTOP="${DESKTOP:-kde}"               # kde | gnome | none
DESKTOP_SIZE="${DESKTOP_SIZE:-minimal}" # minimal | full

#--- GRUB ---------------------------------------------------------------------
# [GUIDE] step 5.4, "Optional (but highly recommended): Make debugging GRUB
# easier" -- remove quiet from GRUB_CMDLINE_LINUX_DEFAULT and set
# GRUB_TERMINAL=console. Left ON here so boot messages are visible.
GRUB_VERBOSE="${GRUB_VERBOSE:-yes}"
GRUB_CMDLINE_DEFAULT="${GRUB_CMDLINE_DEFAULT:-loglevel=6}"
GRUB_TIMEOUT_SECS="${GRUB_TIMEOUT_SECS:-5}"
REMOVE_OS_PROBER="${REMOVE_OS_PROBER:-yes}"   # [GUIDE] step 4.11
# [GUIDE] step 8.3: /var/log is already a compressed dataset, so logrotate's
# own compression burns CPU for little gain and wastes space in snapshots.
DISABLE_LOG_COMPRESSION="${DISABLE_LOG_COMPRESSION:-yes}"

#--- Passwords (prompted if unset) --------------------------------------------
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ZFS_PASSPHRASE="${ZFS_PASSPHRASE:-}"

#--- Misc ---------------------------------------------------------------------
FORCE="${FORCE:-no}"
BLKDISCARD="${BLKDISCARD:-no}"          # [GUIDE] step 2.2, flash full discard

#==============================================================================
# Helpers
#==============================================================================

log()  { printf '\n\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

prompt_pass() {
	local __var="$1" label="$2" minlen="${3:-1}" p1 p2
	while :; do
		read -rsp "  ${label}: " p1; echo
		read -rsp "  Confirm ${label}: " p2; echo
		if   [[ -z "$p1" ]];        then warn "Empty. Try again."
		elif [[ "$p1" != "$p2" ]];  then warn "Passwords do not match. Try again."
		elif (( ${#p1} < minlen )); then warn "Need at least ${minlen} characters."
		else break
		fi
	done
	printf -v "$__var" '%s' "$p1"
	return 0
}

list_disks() {
	local l
	echo "Whole disks under /dev/disk/by-id/:" >&2
	for l in /dev/disk/by-id/*; do
		[[ "$l" == *-part* ]] && continue
		[[ -b "$l" ]] || continue
		[[ "$(lsblk -dno TYPE "$l" 2>/dev/null)" == "disk" ]] || continue
		printf '  %-72s %s\n' "$l" "$(lsblk -dno SIZE,MODEL "$l" 2>/dev/null)" >&2
	done
	return 0
}

#==============================================================================
# Preflight
#==============================================================================

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i)."

if [[ -z "$DISK" ]]; then
	list_disks
	die "DISK is not set. Pass a /dev/disk/by-id/... path."
fi
if [[ "$DISK" != /dev/disk/by-id/* ]]; then
	list_disks
	die "DISK must be a /dev/disk/by-id/... path (got: ${DISK})."
fi
if [[ "$DISK" == *-part* ]]; then
	die "DISK must point at a whole disk, not a partition."
fi
if [[ ! -b "$DISK" ]]; then
	list_disks
	die "${DISK} is not a block device."
fi

DISK_REAL="$(readlink -f "$DISK")"
[[ "$(lsblk -dno TYPE "$DISK_REAL")" == "disk" ]] || die "${DISK} does not resolve to a whole disk."

case "$BOOT_MODE"     in uefi|bios)      ;; *) die "BOOT_MODE must be uefi or bios." ;; esac
case "$DESKTOP"       in kde|gnome|none) ;; *) die "DESKTOP must be kde, gnome or none." ;; esac
case "$DESKTOP_SIZE"  in minimal|full)   ;; *) die "DESKTOP_SIZE must be minimal or full." ;; esac
case "$BASELINE_MODE" in clone|send|none);; *) die "BASELINE_MODE must be clone, send or none." ;; esac

if [[ "$BOOT_MODE" == "uefi" && ! -d /sys/firmware/efi ]]; then
	die "BOOT_MODE=uefi but this live system was not booted in UEFI mode."
fi

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	die "ADMIN_USER '${ADMIN_USER}' is not a valid Unix username."
fi
if [[ "$ADMIN_USER" == "root" ]]; then
	die "ADMIN_USER cannot be root."
fi

if [[ -r "$XKB_LST" ]]; then
	if ! awk '/^! layout/{f=1;next} /^!/{f=0} f&&NF{print $1}' "$XKB_LST" | grep -qx "$KEYMAP"; then
		die "KEYMAP='${KEYMAP}' is not a known XKB layout."
	fi
	if [[ -n "$KEYBOARD_VARIANT" ]]; then
		if ! awk -v l="${KEYMAP}:" '/^! variant/{f=1;next} /^!/{f=0} f&&NF>1&&$2==l{print $1}' \
			"$XKB_LST" | grep -qx "$KEYBOARD_VARIANT"; then
			warn "KEYBOARD_VARIANT='${KEYBOARD_VARIANT}' is not valid for layout '${KEYMAP}'."
			echo "Valid variants for '${KEYMAP}':" >&2
			list_variants "$KEYMAP"
			die "Pick one of the above, or leave KEYBOARD_VARIANT empty."
		fi
	fi
fi

[[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "TIMEZONE='${TIMEZONE}' is not a known zoneinfo name."
case "$LOCALE" in
	*.UTF-8|*.utf8) ;;
	*) die "LOCALE='${LOCALE}' must be a UTF-8 locale, e.g. en_US.UTF-8." ;;
esac

#--- Partition numbering ------------------------------------------------------
BIOS_PART=1
ESP_PART=2
BOOT_PART=3
SWAP_PART=4
ROOT_PART=5
if (( SWAP_SIZE_MIB <= 0 )); then
	ROOT_PART=4
fi

BIOS_DEVICE="${DISK}-part${BIOS_PART}"
ESP_DEVICE="${DISK}-part${ESP_PART}"
BOOT_DEVICE="${DISK}-part${BOOT_PART}"
SWAP_DEVICE="${DISK}-part${SWAP_PART}"
ROOT_DEVICE="${DISK}-part${ROOT_PART}"

# Primary network interface, for the HOWTO's ifupdown config (step 4.2)
PRIMARY_IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
[[ -n "$PRIMARY_IFACE" ]] || PRIMARY_IFACE="$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}' || true)"

log "Planned configuration"
cat <<EOF
  Disk             : ${DISK}
                     -> ${DISK_REAL}  ($(lsblk -dno SIZE,MODEL "$DISK_REAL"))
  Boot mode        : ${BOOT_MODE}
  BIOS boot part   : ${BIOS_DEVICE}   1 MiB   EF02
  ESP              : ${ESP_DEVICE}   ${ESP_SIZE_MIB} MiB  vfat   /boot/efi
  /boot            : ${BOOT_DEVICE}   ${BOOT_SIZE_MIB} MiB  ext4   [DEVIATION: guide uses bpool]
  Swap             : $( (( SWAP_SIZE_MIB > 0 )) && echo "${SWAP_DEVICE}   ${SWAP_SIZE_MIB} MiB  plain dm-crypt, random key" || echo "disabled" )
  Root pool vdev   : ${ROOT_DEVICE}
  Pool             : ${POOL_NAME}  ashift=${ASHIFT}  compression=${COMPRESSION}
                     dnodesize=${DNODESIZE}  normalization=${NORMALIZATION:-<unset>}
  Encryption       : ZFS native, keylocation=prompt, keyformat=passphrase
  Boot environment : ${POOL_NAME}/ROOT/${BE_NAME}
  Baseline BE      : $( [[ "$BASELINE_MODE" == none ]] && echo "disabled" || echo "${POOL_NAME}/ROOT/${BASELINE_NAME} (${BASELINE_MODE})" )
  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}  (${POOL_NAME}/data/home/${ADMIN_USER})
  Desktop          : ${DESKTOP} (${DESKTOP_SIZE})
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : layout=${KEYMAP} variant=$( [[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none, standard layout)" )
  Network iface    : ${PRIMARY_IFACE:-<none detected>}
  GRUB verbose     : ${GRUB_VERBOSE}   cmdline: ${GRUB_CMDLINE_DEFAULT}
EOF

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK_REAL" || true

if [[ "$FORCE" != "yes" ]]; then
	echo
	warn "EVERY PARTITION AND ALL DATA ON ${DISK_REAL} WILL BE DESTROYED."
	read -rp "Type ERASE to continue: " confirm
	[[ "$confirm" == "ERASE" ]] || die "Aborted."
fi

log "Collecting passwords"
[[ -n "$ROOT_PASSWORD" ]]  || prompt_pass ROOT_PASSWORD  "root password" 1
[[ -n "$ADMIN_PASSWORD" ]] || prompt_pass ADMIN_PASSWORD "password for ${ADMIN_USER}" 1
if [[ -z "$ZFS_PASSPHRASE" ]]; then
	# [GUIDE] "Your passphrase will likely be the weakest link. Choose wisely."
	echo "  Typed at the initramfs prompt on every boot, before your keymap loads."
	echo "  Prefer unshifted ASCII you can find blind."
	prompt_pass ZFS_PASSPHRASE "ZFS pool passphrase" 8
fi

#==============================================================================
# [GUIDE] Step 1: Prepare The Install Environment
#==============================================================================

# [GUIDE] step 1.4: prevent the desktop from automounting old partitions
if command -v gsettings >/dev/null 2>&1; then
	gsettings set org.gnome.desktop.media-handling automount false 2>/dev/null || true
fi

log "Configuring APT in the live environment"
cat > /etc/apt/sources.list <<EOF
deb ${MIRROR} ${SUITE} ${COMPONENTS}
EOF
rm -f /etc/apt/sources.list.d/debian.sources
export DEBIAN_FRONTEND=noninteractive
apt update

# [GUIDE] step 1.6: "Install missing prerequisites in zfsutils-linux package
# (bug 1091428)". The HOWTO names linux-headers-generic, which is an Ubuntu
# metapackage name; on Debian the equivalent is linux-headers-amd64. Probe for
# whichever exists rather than assuming.
log "Installing ZFS in the live environment"
HDR_PKG=""
for c in linux-headers-generic linux-headers-amd64 "linux-headers-$(uname -r)"; do
	if apt-cache show "$c" >/dev/null 2>&1; then HDR_PKG="$c"; break; fi
done
if [[ -n "$HDR_PKG" ]]; then
	apt install -y "$HDR_PKG"
else
	warn "No kernel headers package found; zfsutils-linux may be incomplete."
fi

# [GUIDE] step 1.7
apt install -y debootstrap gdisk zfsutils-linux
modprobe zfs || die "zfs module failed to load in the live environment."

#==============================================================================
# [GUIDE] Step 2: Disk Formatting
#==============================================================================

# [GUIDE] step 2.2: clear the disk if re-using it
log "Clearing ${DISK}"
swapoff --all || true
if [[ -e /proc/mdstat ]] && grep -q '^md' /proc/mdstat 2>/dev/null; then
	warn "MD arrays are active. Stop them (mdadm --stop) before continuing."
fi
wipefs -a "$DISK" || true
if [[ "$BLKDISCARD" == "yes" ]]; then
	log "Running full-disk discard (TRIM/UNMAP)"
	blkdiscard -f "$DISK" || warn "blkdiscard failed; continuing."
fi
sgdisk --zap-all "$DISK"
partprobe "$DISK_REAL" || true
udevadm settle

# [GUIDE] step 2.3: partition the disk
log "Creating partitions"
# Legacy (BIOS) boot partition. Tiny, and it keeps the BIOS path open later.
sgdisk -a1 -n"${BIOS_PART}:24K:+1000K" -t"${BIOS_PART}:EF02" "$DISK"
# UEFI ESP: "for use now or in the future"
sgdisk     -n"${ESP_PART}:1M:+${ESP_SIZE_MIB}M"  -t"${ESP_PART}:EF00"  -c"${ESP_PART}:EFI" "$DISK"
# [DEVIATION] ext4 /boot in place of the guide's BF01 bpool partition
sgdisk     -n"${BOOT_PART}:0:+${BOOT_SIZE_MIB}M" -t"${BOOT_PART}:8300" -c"${BOOT_PART}:boot" "$DISK"
if (( SWAP_SIZE_MIB > 0 )); then
	sgdisk -n"${SWAP_PART}:0:+${SWAP_SIZE_MIB}M" -t"${SWAP_PART}:8200" -c"${SWAP_PART}:swap" "$DISK"
fi
# [GUIDE] "Unencrypted or ZFS native encryption: -t4:BF00"
sgdisk     -n"${ROOT_PART}:0:0"                  -t"${ROOT_PART}:BF00" -c"${ROOT_PART}:${POOL_NAME}" "$DISK"

partprobe "$DISK_REAL" || true
udevadm settle
sleep 2
sgdisk -p "$DISK"

for p in "$ESP_DEVICE" "$BOOT_DEVICE" "$ROOT_DEVICE"; do
	[[ -b "$p" ]] || die "Expected partition link $p does not exist after partitioning."
done
if (( SWAP_SIZE_MIB > 0 )) && [[ ! -b "$SWAP_DEVICE" ]]; then
	die "Expected partition link $SWAP_DEVICE does not exist."
fi

#--- [DEVIATION] ext4 /boot ---------------------------------------------------
log "Creating ext4 filesystem on ${BOOT_DEVICE}"
mkfs.ext4 -q -L boot "$BOOT_DEVICE"

#--- [GUIDE] step 2.5: Create the root pool (ZFS native encryption) -----------
# The HOWTO uses -O keylocation=prompt, which makes zpool create ask
# interactively. A script cannot answer that, so the pool is created against a
# temporary key file in the live system's tmpfs and then switched to prompt --
# ending in exactly the state the HOWTO describes.
TMPKEY="$(mktemp /dev/shm/zfskey.XXXXXX)"
chmod 600 "$TMPKEY"
printf '%s' "$ZFS_PASSPHRASE" > "$TMPKEY"

log "Creating encrypted zpool ${POOL_NAME} on ${ROOT_DEVICE}"
zpool_opts=(
	-o "ashift=${ASHIFT}"
	-o autotrim=on
	# [DEVIATION] With no bpool, this is what puts rpool in the cache file
	# that the guide copies to the new system in step 3.6.
	-o cachefile=/etc/zfs/zpool.cache
	-O encryption=on
	-O "keylocation=file://${TMPKEY}"
	-O keyformat=passphrase
	-O acltype=posixacl -O xattr=sa -O "dnodesize=${DNODESIZE}"
	-O "compression=${COMPRESSION}"
	-O relatime=on
	-O canmount=off -O mountpoint=/ -R /mnt
)
if [[ -n "$NORMALIZATION" ]]; then
	zpool_opts+=(-O "normalization=${NORMALIZATION}")
fi
zpool create "${zpool_opts[@]}" "$POOL_NAME" "$ROOT_DEVICE"

log "Switching keylocation to prompt (the guide's end state)"
zfs set keylocation=prompt "$POOL_NAME"
shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"

#==============================================================================
# [GUIDE] Step 3: System Installation
#==============================================================================

# [GUIDE] step 3.1 and 3.2, with the requested hierarchy.
# canmount=noauto is essential on every dataset with mountpoint=/ -- otherwise
# the system tries to mount two filesystems at / and fails to boot.
log "Creating boot environment datasets"
zfs create -o canmount=off -o mountpoint=none    "${POOL_NAME}/ROOT"
zfs create -o canmount=noauto -o mountpoint=/    "${POOL_NAME}/ROOT/${BE_NAME}"
zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"

# [GUIDE] step 3.3, adapted to the requested layout
log "Creating data datasets"
zfs create -o canmount=off -o mountpoint=none    "${POOL_NAME}/data"

zfs create -o mountpoint=/home                   "${POOL_NAME}/data/home"
zfs create -o mountpoint=/root                   "${POOL_NAME}/data/home/root"
zfs create -o mountpoint="/home/${ADMIN_USER}"   "${POOL_NAME}/data/home/${ADMIN_USER}"

zfs create -o mountpoint=/opt                    "${POOL_NAME}/data/opt"
zfs create -o mountpoint=/srv                    "${POOL_NAME}/data/srv"

zfs create -o canmount=off -o mountpoint=none    "${POOL_NAME}/data/var"
zfs create -o canmount=off -o mountpoint=none    "${POOL_NAME}/data/var/lib"
zfs create -o mountpoint=/var/lib/containers     "${POOL_NAME}/data/var/lib/containers"
# [GUIDE] "If this system will use Docker (which manages its own datasets &
# snapshots): zfs create -o com.sun:auto-snapshot=false rpool/var/lib/docker"
zfs create -o mountpoint=/var/lib/docker -o com.sun:auto-snapshot=false \
                                                 "${POOL_NAME}/data/var/lib/docker"
zfs create -o mountpoint=/var/lib/libvirt        "${POOL_NAME}/data/var/lib/libvirt"
zfs create -o mountpoint=/var/lib/lxc            "${POOL_NAME}/data/var/lib/lxc"
zfs create -o mountpoint=/var/log                "${POOL_NAME}/data/var/log"
zfs create -o mountpoint=/var/spool              "${POOL_NAME}/data/var/spool"
zfs create -o mountpoint=/var/tmp                "${POOL_NAME}/data/var/tmp"

zfs mount -a

if [[ "$DATASET_TUNING" == "yes" ]]; then
	log "Applying per-dataset tuning"
	zfs set atime=off                       "${POOL_NAME}/data/var"
	zfs set setuid=off devices=off          "${POOL_NAME}/data/var/tmp"
	zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
	zfs set recordsize=64K                  "${POOL_NAME}/data/var/lib/libvirt"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containers"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/docker"
	# Container and VM stores manage their own snapshots or hold huge images.
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/containers"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/lxc"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/libvirt"
fi

# [GUIDE] step 3.3: chmod 700 /mnt/root
chmod 700 /mnt/root

# [DEVIATION] Mount the ext4 /boot where the guide would mount bpool/BOOT/debian
log "Mounting ext4 /boot at /mnt/boot"
mkdir -p /mnt/boot
mount "$BOOT_DEVICE" /mnt/boot

# [GUIDE] step 3.4: Mount a tmpfs at /run
mkdir -p /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock

echo
zfs list -o name,used,mountpoint,canmount -r "$POOL_NAME"
mountpoint -q /mnt || die "${POOL_NAME}/ROOT/${BE_NAME} is not mounted at /mnt."
for d in /mnt/home /mnt/root /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool /mnt/var/tmp /mnt/boot; do
	mountpoint -q "$d" || die "Expected mount missing: $d"
done

# [GUIDE] step 3.5: Install the minimal system
log "Running debootstrap (${SUITE})"
debootstrap "$SUITE" /mnt "$MIRROR"

# [GUIDE] step 3.6: Copy in zpool.cache
log "Copying zpool.cache into the new install"
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/ || warn "No /etc/zfs/zpool.cache to copy."

# Restore conventional modes on the dataset-backed directories
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
chmod 0755 /mnt/home /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool

#==============================================================================
# [GUIDE] Step 4: System Configuration
#==============================================================================

# [GUIDE] step 4.1: Configure the hostname
log "Configuring hostname and network"
echo "$TARGET_HOSTNAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${TARGET_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

# [GUIDE] step 4.2: Configure the network interface.
# Only for headless installs -- with a desktop, NetworkManager takes over and
# a conflicting ifupdown stanza causes trouble.
if [[ "$DESKTOP" == "none" && -n "$PRIMARY_IFACE" ]]; then
	mkdir -p /mnt/etc/network/interfaces.d
	cat > "/mnt/etc/network/interfaces.d/${PRIMARY_IFACE}" <<EOF
auto ${PRIMARY_IFACE}
iface ${PRIMARY_IFACE} inet dhcp
EOF
fi

cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || true

# [GUIDE] step 4.4: Bind the virtual filesystems and chroot.
# "This is using --rbind, not --bind."
log "Preparing chroot mounts"
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

#==============================================================================
# Write configuration + chroot script
#==============================================================================

log "Writing chroot payload"

{
	printf 'POOL_NAME=%q\n'          "$POOL_NAME"
	printf 'BE_NAME=%q\n'            "$BE_NAME"
	printf 'BASELINE_NAME=%q\n'      "$BASELINE_NAME"
	printf 'BASELINE_MODE=%q\n'      "$BASELINE_MODE"
	printf 'TARGET_HOSTNAME=%q\n'    "$TARGET_HOSTNAME"
	printf 'ADMIN_USER=%q\n'         "$ADMIN_USER"
	printf 'ADMIN_FULLNAME=%q\n'     "$ADMIN_FULLNAME"
	printf 'ADMIN_GROUPS=%q\n'       "$ADMIN_GROUPS"
	printf 'ROOT_PASSWORD=%q\n'      "$ROOT_PASSWORD"
	printf 'ADMIN_PASSWORD=%q\n'     "$ADMIN_PASSWORD"
	printf 'TIMEZONE=%q\n'           "$TIMEZONE"
	printf 'LOCALE=%q\n'             "$LOCALE"
	printf 'KEYMAP=%q\n'             "$KEYMAP"
	printf 'KEYBOARD_VARIANT=%q\n'   "$KEYBOARD_VARIANT"
	printf 'SUITE=%q\n'              "$SUITE"
	printf 'MIRROR=%q\n'             "$MIRROR"
	printf 'SECURITY_MIRROR=%q\n'    "$SECURITY_MIRROR"
	printf 'COMPONENTS=%q\n'         "$COMPONENTS"
	printf 'ENABLE_BACKPORTS=%q\n'   "$ENABLE_BACKPORTS"
	printf 'INSTALL_FIRMWARE=%q\n'   "$INSTALL_FIRMWARE"
	printf 'INSTALL_SSH=%q\n'        "$INSTALL_SSH"
	printf 'EXTRA_PACKAGES=%q\n'     "$EXTRA_PACKAGES"
	printf 'DESKTOP=%q\n'            "$DESKTOP"
	printf 'DESKTOP_SIZE=%q\n'       "$DESKTOP_SIZE"
	printf 'BOOT_MODE=%q\n'          "$BOOT_MODE"
	printf 'DISK=%q\n'               "$DISK"
	printf 'ESP_DEVICE=%q\n'         "$ESP_DEVICE"
	printf 'BOOT_DEVICE=%q\n'        "$BOOT_DEVICE"
	printf 'SWAP_DEVICE=%q\n'        "$SWAP_DEVICE"
	printf 'SWAP_SIZE_MIB=%q\n'      "$SWAP_SIZE_MIB"
	printf 'SWAP_RANDOM_SOURCE=%q\n' "$SWAP_RANDOM_SOURCE"
	printf 'SWAP_CIPHER=%q\n'        "$SWAP_CIPHER"
	printf 'SWAP_KEYSIZE=%q\n'       "$SWAP_KEYSIZE"
	printf 'SWAP_MAPPER=%q\n'        "$SWAP_MAPPER"
	printf 'GRUB_VERBOSE=%q\n'       "$GRUB_VERBOSE"
	printf 'GRUB_CMDLINE_DEFAULT=%q\n' "$GRUB_CMDLINE_DEFAULT"
	printf 'GRUB_TIMEOUT_SECS=%q\n'  "$GRUB_TIMEOUT_SECS"
	printf 'REMOVE_OS_PROBER=%q\n'   "$REMOVE_OS_PROBER"
	printf 'DISABLE_LOG_COMPRESSION=%q\n' "$DISABLE_LOG_COMPRESSION"
} > /mnt/root/zfs-install.env
chmod 600 /mnt/root/zfs-install.env

cat > /mnt/root/zfs-chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/zfs-install.env

WARNFILE=/root/INSTALL-WARNINGS.txt

log()  { printf '\n\033[1;36m -->\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() {
	printf '\033[1;33m [!]\033[0m %s\n' "$*" >&2
	printf '%s\n' "$*" >> "$WARNFILE"
}

export DEBIAN_FRONTEND=noninteractive

#--- [GUIDE] step 4.3: Configure the package sources --------------------------
log "Configuring APT sources"
rm -f /etc/apt/sources.list.d/debian.sources
cat > /etc/apt/sources.list <<EOF
deb ${MIRROR} ${SUITE} ${COMPONENTS}
deb-src ${MIRROR} ${SUITE} ${COMPONENTS}

deb ${SECURITY_MIRROR} ${SUITE}-security ${COMPONENTS}
deb-src ${SECURITY_MIRROR} ${SUITE}-security ${COMPONENTS}

deb ${MIRROR} ${SUITE}-updates ${COMPONENTS}
deb-src ${MIRROR} ${SUITE}-updates ${COMPONENTS}
EOF

if [[ "$ENABLE_BACKPORTS" == "yes" ]]; then
	cat > "/etc/apt/sources.list.d/${SUITE}-backports.list" <<EOF
deb ${MIRROR} ${SUITE}-backports ${COMPONENTS}
deb-src ${MIRROR} ${SUITE}-backports ${COMPONENTS}
EOF
fi

#--- [DEVIATION] fstab for ext4 /boot -----------------------------------------
# The guide has no /boot fstab entry because bpool/BOOT/debian is a dataset.
log "Writing /etc/fstab entry for /boot"
BOOT_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE")"
echo "UUID=${BOOT_UUID}	/boot	ext4	defaults	0	2" >> /etc/fstab

#--- [GUIDE] step 4.5: Configure a basic system environment -------------------
log "Configuring locale, timezone and keyboard"
apt update
apt install -y console-setup locales tzdata keyboard-configuration

# [GUIDE] "always ensure that en_US.UTF-8 is available"
sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
grep -q "^${LOCALE} UTF-8"   /etc/locale.gen || echo "${LOCALE} UTF-8"   >> /etc/locale.gen
grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale "LANG=${LOCALE}"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

debconf-set-selections <<EOF
keyboard-configuration keyboard-configuration/xkb-keymap select ${KEYMAP}
keyboard-configuration keyboard-configuration/variant select ${KEYBOARD_VARIANT}
console-setup console-setup/charmap47 select UTF-8
EOF
sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"${KEYMAP}\"/"             /etc/default/keyboard 2>/dev/null || true
sed -i "s/^XKBVARIANT=.*/XKBVARIANT=\"${KEYBOARD_VARIANT}\"/" /etc/default/keyboard 2>/dev/null || true

# [GUIDE] dpkg-reconfigure locales tzdata keyboard-configuration console-setup
dpkg-reconfigure -f noninteractive tzdata
dpkg-reconfigure -f noninteractive keyboard-configuration console-setup

#--- [GUIDE] step 4.6: Install driver firmware and WiFi support ---------------
if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	log "Installing CPU microcode"
	# [DEVIATION] The guide omits microcode. It carries security fixes applied
	# by the kernel at early boot; a real install should have it.
	CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo || true)"
	case "$CPU_VENDOR" in
		GenuineIntel) apt install -y intel-microcode ;;
		AuthenticAMD) apt install -y amd64-microcode ;;
		*) warn "Unrecognised CPU vendor '${CPU_VENDOR}'; installing both."
		   apt install -y intel-microcode amd64-microcode || true ;;
	esac

	# [GUIDE] "apt install --yes firmware-linux iw wpasupplicant"
	# firmware-linux covers graphics/misc only. Wireless and sound firmware are
	# separate packages nothing depends on, so an Intel wifi laptop comes up
	# with no network unless firmware-iwlwifi is named explicitly. Package
	# names shift between releases, so each is probed against the archive.
	log "Installing device firmware"
	FW_CANDIDATES=(
		firmware-linux firmware-linux-free firmware-linux-nonfree
		firmware-misc-nonfree
		firmware-iwlwifi firmware-realtek firmware-atheros
		firmware-brcm80211 firmware-libertas firmware-ti-connectivity
		firmware-zd1211 firmware-mediatek firmware-marvell-prestera
		firmware-sof-signed firmware-intel-sound
		firmware-amd-graphics firmware-intel-graphics firmware-nvidia-graphics
		firmware-bnx2 firmware-bnx2x firmware-qlogic firmware-cavium
	)
	FW_AVAILABLE=()
	for _p in "${FW_CANDIDATES[@]}"; do
		if apt-cache show "$_p" >/dev/null 2>&1; then
			FW_AVAILABLE+=("$_p")
		fi
	done
	if (( ${#FW_AVAILABLE[@]} > 0 )); then
		echo "  Installing: ${FW_AVAILABLE[*]}"
		apt install -y "${FW_AVAILABLE[@]}" || \
			warn "Some firmware packages failed; is non-free-firmware in COMPONENTS?"
	fi
	apt install -y iw wpasupplicant wireless-regdb rfkill || true
fi

#--- [GUIDE] step 4.7: Install ZFS in the chroot environment ------------------
# The HOWTO names linux-headers-generic / linux-image-generic, which are Ubuntu
# metapackage names carried over; Debian uses the -amd64 variants. Probe.
log "Installing kernel and ZFS"
KHDR=""; KIMG=""
for c in linux-headers-generic linux-headers-amd64; do
	if apt-cache show "$c" >/dev/null 2>&1; then KHDR="$c"; break; fi
done
for c in linux-image-generic linux-image-amd64; do
	if apt-cache show "$c" >/dev/null 2>&1; then KIMG="$c"; break; fi
done
[[ -n "$KHDR" && -n "$KIMG" ]] || { echo "No kernel metapackage found" >&2; exit 1; }
echo "  Using: ${KHDR} ${KIMG}"
apt install -y dpkg-dev "$KHDR" "$KIMG"

# [GUIDE] "Ignore any error messages saying ERROR: Couldn't resolve device and
# WARNING: Couldn't determine root device. cryptsetup does not support ZFS."
apt install -y zfs-initramfs
# zed is required for zfs-mount-generator in step 5.7 below.
apt install -y zfs-zed

#--- [GUIDE] step 4.9: Install an NTP service ---------------------------------
apt install -y systemd-timesyncd
systemctl enable systemd-timesyncd

#--- [GUIDE] step 4.10: Install GRUB ------------------------------------------
log "Installing GRUB (${BOOT_MODE})"
if [[ "$BOOT_MODE" == "uefi" ]]; then
	apt install -y dosfstools
	# [GUIDE] "-s 1 for mkdosfs is only necessary for drives which present
	# 4 KiB logical sectors... It also works fine on drives which present
	# 512 B sectors."
	mkdosfs -F 32 -s 1 -n EFI "$ESP_DEVICE"
	mkdir -p /boot/efi
	ESP_UUID="$(blkid -s UUID -o value "$ESP_DEVICE")"
	echo "/dev/disk/by-uuid/${ESP_UUID}	/boot/efi	vfat	defaults	0	0" >> /etc/fstab
	mount /boot/efi
	apt install -y grub-efi-amd64 shim-signed
else
	apt install -y grub-pc
fi

# [GUIDE] step 4.11: Optional: Remove os-prober
# "This avoids error messages from update-grub. os-prober is only necessary in
# dual-boot configurations."
if [[ "$REMOVE_OS_PROBER" == "yes" ]]; then
	apt purge -y os-prober || true
fi

#--- [GUIDE] step 4.12: Set a root password -----------------------------------
echo "root:${ROOT_PASSWORD}" | chpasswd

# [GUIDE] step 4.13 (Enable importing bpool) is INTENTIONALLY ABSENT.
# There is no bpool: /boot is ext4, mounted from /etc/fstab.

#--- [GUIDE] step 4.14: Optional: Install SSH ---------------------------------
if [[ "$INSTALL_SSH" == "yes" ]]; then
	apt install -y openssh-server
	# Root SSH login is left at Debian's default (prohibit-password). The guide
	# enables it temporarily then tells you to revert it in step 9.4; skipping
	# both is simpler and safer.
fi

#--- [DEVIATION] Encrypted swap partition -------------------------------------
if (( SWAP_SIZE_MIB > 0 )); then
	log "Configuring encrypted swap"
	apt install -y cryptsetup

	SWAP_PARTUUID="$(blkid -s PARTUUID -o value "$SWAP_DEVICE")"
	# Plain dm-crypt: crypttab's 'swap' option pulls a fresh key from the
	# source device and runs mkswap on every boot.
	cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	/dev/disk/by-partuuid/${SWAP_PARTUUID}	${SWAP_RANDOM_SOURCE}	swap,cipher=${SWAP_CIPHER},size=${SWAP_KEYSIZE},discard
EOF
	echo "/dev/mapper/${SWAP_MAPPER}	none	swap	discard	0	0" >> /etc/fstab
fi

# [GUIDE] step 7.2: "The RESUME=none is necessary to disable resuming from
# hibernation... If it is not disabled, the boot process hangs for 30 seconds
# waiting for the swap to appear." Equally required for a random-key swap,
# whose contents never survive a reboot.
mkdir -p /etc/initramfs-tools/conf.d
echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume

#==============================================================================
# [GUIDE] Step 5: GRUB Installation
#==============================================================================

# [GUIDE] step 5.1: Verify that the boot filesystem is recognized.
# With ext4 /boot this reports ext2 (GRUB's name for the ext2/3/4 family)
# rather than zfs, which is expected and correct here.
log "Verifying GRUB can probe /boot"
grub-probe /boot || warn "grub-probe /boot failed."

# [GUIDE] step 5.2: Refresh the initrd files
log "Refreshing initramfs"
update-initramfs -c -k all

# [GUIDE] step 5.3: Workaround GRUB's missing zpool-features support
# [GUIDE] step 5.4: Make debugging GRUB easier
log "Configuring /etc/default/grub"
set_grub() {
	local key="$1" val="$2"
	if grep -q "^#\?${key}=" /etc/default/grub; then
		sed -i "s|^#\?${key}=.*|${key}=${val}|" /etc/default/grub
	else
		echo "${key}=${val}" >> /etc/default/grub
	fi
}
set_grub GRUB_CMDLINE_LINUX "\"root=ZFS=${POOL_NAME}/ROOT/${BE_NAME}\""
set_grub GRUB_TIMEOUT "${GRUB_TIMEOUT_SECS}"
if [[ "$GRUB_VERBOSE" == "yes" ]]; then
	# quiet removed; GRUB_TERMINAL=console uncommented, per the guide
	set_grub GRUB_CMDLINE_LINUX_DEFAULT "\"${GRUB_CMDLINE_DEFAULT}\""
	set_grub GRUB_TERMINAL console
else
	set_grub GRUB_CMDLINE_LINUX_DEFAULT "\"quiet ${GRUB_CMDLINE_DEFAULT}\""
fi
grep -E '^GRUB_(CMDLINE|TIMEOUT|TERMINAL)' /etc/default/grub

#--- [DEVIATION] GRUB menu entry for the baseline boot environment ------------
# update-grub only generates entries for the running root dataset. Because
# /boot is a shared ext4 partition, a second entry pointing at a different
# root=ZFS= is all that is needed. This generator script re-runs on every
# update-grub, so it tracks kernel updates automatically.
if [[ "$BASELINE_MODE" != "none" ]]; then
	log "Adding a GRUB entry for the baseline boot environment"
	cat > /etc/grub.d/11_baseline_be <<GRUBD_HDR
#!/bin/sh
set -e
BOOT_UUID="${BOOT_UUID}"
BE="${POOL_NAME}/ROOT/${BASELINE_NAME}"
CMDLINE="${GRUB_CMDLINE_DEFAULT}"
GRUBD_HDR
	cat >> /etc/grub.d/11_baseline_be <<'GRUBD_BODY'
# Emit an entry for the newest kernel present in /boot.
for k in $(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V -r); do
	v=${k#/boot/vmlinuz-}
	[ -f "/boot/initrd.img-$v" ] || continue
	cat <<MENU
menuentry 'Debian - baseline boot environment ($v)' {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root $BOOT_UUID
	linux /vmlinuz-$v root=ZFS=$BE ro $CMDLINE
	initrd /initrd.img-$v
}
MENU
	break
done
GRUBD_BODY
	chmod +x /etc/grub.d/11_baseline_be
fi

# [GUIDE] step 5.5: Update the boot configuration
log "Running update-grub"
update-grub

# [GUIDE] step 5.6: Install the boot loader
log "Installing the boot loader"
if [[ "$BOOT_MODE" == "uefi" ]]; then
	grub-install --target=x86_64-efi --efi-directory=/boot/efi \
		--bootloader-id=debian --recheck
	# Removable-media fallback, for firmware that ignores NVRAM boot entries.
	# With Secure Boot, BOOTX64.EFI must be the shim, which then chainloads
	# grubx64.efi from the same directory -- copying GRUB alone would break
	# the signature chain.
	if [[ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
		mkdir -p /boot/efi/EFI/BOOT
		if [[ -f /boot/efi/EFI/debian/shimx64.efi ]]; then
			cp /boot/efi/EFI/debian/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
			cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
			if [[ -f /boot/efi/EFI/debian/mmx64.efi ]]; then
				cp /boot/efi/EFI/debian/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi
			fi
		elif [[ -f /boot/efi/EFI/debian/grubx64.efi ]]; then
			cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
		else
			warn "No GRUB EFI binary found to install as a removable fallback."
		fi
	fi
else
	# "Note that you are installing GRUB to the whole disk, not a partition."
	grub-install "$DISK"
fi

#--- [GUIDE] step 5.7: Fix filesystem mount ordering --------------------------
# "We need to activate zfs-mount-generator. This makes systemd aware of the
# separate mountpoints, which is important for things like /var/log and
# /var/tmp." This matters more here than in the guide, because this layout has
# a dozen separate datasets.
log "Activating zfs-mount-generator"
mkdir -p /etc/zfs/zfs-list.cache
touch "/etc/zfs/zfs-list.cache/${POOL_NAME}"

# The cache is written by a ZED hook; make sure it is enabled.
if [[ ! -e /etc/zfs/zed.d/history_event-zfs-list-cacher.sh ]]; then
	for cand in /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh \
	            /usr/libexec/zfs/zed.d/history_event-zfs-list-cacher.sh; do
		if [[ -e "$cand" ]]; then
			ln -sf "$cand" /etc/zfs/zed.d/
			break
		fi
	done
fi

zed -F &
ZED_PID=$!
sleep 2
# [GUIDE] "If either is empty, force a cache update and check again"
zfs set canmount=noauto "${POOL_NAME}/ROOT/${BE_NAME}"
for _i in $(seq 1 30); do
	[[ -s "/etc/zfs/zfs-list.cache/${POOL_NAME}" ]] && break
	sleep 1
done
kill "$ZED_PID" 2>/dev/null || true
wait "$ZED_PID" 2>/dev/null || true

if [[ -s "/etc/zfs/zfs-list.cache/${POOL_NAME}" ]]; then
	# [GUIDE] "Fix the paths to eliminate /mnt"
	sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
	echo "  zfs-list.cache entries: $(wc -l < "/etc/zfs/zfs-list.cache/${POOL_NAME}")"
else
	warn "zfs-list.cache/${POOL_NAME} is empty; zfs-mount-generator is inactive."
	warn "Datasets will still mount via zfs-mount.service, but ordering is weaker."
	warn "Fix after first boot: rm the file, touch it again, systemctl restart zfs-zed,"
	warn "then run: zfs set canmount=noauto ${POOL_NAME}/ROOT/${BE_NAME}"
fi

#--- [GUIDE] step 6.7: Create a user account ----------------------------------
# The guide does this after first boot; doing it here means the machine is
# usable immediately. Note the guide's own skel handling: it runs
# `cp -a /etc/skel/. /home/$username` explicitly, because the home directory
# already exists as a dataset and adduser/useradd will NOT populate a
# directory that already exists.
log "Creating user ${ADMIN_USER}"
apt install -y sudo
useradd -M -d "/home/${ADMIN_USER}" -s /bin/bash -c "$ADMIN_FULLNAME" "$ADMIN_USER"
cp -a /etc/skel/. "/home/${ADMIN_USER}/"
echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}"
chmod 0750 "/home/${ADMIN_USER}"
usermod -a -G "${ADMIN_GROUPS},sudo" "$ADMIN_USER"

if [[ ! -f "/home/${ADMIN_USER}/.bashrc" ]]; then
	warn "/home/${ADMIN_USER}/.bashrc missing -- skel copy did not work."
fi

#==============================================================================
# [GUIDE] Step 8: Full Software Installation
#==============================================================================

log "Installing base userland"
apt install -y \
	network-manager openssh-client ca-certificates \
	bash-completion less nano vim-tiny curl wget rsync \
	man-db pciutils usbutils htop zstd git gdisk cryptsetup
systemctl enable NetworkManager

if [[ -n "$EXTRA_PACKAGES" ]]; then
	# Deliberately unquoted: EXTRA_PACKAGES is a space-separated list.
	apt install -y $EXTRA_PACKAGES
fi

# [DEVIATION] The guide runs `tasksel --new-install` interactively here.
case "$DESKTOP" in
	kde)
		log "Installing KDE Plasma (${DESKTOP_SIZE})"
		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			apt install -y kde-standard sddm
		else
			apt install -y kde-plasma-desktop sddm
		fi
		apt install -y xdg-user-dirs xdg-utils fonts-noto pipewire-audio
		systemctl enable sddm
		systemctl set-default graphical.target
		;;
	gnome)
		log "Installing GNOME (${DESKTOP_SIZE})"
		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			apt install -y gnome gdm3
		else
			apt install -y gnome-core gdm3
		fi
		apt install -y xdg-user-dirs xdg-utils fonts-noto pipewire-audio
		systemctl enable gdm3
		systemctl set-default graphical.target
		;;
	none)
		log "Skipping desktop install"
		systemctl set-default multi-user.target
		;;
esac

# [GUIDE] step 8.3: Optional: Disable log compression
# "As /var/log is already compressed by ZFS, logrotate's compression is going
# to burn CPU and disk I/O for (in most cases) very little gain."
if [[ "$DISABLE_LOG_COMPRESSION" == "yes" ]]; then
	log "Disabling logrotate compression"
	for file in /etc/logrotate.d/*; do
		[[ -f "$file" ]] || continue
		if grep -Eq "(^|[^#y])compress" "$file"; then
			sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
		fi
	done
fi

#--- Regenerate GRUB now that everything is installed -------------------------
update-grub

#--- Cleanup ------------------------------------------------------------------
log "Cleaning up"
apt --purge autoremove -y
apt clean
CHROOT_EOF

chmod 700 /mnt/root/zfs-chroot.sh

#==============================================================================
# Run the chroot stage
#==============================================================================

# [GUIDE] step 4.4: chroot /mnt /usr/bin/env DISK=$DISK bash --login
log "Entering chroot"
chroot /mnt /usr/bin/env "DISK=$DISK" bash /root/zfs-chroot.sh

#==============================================================================
# Baseline boot environment + [GUIDE] Step 6: First Boot
#==============================================================================

log "Removing installer artefacts"
rm -f /mnt/root/zfs-install.env /mnt/root/zfs-chroot.sh

# [GUIDE] step 6.1: Optional: Snapshot the initial installation
log "Snapshotting the initial installation"
zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@install"

if [[ "$BASELINE_MODE" != "none" ]]; then
	log "Creating factory baseline boot environment (${BASELINE_MODE})"
	zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}"
	if [[ "$BASELINE_MODE" == "clone" ]]; then
		# canmount=noauto set explicitly: canmount is not inheritable, and two
		# filesystems trying to mount at / prevents the system from booting.
		zfs clone -o canmount=noauto -o mountpoint=/ \
			"${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" \
			"${POOL_NAME}/ROOT/${BASELINE_NAME}"
	else
		zfs send "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" | \
			zfs recv -u "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set canmount=noauto "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set mountpoint=/    "${POOL_NAME}/ROOT/${BASELINE_NAME}"
	fi
fi

log "Final dataset layout"
zfs list -o name,used,refer,mountpoint,canmount -r "$POOL_NAME"

if [[ -s /mnt/root/INSTALL-WARNINGS.txt ]]; then
	echo
	warn "Warnings were recorded during installation:"
	sed 's/^/    /' /mnt/root/INSTALL-WARNINGS.txt >&2
	warn "Kept at /root/INSTALL-WARNINGS.txt on the new system."
fi

# [GUIDE] step 6.3: unmount all filesystems, then export
log "Unmounting everything"
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -r -i{} umount -lf {} || true
sleep 2
if ! zpool export -a; then
	# [GUIDE] step 6.4: "If export failed due to busy error, try to kill
	# everything that might be using it"
	warn "Export failed; killing processes holding the pool"
	grep '[p]ool' /proc/*/mounts 2>/dev/null | cut -d/ -f3 | uniq | xargs -r kill || true
	sleep 2
	zpool export -a || die "Could not export ${POOL_NAME}. Do not reboot until resolved."
fi

log "Done"
cat <<EOF

Installation complete. Remove the live medium and reboot.

BOOT CHAIN
  firmware -> GRUB (reads ext4 /boot) -> kernel + initramfs -> unlock ${POOL_NAME}

  The initramfs prompts for your ZFS passphrase. GRUB itself never touches the
  encrypted pool, which is why /boot is a plain ext4 partition here.

  GRUB menu:
    Debian                                  -> ${POOL_NAME}/ROOT/${BE_NAME}
$( [[ "$BASELINE_MODE" != none ]] && printf '%s\n' \
"    Debian - baseline boot environment      -> ${POOL_NAME}/ROOT/${BASELINE_NAME}" )

  Log in as '${ADMIN_USER}' (sudo enabled) or root.

WHAT THIS SCRIPT DOES NOT DO (versus the OpenZFS HOWTO)
  * No bpool. /boot is ext4, so there is no compatibility=grub2 pool, no
    zfs-import-bpool.service, and no bpool in zfs-list.cache.
  * Consequence: 'zpool upgrade ${POOL_NAME}' is always safe. GRUB never reads
    the root pool, so new feature flags cannot make the system unbootable.
  * Swap is a partition, not a zvol, avoiding the lockup bug the guide warns
    about under high memory pressure. RESUME=none is set either way.

BOOT VERBOSITY
  GRUB_VERBOSE=${GRUB_VERBOSE}. 'quiet' is $( [[ "$GRUB_VERBOSE" == yes ]] && echo "not set" || echo "set" ); GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_DEFAULT}".
  The guide suggests reverting this once the system has rebooted twice and you
  are confident it works:
    sudo nano /etc/default/grub     # add 'quiet', comment GRUB_TERMINAL
    sudo update-grub

NEW BOOT ENVIRONMENTS
  canmount is NOT inheritable. Every dataset with mountpoint=/ needs it set:
    sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade
    sudo zfs clone -o canmount=noauto -o mountpoint=/ \\
        ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade ${POOL_NAME}/ROOT/new
  To boot one, edit the GRUB entry at boot (press 'e') and change the
  root=ZFS= value, or copy /etc/grub.d/11_baseline_be as a template.

NEW USERS
  A per-user dataset makes the home directory exist, and useradd will not copy
  /etc/skel into a directory that already exists. The guide does this manually
  and so should you:
    sudo zfs create -o mountpoint=/home/NAME ${POOL_NAME}/data/home/NAME
    sudo useradd -M -d /home/NAME -s /bin/bash NAME
    sudo cp -a /etc/skel/. /home/NAME/
    sudo chown -R NAME:NAME /home/NAME && sudo chmod 0750 /home/NAME
    sudo usermod -a -G ${ADMIN_GROUPS},sudo NAME
    sudo passwd NAME

MOUNT ORDERING
  zfs-mount-generator is active via /etc/zfs/zfs-list.cache/${POOL_NAME}. If you
  add, remove or re-mountpoint datasets later, the cache updates automatically
  as long as zfs-zed is running. Verify with:
    systemctl status zfs-zed
    cat /etc/zfs/zfs-list.cache/${POOL_NAME}

CLEANUP (guide step 9, once you are happy)
  sudo zfs destroy ${POOL_NAME}/ROOT/${BE_NAME}@install
  sudo usermod -p '*' root          # disable the root password

EOF
