#!/usr/bin/env bash
#
# debian13-zbm-install.sh  (v2)
#
# Debian 13 (Trixie) root-on-ZFS with ZFSBootMenu + rEFInd, UEFI only,
# mandatory ZFS native encryption.
# Follows https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html
#
# Disk layout on $DISK (a /dev/disk/by-id/... path, GPT, fully wiped):
#   -part1   1 MiB .. +1024 MiB   ef00  EFI System Partition -> /boot/efi
#   -part2         .. +1024 MiB   8309  encrypted swap
#   -part3         .. -10 MiB     bf00  ZFS pool
#
# Dataset hierarchy:
#   zroot/ROOT                      mountpoint=none  canmount=off
#   ├── default                     mountpoint=/     canmount=noauto   <- active
#   └── baseline                    mountpoint=/     canmount=noauto   <- factory
#   zroot/data                      mountpoint=none  canmount=off
#   ├── home                        /home
#   │   ├── root                    /root
#   │   └── <username>              /home/<username>
#   ├── opt                         /opt
#   ├── srv                         /srv
#   └── var                         (container, canmount=off)
#       ├── lib                     (container, canmount=off)
#       │   ├── containers          /var/lib/containers   (Podman)
#       │   ├── docker              /var/lib/docker       (Docker)
#       │   ├── libvirt             /var/lib/libvirt      (VMs)
#       │   └── lxc                 /var/lib/lxc          (LXC)
#       ├── log                     /var/log
#       ├── spool                   /var/spool
#       └── tmp                     /var/tmp
#
# Run as root from a Debian 13 Live ISO booted in UEFI mode:
#
#   DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
#   DESKTOP=kde ADMIN_USER=alireza ./debian13-zbm-install.sh
#
# THIS DESTROYS ALL DATA ON $DISK.
#
set -euo pipefail

################################################################################
# Detect keyboard defaults from the running live environment
#
# Only the keyboard is inherited: whatever layout you selected on the live ISO
# boot menu already lives in /etc/default/keyboard, and getting it wrong makes
# the boot passphrase prompt hard to use. Locale and timezone are NOT guessed —
# set them explicitly with the LOCALE and TIMEZONE environment variables.
################################################################################

_LIVE_XKBLAYOUT=""
_LIVE_XKBVARIANT=""
if [[ -r /etc/default/keyboard ]]; then
	_LIVE_XKBLAYOUT="$(. /etc/default/keyboard 2>/dev/null; printf '%s' "${XKBLAYOUT:-}")"
	_LIVE_XKBVARIANT="$(. /etc/default/keyboard 2>/dev/null; printf '%s' "${XKBVARIANT:-}")"
fi

XKB_LST="/usr/share/X11/xkb/rules/base.lst"

# List the variants available for a layout, e.g.  list_variants us
list_variants() {
	local layout="$1"
	[[ -r "$XKB_LST" ]] || { echo "  (xkb-data not installed; cannot list)" >&2; return; }
	printf '  %-16s %s\n' "(none)" "default layout for '${layout}'" >&2
	awk -v l="${layout}:" '
		/^! variant/ { f=1; next }
		/^!/         { f=0 }
		f && NF > 1 && $2 == l {
			name = $1; $1 = ""; $2 = "";
			sub(/^ +/, "");
			printf "  %-16s %s\n", name, $0
		}' "$XKB_LST" >&2
}

# Convenience: LIST_KEYBOARD=de ./script  prints the variants for 'de' and exits
if [[ -n "${LIST_KEYBOARD:-}" ]]; then
	_l="${LIST_KEYBOARD}"
	[[ "$_l" == "yes" ]] && _l="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
	echo "Keyboard variants for layout '${_l}':" >&2
	list_variants "$_l"
	exit 0
fi

################################################################################
# CONFIGURATION - override any of these as environment variables
################################################################################

# --- Target disk (REQUIRED, must be a /dev/disk/by-id/ path) ----------------
# List candidates with:  ls -l /dev/disk/by-id/ | grep -v -- -part
DISK="${DISK:-}"

# --- Desktop environment ----------------------------------------------------
DESKTOP="${DESKTOP:-kde}"               # kde | gnome | none
DESKTOP_SIZE="${DESKTOP_SIZE:-minimal}" # minimal | full

# --- Identity ---------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian-zbm}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
ADMIN_GROUPS="${ADMIN_GROUPS:-adm,cdrom,dip,plugdev,users,audio,video,netdev}"

# --- Locale / time / keyboard ----------------------------------------------
# Locale and timezone are plain environment variables with fixed defaults.
# Both are validated before anything destructive happens.
#   TIMEZONE : any zoneinfo name, e.g. Europe/Berlin, Asia/Tehran, Etc/UTC
#              (list with: timedatectl list-timezones)
#   LOCALE   : a UTF-8 locale, e.g. en_US.UTF-8, de_DE.UTF-8, fa_IR.UTF-8
#              en_US.UTF-8 is always generated as well, since some programs
#              require it.
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# The keyboard layout IS inherited from the live session, because a wrong
# keymap makes the boot-time passphrase prompt painful. Override if needed.
KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
#
# KEYBOARD_VARIANT is the XKB *variant* of KEYMAP. Empty is a valid and common
# answer: it means "the plain default layout for this country code". us + empty
# is US QWERTY; de + empty is German QWERTZ. You only need a variant for
# deliberately non-standard layouts (dvorak, colemak, nodeadkeys, intl, ...).
#
# If you don't know, leave it alone. To see the options for your layout:
#     LIST_KEYBOARD=yes ./debian13-zbm-install.sh
#
# Note the '-' rather than ':-' below: passing KEYBOARD_VARIANT= explicitly
# forces "no variant" even when the live session has one set.
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"

# --- Partition sizes (MiB) --------------------------------------------------
ESP_SIZE_MIB="${ESP_SIZE_MIB:-1024}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"  # 0 disables swap entirely

# --- Swap encryption --------------------------------------------------------
# random : plain dm-crypt, fresh key from $SWAP_RANDOM_SOURCE every boot.
#          Nothing survives reboot; hibernation impossible by construction.
# luks   : persistent LUKS2, unlocked from a keyfile on the encrypted root.
# none   : plain unencrypted swap (not recommended)
SWAP_MODE="${SWAP_MODE:-random}"
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"     # 512 = AES-256 in XTS
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

# --- ZFS --------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-zroot}"
BE_NAME="${BE_NAME:-default}"           # zroot/ROOT/default
BASELINE_NAME="${BASELINE_NAME:-baseline}"
# clone : baseline is a clone of default@baseline (cheap, shares blocks)
# send  : baseline is an independent full copy (costs a second copy of the OS)
# none  : do not create a baseline boot environment
BASELINE_MODE="${BASELINE_MODE:-clone}"
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-aes-256-gcm}"
# Empty = enable every feature flag the installing ZFS supports (2.3.x from the
# Trixie live ISO). Deliberately unset so the pool can later be upgraded to
# 2.4.x features from trixie-backports. See the post-install notes: refresh
# ZFSBootMenu BEFORE running 'zpool upgrade', or the pool becomes unimportable
# by the boot image. Set e.g. POOL_COMPAT=openzfs-2.3-linux to pin it instead.
POOL_COMPAT="${POOL_COMPAT:-}"
DATASET_TUNING="${DATASET_TUNING:-yes}" # light per-dataset property tuning

# --- Debian -----------------------------------------------------------------
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://deb.debian.org/debian-security}"
COMPONENTS="${COMPONENTS:-main contrib non-free-firmware}"
# Adds the trixie-backports source without pinning, so nothing is pulled from
# it unless you ask explicitly (apt install -t trixie-backports ...).
ENABLE_BACKPORTS="${ENABLE_BACKPORTS:-yes}"
INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

# --- ZFSBootMenu / rEFInd ---------------------------------------------------
ZBM_INSTALL="${ZBM_INSTALL:-prebuilt}"  # prebuilt | source
KERNEL_CMDLINE="${KERNEL_CMDLINE:-quiet loglevel=0}"

# --- Passwords (prompted if unset) ------------------------------------------
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ZFS_PASSPHRASE="${ZFS_PASSPHRASE:-}"

# --- Misc -------------------------------------------------------------------
FORCE="${FORCE:-no}"
HOSTID="${HOSTID:-0x00bab10c}"

################################################################################
# Helpers
################################################################################

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
}

list_disks() {
	echo "Available disks under /dev/disk/by-id/ (partitions omitted):" >&2
	local l
	for l in /dev/disk/by-id/*; do
		[[ "$l" == *-part* ]] && continue
		[[ -b "$l" ]] || continue
		[[ "$(lsblk -dno TYPE "$l" 2>/dev/null)" == "disk" ]] || continue
		printf '  %-70s %s\n' "$l" "$(lsblk -dno SIZE,MODEL "$l" 2>/dev/null)" >&2
	done
}

################################################################################
# Preflight
################################################################################

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. This script is UEFI-only."

if [[ -z "$DISK" ]]; then
	list_disks
	die "DISK is not set. Pass a /dev/disk/by-id/... path."
fi

# by-id paths are mandatory: they are stable across reboots and controller
# reordering, and they give us deterministic -partN children.
if [[ "$DISK" != /dev/disk/by-id/* ]]; then
	list_disks
	die "DISK must be a /dev/disk/by-id/... path (got: ${DISK})."
fi
[[ "$DISK" == *-part* ]] && die "DISK must point at a whole disk, not a partition."
[[ -b "$DISK" ]] || { list_disks; die "${DISK} is not a block device."; }

DISK_REAL="$(readlink -f "$DISK")"
[[ "$(lsblk -dno TYPE "$DISK_REAL")" == "disk" ]] || die "${DISK} does not resolve to a whole disk."

case "$DESKTOP"       in kde|gnome|none)   ;; *) die "DESKTOP must be kde, gnome or none." ;; esac
case "$DESKTOP_SIZE"  in minimal|full)     ;; *) die "DESKTOP_SIZE must be minimal or full." ;; esac
case "$SWAP_MODE"     in random|luks|none) ;; *) die "SWAP_MODE must be random, luks or none." ;; esac
case "$ZBM_INSTALL"   in prebuilt|source)  ;; *) die "ZBM_INSTALL must be prebuilt or source." ;; esac
case "$BASELINE_MODE" in clone|send|none)  ;; *) die "BASELINE_MODE must be clone, send or none." ;; esac
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "ADMIN_USER is not a valid Unix username."
[[ "$ADMIN_USER" == "root" ]] && die "ADMIN_USER cannot be root."

# A bad layout or variant produces a system whose keyboard is subtly wrong,
# which is especially unpleasant when you have to type a passphrase at boot.
if [[ -r "$XKB_LST" ]]; then
	if ! awk '/^! layout/{f=1;next} /^!/{f=0} f&&NF{print $1}' "$XKB_LST" | grep -qx "$KEYMAP"; then
		warn "KEYMAP='${KEYMAP}' is not a known XKB layout."
		echo "  Known layouts: awk '/^! layout/{f=1;next}/^!/{f=0}f&&NF{print \$1}' ${XKB_LST}" >&2
		die "Set KEYMAP to a valid layout code."
	fi
	if [[ -n "$KEYBOARD_VARIANT" ]]; then
		if ! awk -v l="${KEYMAP}:" '/^! variant/{f=1;next} /^!/{f=0} f&&NF>1&&$2==l{print $1}' \
			"$XKB_LST" | grep -qx "$KEYBOARD_VARIANT"; then
			warn "KEYBOARD_VARIANT='${KEYBOARD_VARIANT}' is not valid for layout '${KEYMAP}'."
			echo "Valid variants for '${KEYMAP}':" >&2
			list_variants "$KEYMAP"
			die "Set KEYBOARD_VARIANT to one of the above, or leave it empty."
		fi
	fi
else
	warn "xkb-data not available; skipping keyboard layout validation."
fi

[[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "TIMEZONE='${TIMEZONE}' is not a known zoneinfo name."

case "$LOCALE" in
	*.UTF-8|*.utf8) ;;
	*) die "LOCALE='${LOCALE}' must be a UTF-8 locale, e.g. en_US.UTF-8." ;;
esac
if [[ -r /usr/share/i18n/SUPPORTED ]]; then
	grep -qi "^${LOCALE} UTF-8$" /usr/share/i18n/SUPPORTED || \
		warn "LOCALE='${LOCALE}' is not listed in /usr/share/i18n/SUPPORTED; locale-gen may fail."
fi

BOOT_PART=1
SWAP_PART=2
POOL_PART=3
(( SWAP_SIZE_MIB > 0 )) || { SWAP_MODE="none"; POOL_PART=2; }

# by-id links expose partitions as <link>-partN, which is exactly what we want.
BOOT_DEVICE="${DISK}-part${BOOT_PART}"
SWAP_DEVICE="${DISK}-part${SWAP_PART}"
POOL_DEVICE="${DISK}-part${POOL_PART}"

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
  Backports repo   : ${ENABLE_BACKPORTS}
  Encryption       : ${ENCRYPTION_ALGO} (native, mandatory, passphrase)
  Boot environment : ${POOL_NAME}/ROOT/${BE_NAME}
  Baseline BE      : $( [[ "$BASELINE_MODE" == none ]] && echo "disabled" || echo "${POOL_NAME}/ROOT/${BASELINE_NAME} (${BASELINE_MODE})" )
  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}  (home dataset: ${POOL_NAME}/data/home/${ADMIN_USER})
  Desktop          : ${DESKTOP} (${DESKTOP_SIZE})
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : layout=${KEYMAP} variant=$( [[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none, standard layout)" )
  Boot chain       : rEFInd -> ZFSBootMenu (${ZBM_INSTALL})
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
	echo "  This unlocks the pool at every boot, typed inside ZFSBootMenu."
	echo "  Use characters you can reach on a plain ${KEYMAP} layout."
	prompt_pass ZFS_PASSPHRASE "ZFS pool passphrase" 8
fi

################################################################################
# Configure live environment
################################################################################

log "Configuring APT in the live environment"
cat > /etc/apt/sources.list <<EOF
deb ${MIRROR}/ ${SUITE} ${COMPONENTS}
deb-src ${MIRROR}/ ${SUITE} ${COMPONENTS}
EOF
rm -f /etc/apt/sources.list.d/debian.sources
export DEBIAN_FRONTEND=noninteractive
apt update

log "Installing ZFS and helpers in the live environment (DKMS build, be patient)"
apt install -y debootstrap gdisk dkms "linux-headers-$(uname -r)" cryptsetup
apt install -y zfsutils-linux zfs-dkms
modprobe zfs || die "zfs module failed to load in the live environment."

log "Generating /etc/hostid"
zgenhostid -f "$HOSTID"

################################################################################
# Disk preparation
################################################################################

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
sgdisk -n "${BOOT_PART}:1m:+${ESP_SIZE_MIB}m" -t "${BOOT_PART}:ef00" -c "${BOOT_PART}:EFI" "$DISK"
if (( SWAP_SIZE_MIB > 0 )); then
	swap_type=8200
	[[ "$SWAP_MODE" == "luks" ]] && swap_type=8309
	sgdisk -n "${SWAP_PART}:0:+${SWAP_SIZE_MIB}m" -t "${SWAP_PART}:${swap_type}" -c "${SWAP_PART}:swap" "$DISK"
fi
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" -c "${POOL_PART}:${POOL_NAME}" "$DISK"

partprobe "$DISK_REAL" || true
udevadm settle
sleep 2
sgdisk -p "$DISK"

for p in "$BOOT_DEVICE" "$POOL_DEVICE"; do
	[[ -b "$p" ]] || die "Expected partition link $p does not exist after partitioning."
done
(( SWAP_SIZE_MIB > 0 )) && { [[ -b "$SWAP_DEVICE" ]] || die "Missing $SWAP_DEVICE"; }

################################################################################
# ZFS pool creation (native encryption is mandatory)
################################################################################

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
[[ -n "$POOL_COMPAT" ]] && zpool_opts+=(-o "compatibility=${POOL_COMPAT}")

# The by-id link is used as the vdev path so the pool label records a stable
# device name; zpool will resolve and store it accordingly.
zpool create "${zpool_opts[@]}" -m none "$POOL_NAME" "$POOL_DEVICE"

################################################################################
# Dataset hierarchy
################################################################################

log "Creating boot environment datasets"
zfs create -o mountpoint=none -o canmount=off        "${POOL_NAME}/ROOT"
zfs create -o mountpoint=/    -o canmount=noauto     "${POOL_NAME}/ROOT/${BE_NAME}"
zpool set "bootfs=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

log "Creating data datasets"
zfs create -o mountpoint=none -o canmount=off        "${POOL_NAME}/data"

zfs create -o mountpoint=/home                       "${POOL_NAME}/data/home"
zfs create -o mountpoint=/root                       "${POOL_NAME}/data/home/root"
zfs create -o mountpoint="/home/${ADMIN_USER}"       "${POOL_NAME}/data/home/${ADMIN_USER}"

zfs create -o mountpoint=/opt                        "${POOL_NAME}/data/opt"
zfs create -o mountpoint=/srv                        "${POOL_NAME}/data/srv"

zfs create -o mountpoint=none -o canmount=off        "${POOL_NAME}/data/var"
zfs create -o mountpoint=none -o canmount=off        "${POOL_NAME}/data/var/lib"
zfs create -o mountpoint=/var/lib/containers         "${POOL_NAME}/data/var/lib/containers"
zfs create -o mountpoint=/var/lib/docker             "${POOL_NAME}/data/var/lib/docker"
zfs create -o mountpoint=/var/lib/libvirt            "${POOL_NAME}/data/var/lib/libvirt"
zfs create -o mountpoint=/var/lib/lxc                "${POOL_NAME}/data/var/lib/lxc"
zfs create -o mountpoint=/var/log                    "${POOL_NAME}/data/var/log"
zfs create -o mountpoint=/var/spool                  "${POOL_NAME}/data/var/spool"
zfs create -o mountpoint=/var/tmp                    "${POOL_NAME}/data/var/tmp"

if [[ "$DATASET_TUNING" == "yes" ]]; then
	log "Applying per-dataset tuning"
	# Nothing under data/ benefits from atime; relatime is inherited from the
	# pool, so this is a deliberate override rather than a default.
	zfs set atime=off                       "${POOL_NAME}/data/var"
	# /var/tmp is world-writable scratch: no setuid, no device nodes.
	zfs set setuid=off devices=off          "${POOL_NAME}/data/var/tmp"
	# Logs are highly compressible and written in small appends.
	zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
	# VM disk images: larger records, and no point compressing twice if the
	# guest already does. Adjust to taste per image workload.
	zfs set recordsize=64K                  "${POOL_NAME}/data/var/lib/libvirt"
	# Container image stores churn on many small files.
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containers"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/docker"
fi

log "Exporting and re-importing at /mnt"
zpool export "$POOL_NAME"
zpool import -N -R /mnt "$POOL_NAME"
zfs load-key "$POOL_NAME"
zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"
zfs mount -a

echo
zfs list -o name,used,mountpoint,canmount -r "$POOL_NAME"
mount | grep -q ' /mnt ' || die "${POOL_NAME}/ROOT/${BE_NAME} is not mounted at /mnt."
for d in /mnt/home /mnt/root /mnt/opt /mnt/srv /mnt/var/log /mnt/var/tmp; do
	mountpoint -q "$d" || die "Expected dataset not mounted: $d"
done
udevadm trigger

################################################################################
# Bootstrap Debian
################################################################################

log "Running debootstrap (${SUITE})"
debootstrap --include=ca-certificates "$SUITE" /mnt "$MIRROR"

log "Fixing permissions on dataset-backed directories"
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
chmod 0755 /mnt/home /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool

log "Copying host files into the new install"
mkdir -p /mnt/etc/zfs
cp /etc/hostid /mnt/etc/
cp /etc/resolv.conf /mnt/etc/
cp "$KEYFILE" "/mnt${KEYFILE}"
chmod 000 "/mnt${KEYFILE}"

log "Preparing chroot mounts"
mount -t proc  proc  /mnt/proc
mount -t sysfs sys   /mnt/sys
mount -B /dev        /mnt/dev
mount -t devpts pts  /mnt/dev/pts
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || \
	warn "Could not mount efivarfs; rEFInd may fail to register a boot entry."

################################################################################
# Write configuration + chroot script
################################################################################

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
	printf 'KERNEL_CMDLINE=%q\n'     "$KERNEL_CMDLINE"
} > /mnt/root/zbm-install.env
chmod 600 /mnt/root/zbm-install.env

cat > /mnt/root/zbm-chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/zbm-install.env

log()  { printf '\n\033[1;36m -->\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m [!]\033[0m %s\n' "$*" >&2; }

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- hostname ---
log "Setting hostname"
echo "$TARGET_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${TARGET_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

# -------------------------------------------------------------- apt config ---
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
	# Not pinned: backports has a low default priority, so packages are only
	# installed from here when requested with -t ${SUITE}-backports.
	cat > "/etc/apt/sources.list.d/${SUITE}-backports.list" <<EOF
deb ${MIRROR} ${SUITE}-backports ${COMPONENTS}
deb-src ${MIRROR} ${SUITE}-backports ${COMPONENTS}
EOF
fi

apt update

# ---------------------------------------------------------- locale/tz/kbd ---
log "Configuring locale, timezone and keyboard"
apt install -y locales keyboard-configuration console-setup tzdata

sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
grep -q "^${LOCALE} UTF-8"    /etc/locale.gen || echo "${LOCALE} UTF-8"    >> /etc/locale.gen
grep -q "^en_US.UTF-8 UTF-8"  /etc/locale.gen || echo "en_US.UTF-8 UTF-8"  >> /etc/locale.gen
locale-gen
update-locale "LANG=${LOCALE}"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

debconf-set-selections <<EOF
keyboard-configuration keyboard-configuration/xkb-keymap select ${KEYMAP}
keyboard-configuration keyboard-configuration/variant select ${KEYBOARD_VARIANT}
console-setup console-setup/charmap47 select UTF-8
EOF
sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"${KEYMAP}\"/"           /etc/default/keyboard 2>/dev/null || true
sed -i "s/^XKBVARIANT=.*/XKBVARIANT=\"${KEYBOARD_VARIANT}\"/" /etc/default/keyboard 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration console-setup

# ---------------------------------------------------------- kernel + ZFS ---
log "Installing kernel and ZFS"
mkdir -p /etc/dkms
apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs zfs-zed dosfstools
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	apt install -y firmware-linux firmware-linux-nonfree || \
		warn "Firmware packages unavailable; is non-free-firmware in COMPONENTS?"
fi

log "Enabling ZFS systemd units"
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
systemctl enable zfs-zed

log "Rebuilding initramfs"
# The pool key lives in /etc/zfs and is therefore pulled into the initramfs
# automatically, which is what lets the kernel mount an encrypted root after
# ZFSBootMenu has already loaded the key.
update-initramfs -c -k all

# ----------------------------------------------------------------- swap -----
if [[ "$SWAP_MODE" != "none" ]]; then
	log "Configuring swap (${SWAP_MODE})"
	apt install -y cryptsetup

	SWAP_PARTUUID="$(blkid -s PARTUUID -o value "$SWAP_DEVICE")"
	SWAP_BY_PARTUUID="/dev/disk/by-partuuid/${SWAP_PARTUUID}"

	if [[ "$SWAP_MODE" == "random" ]]; then
		# Plain dm-crypt. The 'swap' option makes cryptsetup take a fresh key
		# from the source device and run mkswap on every boot.
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	${SWAP_BY_PARTUUID}	${SWAP_RANDOM_SOURCE}	swap,cipher=${SWAP_CIPHER},size=${SWAP_KEYSIZE},discard
EOF
	else
		# Persistent LUKS2 unlocked from a keyfile on the encrypted root, so it
		# never prompts: root is already open by the time crypttab is processed.
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

# ----------------------------------------- ZFSBootMenu dataset properties ---
log "Setting ZFSBootMenu dataset properties"
# Inherited by every boot environment under ROOT, including baseline.
zfs set "org.zfsbootmenu:commandline=${KERNEL_CMDLINE}" "${POOL_NAME}/ROOT"
# Tells ZFSBootMenu which dataset holds the key material to cache, so it only
# asks for the passphrase once even when several BEs share an encryption root.
zfs set "org.zfsbootmenu:keysource=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

# ------------------------------------------------------------------ ESP -----
log "Creating vfat filesystem on the ESP and mounting /boot/efi"
mkfs.vfat -F32 -n EFI "$BOOT_DEVICE"
ESP_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE")"
echo "UUID=${ESP_UUID}	/boot/efi	vfat	defaults	0	0" >> /etc/fstab
mkdir -p /boot/efi
mount /boot/efi

# ---------------------------------------------------------- ZFSBootMenu -----
log "Installing ZFSBootMenu (${ZBM_INSTALL})"
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

	mkdir -p /etc/zfsbootmenu
	cat > /etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
  PreHooksDir: /etc/zfsbootmenu/generate-zbm.pre.d
  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d
  InitCPIO: false
Components:
  Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ${KERNEL_CMDLINE}
EOF
	generate-zbm
	# Normalise filenames so the rEFInd config below is predictable
	[[ -f /boot/efi/EFI/ZBM/vmlinuz.EFI ]] && \
		mv /boot/efi/EFI/ZBM/vmlinuz.EFI /boot/efi/EFI/ZBM/VMLINUZ.EFI
	[[ -f /boot/efi/EFI/ZBM/vmlinuz-backup.EFI ]] && \
		mv /boot/efi/EFI/ZBM/vmlinuz-backup.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	[[ -f /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI ]] || \
		cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	cd /
fi

# --------------------------------------------------------------- rEFInd -----
log "Installing and configuring rEFInd"
mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true

apt install -y refind efibootmgr
refind-install
rm -f /boot/refind_linux.conf

cat > /boot/efi/EFI/ZBM/refind_linux.conf <<EOF
"Boot default"  "${KERNEL_CMDLINE} zbm.skip"
"Boot to menu"  "${KERNEL_CMDLINE} zbm.show"
EOF

# ------------------------------------------------------------- accounts -----
log "Creating accounts"
apt install -y sudo
echo "root:${ROOT_PASSWORD}" | chpasswd

# /home/${ADMIN_USER} is already a mounted dataset, so useradd must not try to
# create it; -m simply populates the existing directory from /etc/skel.
useradd -m -d "/home/${ADMIN_USER}" -s /bin/bash \
	-c "$ADMIN_FULLNAME" -G "${ADMIN_GROUPS},sudo" "$ADMIN_USER"
echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}"
chmod 0750 "/home/${ADMIN_USER}"

# ----------------------------------------------------------- base tools -----
log "Installing base userland"
apt install -y \
	network-manager openssh-client ca-certificates \
	bash-completion less nano vim-tiny curl wget rsync \
	man-db pciutils usbutils htop zstd git gdisk cryptsetup \
	systemd-timesyncd
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

[[ -n "$EXTRA_PACKAGES" ]] && apt install -y $EXTRA_PACKAGES

# --------------------------------------------------------------- desktop ----
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

# --------------------------------------------------------------- cleanup ----
log "Cleaning up"
apt --purge autoremove -y
apt clean
CHROOT_EOF

chmod 700 /mnt/root/zbm-chroot.sh

################################################################################
# Run the chroot stage
################################################################################

log "Entering chroot"
chroot /mnt /usr/bin/env bash /root/zbm-chroot.sh

################################################################################
# Baseline boot environment
################################################################################

log "Removing installer artefacts"
rm -f /mnt/root/zbm-install.env /mnt/root/zbm-chroot.sh

if [[ "$BASELINE_MODE" != "none" ]]; then
	log "Creating factory baseline boot environment (${BASELINE_MODE})"
	zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}"

	if [[ "$BASELINE_MODE" == "clone" ]]; then
		# Cheap: shares blocks with default. The @baseline snapshot cannot be
		# destroyed while the clone exists, which is exactly the guarantee you
		# want from a factory image.
		zfs clone -o canmount=noauto -o mountpoint=/ \
			"${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" \
			"${POOL_NAME}/ROOT/${BASELINE_NAME}"
	else
		# Independent full copy: survives destruction of default entirely, at
		# the cost of a second copy of the OS.
		zfs send "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" | \
			zfs recv -u "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set canmount=noauto "${POOL_NAME}/ROOT/${BASELINE_NAME}"
		zfs set mountpoint=/    "${POOL_NAME}/ROOT/${BASELINE_NAME}"
	fi
fi

################################################################################
# Finish
################################################################################

log "Final dataset layout"
zfs list -o name,used,refer,mountpoint,canmount -r "$POOL_NAME"

log "Unmounting and exporting the pool"
umount -n -R /mnt || {
	warn "Lazy-unmounting stragglers"
	umount -n -R -l /mnt || true
}
sleep 2
zpool export "$POOL_NAME"

log "Done"
cat <<EOF

Installation complete. Remove the live medium and reboot.

Boot chain:  firmware -> rEFInd -> ZFSBootMenu -> ${POOL_NAME}/ROOT/${BE_NAME}

  - rEFInd shows two ZBM images: VMLINUZ.EFI and VMLINUZ-BACKUP.EFI.
  - "Boot default" passes zbm.skip and goes straight to the active BE;
    "Boot to menu" passes zbm.show to land in ZFSBootMenu.
  - Enter your ZFS passphrase to unlock ${POOL_NAME}.
$( [[ "$BASELINE_MODE" != none ]] && cat <<EOB
  - ${POOL_NAME}/ROOT/${BASELINE_NAME} is selectable in ZFSBootMenu as a
    known-good factory image. Boot it if ${BE_NAME} ever breaks.
EOB
)
Log in as '${ADMIN_USER}' (sudo) or root.

Notes:
  - Swap on ${SWAP_DEVICE} is ${SWAP_MODE}-encrypted.$( [[ "$SWAP_MODE" == "random" ]] && echo " Hibernation is not possible." )
  - Per-user home datasets: create with
      zfs create -o mountpoint=/home/NAME ${POOL_NAME}/data/home/NAME
    before running useradd -m -d /home/NAME NAME
  - The container/VM datasets exist but the daemons are not installed. Install
    docker.io / podman / libvirt-daemon-system / lxc when you need them; they
    will land on their own datasets.
  - Refresh ZFSBootMenu later with:
      curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
    keeping VMLINUZ-BACKUP.EFI as the known-good image.
  - Pool created with $( [[ -n "$POOL_COMPAT" ]] && echo "compatibility=${POOL_COMPAT}" || echo "no compatibility pin (all 2.3 features enabled)" ).

Upgrading to OpenZFS 2.4.x from ${SUITE}-backports, in this order:

  1. Install the newer ZFS and rebuild the initramfs:
       sudo apt install -t ${SUITE}-backports zfs-dkms zfsutils-linux zfs-initramfs
       sudo update-initramfs -c -k all
     Reboot and confirm: zfs version   (both userland and kmod should be 2.4.x)

  2. Refresh ZFSBootMenu to an image built against 2.4 BEFORE upgrading the
     pool. Check https://github.com/zbm-dev/zfsbootmenu/releases for which ZFS
     version the release embeds, then:
       sudo curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
     Leave VMLINUZ-BACKUP.EFI alone as the known-good fallback.

  3. Reboot through the NEW ZBM image and confirm it still imports ${POOL_NAME}
     and boots. Only once that works:
       sudo zpool upgrade ${POOL_NAME}

  Step 2 before step 3 is not optional. 'zpool upgrade' is irreversible, and a
  ZBM image that predates a newly enabled feature flag cannot import the pool,
  which leaves you booting a rescue ISO to recover.

  If you would rather build ZBM from source against your own 2.4 packages,
  reinstall with ZBM_INSTALL=source, or run 'generate-zbm' after installing the
  build dependencies listed in this script.

EOF
