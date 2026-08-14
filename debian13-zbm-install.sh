#!/usr/bin/env bash
#
#==============================================================================
# debian13-zbm-install.sh          Debian 13 (Trixie) root on encrypted ZFS
#                                  ZFSBootMenu + rEFInd, UEFI only
#==============================================================================
#
# Automation of:
#   https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html
#   (encrypted variant, rEFInd boot-entry variant)
#
# Every guide step is reproduced in order and marked [GUIDE]. Deliberate
# departures are marked [DEVIATION] and justified inline. Nothing the guide
# flags as critical has been altered.
#
#------------------------------------------------------------------------------
# Disk layout on $DISK (a /dev/disk/by-id/... path; GPT, fully wiped)
#------------------------------------------------------------------------------
#   -part1   1 MiB .. +1024 MiB   ef00   EFI System Partition -> /boot/efi
#   -part2         .. +1024 MiB   8309   encrypted swap
#   -part3         .. -10 MiB     bf00   ZFS pool
#
#------------------------------------------------------------------------------
# Dataset hierarchy
#------------------------------------------------------------------------------
#   zroot/ROOT                    mountpoint=none  canmount=off
#   |-- default                   mountpoint=/     canmount=noauto  <- active
#   `-- baseline                  mountpoint=/     canmount=noauto  <- factory
#   zroot/data                    mountpoint=none  canmount=off
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
# Boot a Debian 13 Live ISO in UEFI mode, get a root shell (sudo -i), then:
#
#   DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
#   TARGET_HOSTNAME=workstation ADMIN_USER=alireza \
#   TIMEZONE=Europe/Berlin DESKTOP=kde \
#   ./debian13-zbm-install.sh
#
# Run with DISK unset to list candidate disks.
# Run with LIST_KEYBOARD=yes to list keyboard variants for your layout.
#
# THIS DESTROYS ALL DATA ON $DISK.
#==============================================================================

set -euo pipefail

#==============================================================================
# Keyboard detection from the live environment
#
# Only the keyboard is inherited from the live session: whatever layout you
# picked on the ISO boot menu is already in /etc/default/keyboard, and a wrong
# keymap makes the boot-time passphrase prompt painful. Locale and timezone are
# NOT guessed; set them with LOCALE and TIMEZONE.
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

#--- Target disk (REQUIRED, must be a /dev/disk/by-id/ path) ------------------
# by-id paths are stable across reboots and controller reordering, and give
# deterministic -partN children.
DISK="${DISK:-}"

#--- Desktop environment ------------------------------------------------------
DESKTOP="${DESKTOP:-kde}"                 # kde | gnome | none
DESKTOP_SIZE="${DESKTOP_SIZE:-minimal}"   # minimal | full

#--- Identity -----------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian-zbm}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
ADMIN_GROUPS="${ADMIN_GROUPS:-adm,cdrom,dip,plugdev,users,audio,video,netdev}"

#--- Locale / time / keyboard -------------------------------------------------
#   TIMEZONE : any zoneinfo name (timedatectl list-timezones)
#   LOCALE   : a UTF-8 locale. en_US.UTF-8 is always generated as well, per
#              the guide's note that some programs require it.
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"

KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"

# KEYBOARD_VARIANT is the XKB *variant* of KEYMAP. Empty is valid and common:
# it means "the standard layout for this country code". us + empty is US
# QWERTY. Variants are dvorak, colemak, nodeadkeys, intl and similar.
# Don't know? Leave it. To see the options:  LIST_KEYBOARD=yes ./thisscript
# Note the '-' not ':-': KEYBOARD_VARIANT= explicitly forces "no variant".
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"

#--- Partition sizes (MiB) ----------------------------------------------------
# [DEVIATION] Guide uses +512m for the ESP. 1024 MiB leaves room for several
# ZBM images, a rEFInd install and firmware updates.
ESP_SIZE_MIB="${ESP_SIZE_MIB:-1024}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"    # 0 disables swap entirely

#--- Swap encryption ----------------------------------------------------------
# [DEVIATION] The guide has no swap partition at all.
#
#   random : plain dm-crypt, fresh key from $SWAP_RANDOM_SOURCE every boot.
#            Nothing survives a reboot, so hibernation is impossible.
#            (A random per-boot key cannot be LUKS: LUKS needs a persistent
#            header with keyslots. This is plain mode, via crypttab's 'swap'.)
#   luks   : persistent LUKS2, unlocked from a keyfile on the encrypted root.
#   none   : plain unencrypted swap (not recommended)
#
# Swap is a partition, not a zvol: swap on a zvol can deadlock under memory
# pressure and is advised against by OpenZFS.
SWAP_MODE="${SWAP_MODE:-random}"
# /dev/urandom is cryptographically identical to /dev/random on modern kernels
# and never blocks.
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"       # 512 = AES-256 in XTS mode
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

#--- ZFS ----------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-zroot}"
# [DEVIATION] Guide uses $ID from /etc/os-release ("debian"). Named boot
# environments read better once you have more than one.
BE_NAME="${BE_NAME:-default}"
BASELINE_NAME="${BASELINE_NAME:-baseline}"
#   clone : baseline is a clone of default@baseline (cheap, shares blocks)
#   send  : baseline is an independent full copy (second copy of the OS)
#   none  : no baseline boot environment
BASELINE_MODE="${BASELINE_MODE:-clone}"

ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-aes-256-gcm}"

# [DEVIATION] Guide suggests -o compatibility=openzfs-2.3-linux as a
# conservative choice, and explicitly says it "can be omitted or otherwise
# adjusted to match your specific system needs". Left empty so the pool can
# later be upgraded to 2.4.x feature flags from trixie-backports. See the
# post-install notes for the ORDER that upgrade must follow.
POOL_COMPAT="${POOL_COMPAT:-}"

DATASET_TUNING="${DATASET_TUNING:-yes}"   # light per-dataset property tuning

#--- Debian -------------------------------------------------------------------
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://deb.debian.org/debian-security}"
COMPONENTS="${COMPONENTS:-main contrib non-free-firmware}"
# Adds the trixie-backports source without pinning; nothing installs from it
# unless requested with -t ${SUITE}-backports.
ENABLE_BACKPORTS="${ENABLE_BACKPORTS:-yes}"
INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

#--- ZFSBootMenu / rEFInd -----------------------------------------------------
ZBM_INSTALL="${ZBM_INSTALL:-prebuilt}"    # prebuilt | source

# There are TWO distinct kernel command lines here. Conflating them is a
# common mistake:
#
#   ZBM_CMDLINE     goes in refind_linux.conf and configures ZFSBootMenu's OWN
#                   kernel: what you see while ZBM imports the pool, prompts
#                   for the passphrase and lists boot environments.
#
#   KERNEL_CMDLINE  is stored in org.zfsbootmenu:commandline on ${POOL_NAME}/ROOT
#                   and is what ZBM hands to the Debian kernel it kexecs: what
#                   you see once Debian itself boots.
#
# [DEVIATION] Guide uses "quiet" / "quiet loglevel=0" for both. Both are
# verbose here by request. loglevel=N prints messages of priority below N:
#   3 = errors   4 = + warnings ('quiet' equivalent)
#   6 = + info   7 = + debug (ZBM's full internal tracing)
ZBM_CMDLINE="${ZBM_CMDLINE:-loglevel=6}"
KERNEL_CMDLINE="${KERNEL_CMDLINE:-loglevel=6 systemd.show_status=yes}"

# Seconds ZFSBootMenu waits on its countdown before booting bootfs.
# 0 boots immediately, -1 waits forever. A few seconds is what makes the
# 'baseline' environment reachable without needing another reboot.
ZBM_TIMEOUT="${ZBM_TIMEOUT:-10}"

# The guide's "See also" warns that some firmware silently drops EFI boot
# entries. This copies ZBM to the removable-media fallback path
# EFI/BOOT/BOOTX64.EFI so such machines still boot (straight into ZBM,
# bypassing rEFInd). See the guide's Portable ZFSBootMenu page.
ZBM_FALLBACK="${ZBM_FALLBACK:-yes}"

#--- Passwords (prompted if unset) --------------------------------------------
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ZFS_PASSPHRASE="${ZFS_PASSPHRASE:-}"

#--- Misc ---------------------------------------------------------------------
FORCE="${FORCE:-no}"                      # yes skips only the ERASE prompt
HOSTID="${HOSTID:-0x00bab10c}"            # [GUIDE] zgenhostid -f 0x00bab10c

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

# [GUIDE] Confirm EFI support (guide does: dmesg | grep -i efivars)
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. This script is UEFI-only."

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

case "$DESKTOP"       in kde|gnome|none)   ;; *) die "DESKTOP must be kde, gnome or none." ;; esac
case "$DESKTOP_SIZE"  in minimal|full)     ;; *) die "DESKTOP_SIZE must be minimal or full." ;; esac
case "$SWAP_MODE"     in random|luks|none) ;; *) die "SWAP_MODE must be random, luks or none." ;; esac
case "$ZBM_INSTALL"   in prebuilt|source)  ;; *) die "ZBM_INSTALL must be prebuilt or source." ;; esac
case "$BASELINE_MODE" in clone|send|none)  ;; *) die "BASELINE_MODE must be clone, send or none." ;; esac

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	die "ADMIN_USER '${ADMIN_USER}' is not a valid Unix username."
fi
if [[ "$ADMIN_USER" == "root" ]]; then
	die "ADMIN_USER cannot be root."
fi

# A wrong layout or variant yields a system whose keyboard is subtly wrong,
# which is worst precisely where it matters most: the boot passphrase prompt.
if [[ -r "$XKB_LST" ]]; then
	if ! awk '/^! layout/{f=1;next} /^!/{f=0} f&&NF{print $1}' "$XKB_LST" | grep -qx "$KEYMAP"; then
		warn "KEYMAP='${KEYMAP}' is not a known XKB layout."
		die "Set KEYMAP to a valid layout code (see ${XKB_LST})."
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
else
	warn "xkb-data not available; skipping keyboard validation."
fi

[[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "TIMEZONE='${TIMEZONE}' is not a known zoneinfo name."

case "$LOCALE" in
	*.UTF-8|*.utf8) ;;
	*) die "LOCALE='${LOCALE}' must be a UTF-8 locale, e.g. en_US.UTF-8." ;;
esac
if [[ -r /usr/share/i18n/SUPPORTED ]]; then
	grep -qi "^${LOCALE} UTF-8$" /usr/share/i18n/SUPPORTED || \
		warn "LOCALE='${LOCALE}' not listed in /usr/share/i18n/SUPPORTED; locale-gen may fail."
fi

# [GUIDE] Define disk variables. The guide uses BOOT_DISK/BOOT_PART/BOOT_DEVICE
# and POOL_DISK/POOL_PART/POOL_DEVICE; same idea, derived from the by-id link.
BOOT_PART=1
SWAP_PART=2
POOL_PART=3
if (( SWAP_SIZE_MIB <= 0 )); then
	SWAP_MODE="none"
	POOL_PART=2
fi

BOOT_DEVICE="${DISK}-part${BOOT_PART}"
SWAP_DEVICE="${DISK}-part${SWAP_PART}"
POOL_DEVICE="${DISK}-part${POOL_PART}"

# [GUIDE] keylocation=file:///etc/zfs/zroot.key
KEYFILE="/etc/zfs/${POOL_NAME}.key"

log "Planned configuration"
cat <<EOF
  Disk             : ${DISK}
                     -> ${DISK_REAL}  ($(lsblk -dno SIZE,MODEL "$DISK_REAL"))
  ESP              : ${BOOT_DEVICE}   ${ESP_SIZE_MIB} MiB  vfat  /boot/efi
  Swap             : $( (( SWAP_SIZE_MIB > 0 )) && echo "${SWAP_DEVICE}   ${SWAP_SIZE_MIB} MiB  mode=${SWAP_MODE}" || echo "disabled" )
  Pool vdev        : ${POOL_DEVICE}
  Pool             : ${POOL_NAME}  ashift=${ASHIFT}  compression=${COMPRESSION}
  Feature flags    : $( [[ -n "$POOL_COMPAT" ]] && echo "compatibility=${POOL_COMPAT}" || echo "all features of the installing ZFS (no compatibility pin)" )
  Encryption       : ${ENCRYPTION_ALGO}, native, passphrase (mandatory)
  Boot environment : ${POOL_NAME}/ROOT/${BE_NAME}
  Baseline BE      : $( [[ "$BASELINE_MODE" == none ]] && echo "disabled" || echo "${POOL_NAME}/ROOT/${BASELINE_NAME} (${BASELINE_MODE})" )
  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}  (home dataset: ${POOL_NAME}/data/home/${ADMIN_USER})
  Desktop          : ${DESKTOP} (${DESKTOP_SIZE})
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : layout=${KEYMAP} variant=$( [[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none, standard layout)" )
  Backports repo   : ${ENABLE_BACKPORTS}
  Boot chain       : rEFInd -> ZFSBootMenu (${ZBM_INSTALL})
  ZBM cmdline      : ${ZBM_CMDLINE}   (countdown ${ZBM_TIMEOUT}s)
  Debian cmdline   : ${KERNEL_CMDLINE}
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
	# [GUIDE] "It's critical that your passphrase be something you can type on
	# your keyboard, since you will need to type it in to unlock the pool on
	# boot." ZFSBootMenu uses its own minimal keymap.
	echo "  This unlocks the pool at every boot, typed inside ZFSBootMenu."
	echo "  ZBM uses a basic keymap: prefer unshifted ASCII you can find blind."
	prompt_pass ZFS_PASSPHRASE "ZFS pool passphrase" 8
fi

#==============================================================================
# [GUIDE] Configure Live Environment
#==============================================================================

log "Configuring APT in the live environment"
cat > /etc/apt/sources.list <<EOF
deb ${MIRROR}/ ${SUITE} ${COMPONENTS}
deb-src ${MIRROR}/ ${SUITE} ${COMPONENTS}
EOF
rm -f /etc/apt/sources.list.d/debian.sources
export DEBIAN_FRONTEND=noninteractive
apt update

# [GUIDE] Install helpers
log "Installing ZFS and helpers in the live environment (DKMS build, be patient)"
apt install -y debootstrap gdisk dkms "linux-headers-$(uname -r)" cryptsetup
apt install -y zfsutils-linux zfs-dkms
modprobe zfs || die "zfs module failed to load in the live environment."

# [GUIDE] Generate /etc/hostid
log "Generating /etc/hostid"
zgenhostid -f "$HOSTID"

#==============================================================================
# [GUIDE] Disk preparation
#==============================================================================

log "Wiping ${DISK}"
swapoff -a || true
zpool labelclear -f "$DISK" 2>/dev/null || true
for p in "${DISK}"-part*; do
	[[ -b "$p" ]] || continue
	zpool labelclear -f "$p" 2>/dev/null || true
	wipefs -a "$p" || true
done
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
udevadm settle

log "Creating partitions"
# [GUIDE] Create EFI boot partition (guide: +512m; see ESP_SIZE_MIB)
sgdisk -n "${BOOT_PART}:1m:+${ESP_SIZE_MIB}m" -t "${BOOT_PART}:ef00" -c "${BOOT_PART}:EFI" "$DISK"

if (( SWAP_SIZE_MIB > 0 )); then
	swap_type=8200
	[[ "$SWAP_MODE" == "luks" ]] && swap_type=8309
	sgdisk -n "${SWAP_PART}:0:+${SWAP_SIZE_MIB}m" -t "${SWAP_PART}:${swap_type}" -c "${SWAP_PART}:swap" "$DISK"
fi

# [GUIDE] Create zpool partition
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" -c "${POOL_PART}:${POOL_NAME}" "$DISK"

partprobe "$DISK_REAL" || true
udevadm settle
sleep 2
sgdisk -p "$DISK"

for p in "$BOOT_DEVICE" "$POOL_DEVICE"; do
	[[ -b "$p" ]] || die "Expected partition link $p does not exist after partitioning."
done
if (( SWAP_SIZE_MIB > 0 )) && [[ ! -b "$SWAP_DEVICE" ]]; then
	die "Expected partition link $SWAP_DEVICE does not exist."
fi

#==============================================================================
# [GUIDE] ZFS pool creation (encrypted variant)
#==============================================================================

# [GUIDE] The guide's encrypted zpool create references /etc/zfs/zroot.key as a
# file "which we created in a previous step" -- but the Debian page never shows
# that step. It must exist before zpool create or the command fails.
log "Writing pool key to ${KEYFILE}"
mkdir -p /etc/zfs
printf '%s' "$ZFS_PASSPHRASE" > "$KEYFILE"
chmod 000 "$KEYFILE"

log "Creating encrypted zpool ${POOL_NAME} on ${POOL_DEVICE}"
zpool_opts=(
	-f
	-o "ashift=${ASHIFT}"
	-O "compression=${COMPRESSION}"
	-O acltype=posixacl
	-O xattr=sa
	-O relatime=on
	-O "encryption=${ENCRYPTION_ALGO}"
	-O "keylocation=file://${KEYFILE}"
	-O keyformat=passphrase
	-o autotrim=on
)
if [[ -n "$POOL_COMPAT" ]]; then
	zpool_opts+=(-o "compatibility=${POOL_COMPAT}")
fi
zpool create "${zpool_opts[@]}" -m none "$POOL_NAME" "$POOL_DEVICE"

#------------------------------------------------------------------------------
# [GUIDE] Create initial file systems
#
# The guide's warning applies to every boot environment created below:
#   "canmount is not inheritable. Therefore, setting canmount=noauto on
#    zroot/ROOT is not sufficient... It is necessary to explicitly set the
#    canmount=noauto on every boot environment you create."
# Both 'default' and 'baseline' therefore set it explicitly.
#------------------------------------------------------------------------------

log "Creating boot environment datasets"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/ROOT"
zfs create -o mountpoint=/    -o canmount=noauto "${POOL_NAME}/ROOT/${BE_NAME}"
zpool set "bootfs=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

# [DEVIATION] Guide creates a single zroot/home. This is the requested layout.
log "Creating data datasets"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data"

zfs create -o mountpoint=/home                   "${POOL_NAME}/data/home"
zfs create -o mountpoint=/root                   "${POOL_NAME}/data/home/root"
zfs create -o mountpoint="/home/${ADMIN_USER}"   "${POOL_NAME}/data/home/${ADMIN_USER}"

zfs create -o mountpoint=/opt                    "${POOL_NAME}/data/opt"
zfs create -o mountpoint=/srv                    "${POOL_NAME}/data/srv"

zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data/var"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/data/var/lib"
zfs create -o mountpoint=/var/lib/containers     "${POOL_NAME}/data/var/lib/containers"
zfs create -o mountpoint=/var/lib/docker         "${POOL_NAME}/data/var/lib/docker"
zfs create -o mountpoint=/var/lib/libvirt        "${POOL_NAME}/data/var/lib/libvirt"
zfs create -o mountpoint=/var/lib/lxc            "${POOL_NAME}/data/var/lib/lxc"
zfs create -o mountpoint=/var/log                "${POOL_NAME}/data/var/log"
zfs create -o mountpoint=/var/spool              "${POOL_NAME}/data/var/spool"
zfs create -o mountpoint=/var/tmp                "${POOL_NAME}/data/var/tmp"

if [[ "$DATASET_TUNING" == "yes" ]]; then
	log "Applying per-dataset tuning"
	# Nothing under data/var benefits from atime; relatime is inherited from
	# the pool, so this is a deliberate override.
	zfs set atime=off                       "${POOL_NAME}/data/var"
	# World-writable scratch: no setuid bits, no device nodes.
	zfs set setuid=off devices=off          "${POOL_NAME}/data/var/tmp"
	# Logs are highly compressible and written in small appends.
	zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
	# VM images: larger records suit large sequential guest I/O.
	zfs set recordsize=64K                  "${POOL_NAME}/data/var/lib/libvirt"
	# Container image stores churn on many small files.
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containers"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/docker"
fi

#------------------------------------------------------------------------------
# [GUIDE] Export, then re-import with a temporary mountpoint of /mnt
#------------------------------------------------------------------------------

log "Exporting and re-importing at /mnt"
zpool export "$POOL_NAME"
zpool import -N -R /mnt "$POOL_NAME"
zfs load-key "$POOL_NAME"
zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"
# [DEVIATION] Guide mounts zroot/home explicitly; with many datasets, mount -a
# is equivalent and mounts them in the correct (mountpoint depth) order.
zfs mount -a

# [GUIDE] Verify that everything is mounted correctly
echo
zfs list -o name,used,mountpoint,canmount -r "$POOL_NAME"
mount | grep -q ' /mnt ' || die "${POOL_NAME}/ROOT/${BE_NAME} is not mounted at /mnt."
for d in /mnt/home /mnt/root /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool /mnt/var/tmp; do
	mountpoint -q "$d" || die "Expected dataset not mounted: $d"
done

# [GUIDE] Update device symlinks
udevadm trigger

#==============================================================================
# [GUIDE] Install Debian
#==============================================================================

log "Running debootstrap (${SUITE})"
debootstrap --include=ca-certificates "$SUITE" /mnt "$MIRROR"

# Dataset-backed directories need their conventional modes restored after
# debootstrap has written into them.
log "Fixing permissions on dataset-backed directories"
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
chmod 0755 /mnt/home /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool

# [GUIDE] Copy files into the new install (encrypted variant also copies the key)
log "Copying host files into the new install"
mkdir -p /mnt/etc/zfs
cp /etc/hostid /mnt/etc/
cp /etc/resolv.conf /mnt/etc/
cp "$KEYFILE" "/mnt${KEYFILE}"
chmod 000 "/mnt${KEYFILE}"

# [GUIDE] Chroot into the new OS
log "Preparing chroot mounts"
mount -t proc  proc  /mnt/proc
mount -t sysfs sys   /mnt/sys
mount -B /dev        /mnt/dev
mount -t devpts pts  /mnt/dev/pts
# [DEVIATION] /run as tmpfs: dpkg triggers and systemctl expect it to exist.
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock
# [GUIDE] efivarfs, needed by refind-install. The guide mounts it inside the
# chroot; mounting from the host is equivalent and fails more visibly.
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || \
	warn "Could not mount efivarfs; rEFInd may fail to register a boot entry."

#==============================================================================
# Write configuration + chroot script
#==============================================================================

log "Writing chroot payload"

{
	printf 'POOL_NAME=%q\n'          "$POOL_NAME"
	printf 'BE_NAME=%q\n'            "$BE_NAME"
	printf 'KEYFILE=%q\n'            "$KEYFILE"
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
	printf 'EXTRA_PACKAGES=%q\n'     "$EXTRA_PACKAGES"
	printf 'DESKTOP=%q\n'            "$DESKTOP"
	printf 'DESKTOP_SIZE=%q\n'       "$DESKTOP_SIZE"
	printf 'BOOT_DEVICE=%q\n'        "$BOOT_DEVICE"
	printf 'SWAP_DEVICE=%q\n'        "$SWAP_DEVICE"
	printf 'SWAP_MODE=%q\n'          "$SWAP_MODE"
	printf 'SWAP_RANDOM_SOURCE=%q\n' "$SWAP_RANDOM_SOURCE"
	printf 'SWAP_CIPHER=%q\n'        "$SWAP_CIPHER"
	printf 'SWAP_KEYSIZE=%q\n'       "$SWAP_KEYSIZE"
	printf 'SWAP_MAPPER=%q\n'        "$SWAP_MAPPER"
	printf 'ZBM_INSTALL=%q\n'        "$ZBM_INSTALL"
	printf 'ZBM_CMDLINE=%q\n'        "$ZBM_CMDLINE"
	printf 'ZBM_TIMEOUT=%q\n'        "$ZBM_TIMEOUT"
	printf 'ZBM_FALLBACK=%q\n'       "$ZBM_FALLBACK"
	printf 'KERNEL_CMDLINE=%q\n'     "$KERNEL_CMDLINE"
} > /mnt/root/zbm-install.env
chmod 600 /mnt/root/zbm-install.env

cat > /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/zbm-install.env

WARNFILE=/root/INSTALL-WARNINGS.txt

log()  { printf '\n\033[1;36m -->\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() {
	printf '\033[1;33m [!]\033[0m %s\n' "$*" >&2
	printf '%s\n' "$*" >> "$WARNFILE"
}

export DEBIAN_FRONTEND=noninteractive

#--- [GUIDE] Set a hostname ---------------------------------------------------
log "Setting hostname"
echo "$TARGET_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${TARGET_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

#--- [GUIDE] Configure apt sources --------------------------------------------
log "Configuring APT sources"
rm -f /etc/apt/sources.list.d/debian.sources
cat > /etc/apt/sources.list <<EOF
deb ${MIRROR}/ ${SUITE} ${COMPONENTS}
deb-src ${MIRROR}/ ${SUITE} ${COMPONENTS}

deb ${SECURITY_MIRROR} ${SUITE}-security ${COMPONENTS}
deb-src ${SECURITY_MIRROR}/ ${SUITE}-security ${COMPONENTS}

# ${SUITE}-updates, to get updates before a point release is made
deb ${MIRROR} ${SUITE}-updates ${COMPONENTS}
deb-src ${MIRROR} ${SUITE}-updates ${COMPONENTS}
EOF

if [[ "$ENABLE_BACKPORTS" == "yes" ]]; then
	# Unpinned: backports carries a low default priority, so packages install
	# from here only when asked with -t ${SUITE}-backports.
	cat > "/etc/apt/sources.list.d/${SUITE}-backports.list" <<EOF
deb ${MIRROR} ${SUITE}-backports ${COMPONENTS}
deb-src ${MIRROR} ${SUITE}-backports ${COMPONENTS}
EOF
fi

# [GUIDE] Update the repository cache
apt update

#--- [GUIDE] Install base packages, configure locale/console properties -------
log "Configuring locale, timezone and keyboard"
apt install -y locales keyboard-configuration console-setup tzdata

# [GUIDE] "You should always enable the en_US.UTF-8 locale because some
# programs require it."
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
# (driven from the debconf answers above rather than interactively)
dpkg-reconfigure -f noninteractive tzdata
dpkg-reconfigure -f noninteractive keyboard-configuration console-setup

#--- [GUIDE] ZFS Configuration: install required packages ---------------------
log "Installing kernel and ZFS"
mkdir -p /etc/dkms
apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs dosfstools
# [DEVIATION] zfs-zed is the ZFS event daemon; without it, pool faults and
# scrub results are never reported to you.
apt install -y zfs-zed
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

#--- [DEVIATION] Microcode and firmware ---------------------------------------
if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	log "Installing CPU microcode"
	# Microcode is applied by the kernel at early boot and carries security
	# fixes. The guide omits it; a real install should not.
	CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo || true)"
	case "$CPU_VENDOR" in
		GenuineIntel) apt install -y intel-microcode ;;
		AuthenticAMD) apt install -y amd64-microcode ;;
		*) warn "Unrecognised CPU vendor '${CPU_VENDOR}'; installing both microcode packages."
		   apt install -y intel-microcode amd64-microcode || true ;;
	esac

	log "Installing device firmware"
	# firmware-linux covers only graphics/misc. Wireless, sound and NIC
	# firmware live in separate packages that nothing depends on, so a laptop
	# with an Intel wifi card comes up with no network at all unless
	# firmware-iwlwifi is installed explicitly.
	#
	# Names shift between Debian releases (the Intel sound and graphics
	# firmware have been split and renamed more than once), so each candidate
	# is probed against the archive rather than assumed to exist.
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
			warn "Some firmware packages failed; check non-free-firmware is in COMPONENTS."
	else
		warn "No firmware packages found. Is non-free-firmware in COMPONENTS?"
	fi

	# Userland needed to actually bring wireless up.
	apt install -y wireless-regdb iw rfkill wpasupplicant || true
fi

#--- [GUIDE] Enable systemd ZFS services --------------------------------------
log "Enabling ZFS systemd units"
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
systemctl enable zfs-zed

#--- [GUIDE] Rebuild the initramfs --------------------------------------------
# Guide, encrypted variant: "Because the encryption key is stored in /etc/zfs
# directory, it will automatically be copied into the system initramfs."
log "Rebuilding initramfs"
update-initramfs -c -k all

#--- [DEVIATION] Encrypted swap -----------------------------------------------
if [[ "$SWAP_MODE" != "none" ]]; then
	log "Configuring swap (${SWAP_MODE})"
	apt install -y cryptsetup

	SWAP_PARTUUID="$(blkid -s PARTUUID -o value "$SWAP_DEVICE")"
	SWAP_BY_PARTUUID="/dev/disk/by-partuuid/${SWAP_PARTUUID}"

	if [[ "$SWAP_MODE" == "random" ]]; then
		# Plain dm-crypt. crypttab's 'swap' option takes a fresh key from the
		# source device and runs mkswap on every boot.
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	${SWAP_BY_PARTUUID}	${SWAP_RANDOM_SOURCE}	swap,cipher=${SWAP_CIPHER},size=${SWAP_KEYSIZE},discard
EOF
	else
		# Persistent LUKS2 unlocked from a keyfile on the encrypted root, so it
		# never prompts: root is already open when crypttab is processed.
		install -d -m 700 /etc/cryptsetup-keys.d
		dd if=/dev/urandom of=/etc/cryptsetup-keys.d/swap.key bs=512 count=1 status=none
		chmod 400 /etc/cryptsetup-keys.d/swap.key

		cryptsetup luksFormat --type luks2 --batch-mode \
			--cipher "$SWAP_CIPHER" --key-size "$SWAP_KEYSIZE" \
			--key-file /etc/cryptsetup-keys.d/swap.key "$SWAP_DEVICE"
		cryptsetup open --key-file /etc/cryptsetup-keys.d/swap.key \
			"$SWAP_DEVICE" "$SWAP_MAPPER"
		mkswap -L swap "/dev/mapper/${SWAP_MAPPER}"

		SWAP_UUID="$(blkid -s UUID -o value "$SWAP_DEVICE")"
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	UUID=${SWAP_UUID}	/etc/cryptsetup-keys.d/swap.key	luks,discard
EOF
		cryptsetup close "$SWAP_MAPPER"
	fi

	echo "/dev/mapper/${SWAP_MAPPER}	none	swap	sw	0	0" >> /etc/fstab
fi

#--- [GUIDE] Set ZFSBootMenu properties on datasets ---------------------------
log "Setting ZFSBootMenu dataset properties"
# Inherited by every boot environment under ROOT, including baseline.
# %{parent} can be used per-environment to extend rather than replace this.
zfs set "org.zfsbootmenu:commandline=${KERNEL_CMDLINE}" "${POOL_NAME}/ROOT"
# [GUIDE] Setup key caching in ZFSBootMenu, so the passphrase is asked once.
zfs set "org.zfsbootmenu:keysource=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

#--- [GUIDE] Create a vfat filesystem, fstab entry, and mount -----------------
log "Creating vfat filesystem on the ESP and mounting /boot/efi"
mkfs.vfat -F32 -n EFI "$BOOT_DEVICE"
ESP_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE")"
echo "UUID=${ESP_UUID}	/boot/efi	vfat	defaults	0	0" >> /etc/fstab
mkdir -p /boot/efi
mount /boot/efi

#--- [GUIDE] Install ZFSBootMenu ----------------------------------------------
log "Installing ZFSBootMenu (${ZBM_INSTALL})"
# [GUIDE] "Choose 'No' when asked if kexec-tools should handle reboots."
echo 'kexec-tools kexec-tools/load_kexec boolean false' | debconf-set-selections

if [[ "$ZBM_INSTALL" == "prebuilt" ]]; then
	apt install -y curl
	mkdir -p /boot/efi/EFI/ZBM
	curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
else
	apt install -y curl make git dracut-core fzf kexec-tools mbuffer gawk \
		libsort-versions-perl libboolean-perl libyaml-pp-perl \
		libconfig-inifiles-perl systemd-boot-efi

	mkdir -p /usr/local/src/zfsbootmenu
	cd /usr/local/src/zfsbootmenu
	curl -fSL https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -f -
	make core dracut

	# [GUIDE] config.yaml keys, verbatim from the guide apart from ImageDir
	# case (vfat is case-insensitive, so EFI/ZBM and EFI/zbm are one directory)
	# and CommandLine, which carries ZBM's own verbosity.
	mkdir -p /etc/zfsbootmenu
	cat > /etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
Components:
  Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ${ZBM_CMDLINE}
EOF
	generate-zbm

	# Normalise filenames so refind_linux.conf below is predictable.
	# Written as explicit if-blocks: a trailing '[[ test ]] && cmd' that
	# short-circuits returns 1, which is fatal under 'set -e' at end of scope.
	if [[ -f /boot/efi/EFI/ZBM/vmlinuz.EFI ]]; then
		mv /boot/efi/EFI/ZBM/vmlinuz.EFI /boot/efi/EFI/ZBM/VMLINUZ.EFI
	fi
	if [[ -f /boot/efi/EFI/ZBM/vmlinuz-backup.EFI ]]; then
		mv /boot/efi/EFI/ZBM/vmlinuz-backup.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	fi
	if [[ ! -f /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI ]]; then
		cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	fi
	cd /
fi

#--- [GUIDE] Configure EFI boot entries (rEFInd variant) ----------------------
log "Installing and configuring rEFInd"
mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true

echo 'refind refind/install_to_esp boolean true' | debconf-set-selections
apt install -y refind efibootmgr

# Not fatal: the machine may still boot via the fallback path below, and
# aborting here would leave the install with no user accounts at all.
if ! refind-install; then
	warn "refind-install FAILED. The system may not boot via rEFInd."
	warn "Rely on the EFI/BOOT/BOOTX64.EFI fallback, or repair from a live ISO."
fi

# [GUIDE] The guide removes this file: refind-install writes
# /boot/refind_linux.conf, which would make rEFInd generate entries for the
# Debian kernel directly and bypass ZFSBootMenu entirely.
rm -f /boot/refind_linux.conf

# These configure ZFSBootMenu's own kernel, not Debian's.
#   zbm.timeout=N  show the countdown for N seconds, then boot bootfs
#   zbm.show       always drop into the boot-environment selector
#   zbm.skip       boot bootfs immediately, no menu, no countdown
cat > /boot/efi/EFI/ZBM/refind_linux.conf <<EOF
"Boot default"      "${ZBM_CMDLINE} zbm.timeout=${ZBM_TIMEOUT}"
"Boot to menu"      "${ZBM_CMDLINE} zbm.show"
"Boot immediately"  "${ZBM_CMDLINE} zbm.skip"
"Verbose debug"     "loglevel=7 zbm.show"
EOF

if [[ "$ZBM_FALLBACK" == "yes" ]]; then
	# The guide's "See also" notes that some firmware silently drops EFI boot
	# entries and points at Portable ZFSBootMenu. A well-known removable-media
	# name always boots. This lands in ZBM directly, bypassing rEFInd, and is
	# only ever reached if the NVRAM entries are ignored.
	mkdir -p /boot/efi/EFI/BOOT
	if [[ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
		cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
	fi
fi

#--- Accounts -----------------------------------------------------------------
log "Creating accounts"
apt install -y sudo

# [GUIDE] Set a root password
echo "root:${ROOT_PASSWORD}" | chpasswd

# /home/${ADMIN_USER} already exists as a mounted dataset. useradd -m REFUSES
# to populate a directory that already exists -- it prints "Not copying any
# file from skel directory into it" and carries on -- silently leaving the
# account with no .bashrc, .profile or .bash_logout. So use -M (never touch
# the home directory) and install the skeleton by hand.
useradd -M -d "/home/${ADMIN_USER}" -s /bin/bash \
	-c "$ADMIN_FULLNAME" -G "${ADMIN_GROUPS},sudo" "$ADMIN_USER"
cp -a /etc/skel/. "/home/${ADMIN_USER}/"
echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}"
chmod 0750 "/home/${ADMIN_USER}"

if [[ ! -f "/home/${ADMIN_USER}/.bashrc" ]]; then
	warn "/home/${ADMIN_USER}/.bashrc missing -- skel copy did not work."
fi

#--- Base userland ------------------------------------------------------------
log "Installing base userland"
apt install -y \
	network-manager openssh-client ca-certificates \
	bash-completion less nano vim-tiny curl wget rsync \
	man-db pciutils usbutils htop zstd git gdisk cryptsetup \
	systemd-timesyncd
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

if [[ -n "$EXTRA_PACKAGES" ]]; then
	# Deliberately unquoted: EXTRA_PACKAGES is a space-separated list.
	apt install -y $EXTRA_PACKAGES
fi

#--- Desktop ------------------------------------------------------------------
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

#--- Cleanup ------------------------------------------------------------------
log "Cleaning up"
apt --purge autoremove -y
apt clean
CHROOT_EOF

chmod 700 /mnt/root/zbm-chroot.sh

#==============================================================================
# Run the chroot stage
#==============================================================================

log "Entering chroot"
chroot /mnt /usr/bin/env bash /root/zbm-chroot.sh

#==============================================================================
# Baseline boot environment
#==============================================================================

log "Removing installer artefacts"
rm -f /mnt/root/zbm-install.env /mnt/root/zbm-chroot.sh

if [[ "$BASELINE_MODE" != "none" ]]; then
	log "Creating factory baseline boot environment (${BASELINE_MODE})"
	zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}"

	if [[ "$BASELINE_MODE" == "clone" ]]; then
		# Cheap: shares blocks with default. The @baseline snapshot cannot be
		# destroyed while the clone exists, which is exactly the guarantee a
		# factory image should carry.
		# canmount=noauto set explicitly, per the guide's warning that canmount
		# is not inheritable.
		zfs clone -o canmount=noauto -o mountpoint=/ \
			"${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" \
			"${POOL_NAME}/ROOT/${BASELINE_NAME}"
	else
		# Independent full copy: survives destruction of default, at the cost
		# of a second copy of the OS.
		zfs send "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" | \
			zfs recv -u "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set canmount=noauto "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set mountpoint=/    "${POOL_NAME}/ROOT/${BASELINE_NAME}"
	fi
fi

#==============================================================================
# [GUIDE] Prepare for first boot
#==============================================================================

log "Final dataset layout"
zfs list -o name,used,refer,mountpoint,canmount -r "$POOL_NAME"

if [[ -s /mnt/root/INSTALL-WARNINGS.txt ]]; then
	echo
	warn "Warnings were recorded during installation:"
	sed 's/^/    /' /mnt/root/INSTALL-WARNINGS.txt >&2
	warn "Kept at /root/INSTALL-WARNINGS.txt on the new system."
fi

# [GUIDE] Exit the chroot, unmount everything
log "Unmounting and exporting the pool"
umount -n -R /mnt || {
	warn "Lazy-unmounting stragglers"
	umount -n -R -l /mnt || true
}
sleep 2

# [GUIDE] Export the zpool and reboot
zpool export "$POOL_NAME"

log "Done"
cat <<EOF

Installation complete. Remove the live medium and reboot.

BOOT CHAIN
  firmware -> rEFInd -> ZFSBootMenu -> ${POOL_NAME}/ROOT/${BE_NAME}

  rEFInd offers four ways into ZFSBootMenu, all using the same EFI image:
    Boot default      ${ZBM_TIMEOUT}s countdown, then boots bootfs
    Boot to menu      always show the boot-environment selector
    Boot immediately  no menu, no countdown
    Verbose debug     loglevel=7, ZBM's full internal tracing

  Enter your ZFS passphrase to unlock ${POOL_NAME}.
$( [[ "$BASELINE_MODE" != none ]] && printf '%s\n' \
"  ${POOL_NAME}/ROOT/${BASELINE_NAME} is selectable in ZFSBootMenu as a" \
"  known-good factory image. Boot it if ${BE_NAME} ever breaks." )
  Log in as '${ADMIN_USER}' (sudo enabled) or root.

BOOT VERBOSITY
  'quiet' is not set anywhere.
    ZFSBootMenu's own kernel : ${ZBM_CMDLINE}
    Debian's kernel          : ${KERNEL_CMDLINE}

  Change Debian's verbosity later without touching the bootloader:
    sudo zfs set org.zfsbootmenu:commandline="loglevel=7 systemd.show_status=yes" ${POOL_NAME}/ROOT
  Return to a silent boot:
    sudo zfs set org.zfsbootmenu:commandline="quiet loglevel=3" ${POOL_NAME}/ROOT
  Make one environment verbose (%{parent} expands to the parent's value):
    sudo zfs set org.zfsbootmenu:commandline="loglevel=7 %{parent}" ${POOL_NAME}/ROOT/${BE_NAME}

  Change ZFSBootMenu's own verbosity or countdown by editing
  /boot/efi/EFI/ZBM/refind_linux.conf. No regeneration needed.

NEW BOOT ENVIRONMENTS
  canmount is NOT inheritable, so every new BE needs it set explicitly, or the
  system will try to mount two filesystems at / and fail to boot:
    zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade
    zfs clone -o canmount=noauto -o mountpoint=/ \\
        ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade ${POOL_NAME}/ROOT/new
  ZFSBootMenu can also do this for you from its own menu.

NEW USERS
  useradd will NOT copy /etc/skel into a home directory that already exists,
  and a per-user dataset makes it exist. Populate it yourself:
    zfs create -o mountpoint=/home/NAME ${POOL_NAME}/data/home/NAME
    useradd -M -d /home/NAME -s /bin/bash -G sudo NAME
    cp -a /etc/skel/. /home/NAME/
    chown -R NAME:NAME /home/NAME && chmod 0750 /home/NAME
    passwd NAME

SWAP
  ${SWAP_MODE}-encrypted on ${SWAP_DEVICE}.$( [[ "$SWAP_MODE" == "random" ]] && echo " Hibernation is not possible." )

CONTAINERS AND VMS
  The datasets exist but no daemons are installed. Install docker.io, podman,
  libvirt-daemon-system or lxc when needed; they land on their own datasets.

UPDATING ZFSBOOTMENU
    sudo curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
  Leave VMLINUZ-BACKUP.EFI alone as the known-good fallback.

UPGRADING TO OPENZFS 2.4.x FROM ${SUITE}-backports
  The pool was created with $( [[ -n "$POOL_COMPAT" ]] && echo "compatibility=${POOL_COMPAT}" || echo "no compatibility pin" ).
  Follow this order exactly:

  1. Install the newer ZFS and rebuild the initramfs:
       sudo apt install -t ${SUITE}-backports zfs-dkms zfsutils-linux zfs-initramfs
       sudo update-initramfs -c -k all
     Reboot, then confirm userland and kmod both report 2.4.x:  zfs version

  2. Refresh ZFSBootMenu to an image built against 2.4 BEFORE upgrading the
     pool. Check which ZFS version a release embeds at
     https://github.com/zbm-dev/zfsbootmenu/releases

  3. Reboot through the NEW ZBM image and confirm it still imports ${POOL_NAME}
     and boots. Only then:
       sudo zpool upgrade ${POOL_NAME}

  Step 2 before step 3 is not optional. zpool upgrade is irreversible, and a
  ZBM image predating a newly enabled feature flag cannot import the pool,
  leaving you booting a rescue ISO to recover. Note also that once the pool is
  upgraded, VMLINUZ-BACKUP.EFI stops being a usable fallback unless it too has
  been refreshed.

EOF
