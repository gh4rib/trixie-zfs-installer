#!/usr/bin/env bash
#
#==============================================================================
# debian13-zbm-install-testing.sh
#
#   Debian 13 (Trixie), root on encrypted ZFS, rEFInd -> ZFSBootMenu.
#   TESTING VARIANT: installs every ZFSBootMenu binary image you ask for
#   (release + recovery, Linux 6.6 / 6.12 / 6.18) side by side, plus a backup
#   copy of each release image, so you can find out empirically which one
#   drives your hardware.
#==============================================================================
#
# Based on:
#   https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html
#   (encrypted variant, rEFInd boot-entry variant)
#
# Guide steps are tagged [GUIDE]; departures are tagged [DEVIATION].
#
#------------------------------------------------------------------------------
# WHICH IMAGE IS THE RIGHT ONE? THAT IS YOUR JOB.
#------------------------------------------------------------------------------
# All ZFSBootMenu v3.1.0 binary images embed the SAME OpenZFS (2.4.0). The only
# difference between the 6.6, 6.12 and 6.18 builds is the Linux kernel, i.e.
# HARDWARE SUPPORT -- NVMe controllers, RAID HBAs, GPUs, USB controllers.
# Picking a different kernel does NOT change ZFS capability or feature-flag
# compatibility.
#
# So: install several, boot each once, and keep whichever reaches the menu
# fastest and most reliably. This script deliberately makes no claim about
# which will work on your machine, and none of them is marked "correct".
#
#   release  = normal ZFSBootMenu image
#   recovery = same, plus networking, curl, sgdisk, cryptsetup, an SSH client.
#              This is the one that turns "go find a live USB" into
#              "pick the next menu entry". Install at least one.
#   backup   = byte-identical copy of each release image, kept in its own
#              directory so a botched in-place update cannot take out both.
#
#------------------------------------------------------------------------------
# ESP LAYOUT (this is what makes rEFInd behave)
#------------------------------------------------------------------------------
# rEFInd auto-detects files named vmlinuz*/bzImage*/kernel* as Linux kernels,
# and fold_linux_kernels (default true) collapses every kernel found IN THE
# SAME DIRECTORY into ONE menu tag -- picking as primary whichever filename
# version-sorts highest. That is why an install with VMLINUZ.EFI and
# VMLINUZ-BACKUP.EFI in one directory shows only the backup: "-BACKUP" sorts
# above the empty string.
#
# Folding is per-directory, so one directory per image sidesteps it entirely
# while keeping the vmlinuz name that triggers autodetection:
#
#   /boot/efi/EFI/ZBM-6.6/vmlinuz.EFI            + refind_linux.conf
#   /boot/efi/EFI/ZBM-6.12/vmlinuz.EFI           + refind_linux.conf
#   /boot/efi/EFI/ZBM-6.18/vmlinuz.EFI           + refind_linux.conf
#   /boot/efi/EFI/ZBM-RECOVERY-6.6/vmlinuz.EFI   + refind_linux.conf
#   /boot/efi/EFI/ZBM-RECOVERY-6.12/vmlinuz.EFI  + refind_linux.conf
#   /boot/efi/EFI/ZBM-RECOVERY-6.18/vmlinuz.EFI  + refind_linux.conf
#   /boot/efi/EFI/ZBM-BACKUP/vmlinuz-6.6.EFI
#                            vmlinuz-6.12.EFI    + refind_linux.conf
#                            vmlinuz-6.18.EFI
#
# The backups DO share a directory on purpose: they fold into a single tag so
# they do not clutter the menu. Press F2 or Insert on that entry to reach the
# individual ones.
#
#------------------------------------------------------------------------------
# Disk layout on $DISK (a /dev/disk/by-id/... path; GPT, fully wiped)
#------------------------------------------------------------------------------
#   -part1   2048 MiB (default)   ef00   ESP -> /boot/efi
#   -part2   1024 MiB             8309   encrypted swap, random key per boot
#   -part3   rest - 10 MiB        bf00   zroot
#
#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
#   sudo -i
#   DISK=/dev/disk/by-id/nvme-... ZBM_KERNELS=all ADMIN_USER=alireza \
#   TIMEZONE=Europe/Berlin DESKTOP=kde ./debian13-zbm-install-testing.sh
#
# Run with DISK unset to list candidate disks.
# Run with LIST_KEYBOARD=yes to list keyboard variants for your layout.
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
# CONFIGURATION
#==============================================================================

#--- Target disk (REQUIRED, /dev/disk/by-id/... whole-disk path) --------------
DISK="${DISK:-}"

#--- ZFSBootMenu image selection ----------------------------------------------
# Pinned, not "latest": a testing rig should be reproducible.
ZBM_VERSION="${ZBM_VERSION:-v3.1.0}"
ZBM_BASE_URL="${ZBM_BASE_URL:-https://github.com/zbm-dev/zfsbootmenu/releases/download}"

# Which Linux kernel series to install images for.
#   all            -> 6.6 6.12 6.18
#   "6.12"         -> just that one
#   "6.6 6.18"     -> any space-separated subset
ZBM_KERNELS="${ZBM_KERNELS:-all}"

# Install the recovery build alongside each release build. Strongly recommended:
# the recovery image has networking and disk tooling and can rescue the system
# without a live USB.
ZBM_RECOVERY="${ZBM_RECOVERY:-yes}"

# Keep a second copy of every release image under EFI/ZBM-BACKUP.
ZBM_BACKUP="${ZBM_BACKUP:-yes}"

# Which release image is copied to EFI/BOOT/BOOTX64.EFI as the removable-media
# fallback, for firmware that silently drops NVRAM boot entries. Must be one of
# the kernels you selected. Empty disables the fallback.
ZBM_FALLBACK_KERNEL="${ZBM_FALLBACK_KERNEL:-6.12}"

#--- rEFInd -------------------------------------------------------------------
# 30 seconds is long enough to read the menu and pick an image deliberately.
# Use 0 if you want rEFInd to wait indefinitely instead.
REFIND_TIMEOUT="${REFIND_TIMEOUT:-30}"
# Left EMPTY on purpose: no image is nominated as "the" default, so rEFInd
# highlights the first entry and lets you choose. Once you know which image
# your hardware likes, set this to a substring of its title, e.g.
# REFIND_DEFAULT="ZBM-6.12", or edit refind.conf afterwards.
REFIND_DEFAULT="${REFIND_DEFAULT:-}"

#--- Kernel command lines -----------------------------------------------------
# ZBM_CMDLINE     configures ZFSBootMenu's OWN kernel (via refind_linux.conf).
# KERNEL_CMDLINE  is org.zfsbootmenu:commandline, i.e. what ZBM hands to Debian.
# Both verbose: 'quiet' appears nowhere.
ZBM_CMDLINE="${ZBM_CMDLINE:-loglevel=6}"
KERNEL_CMDLINE="${KERNEL_CMDLINE:-loglevel=6 systemd.show_status=yes}"
# Seconds ZFSBootMenu waits on its own countdown before booting bootfs.
# 0 boots immediately, -1 waits forever.
ZBM_TIMEOUT="${ZBM_TIMEOUT:-30}"

#--- Partition sizes (MiB) ----------------------------------------------------
# 2048 by default: nine ZBM images run to roughly 650 MB, and you want headroom
# to add more without repartitioning.
ESP_SIZE_MIB="${ESP_SIZE_MIB:-2048}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"

#--- Swap ---------------------------------------------------------------------
# Plain dm-crypt, fresh random key every boot; nothing survives a reboot, so
# hibernation is impossible. (A per-boot random key cannot be LUKS: LUKS needs
# a persistent header with keyslots.)
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

#--- ZFS ----------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-zroot}"
BE_NAME="${BE_NAME:-default}"
BASELINE_NAME="${BASELINE_NAME:-baseline}"
BASELINE_MODE="${BASELINE_MODE:-clone}"     # clone | send | none
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-aes-256-gcm}"
DATASET_TUNING="${DATASET_TUNING:-yes}"

#--- Identity -----------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian-zbm}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
ADMIN_GROUPS="${ADMIN_GROUPS:-adm,cdrom,dip,plugdev,users,audio,video,netdev,lpadmin}"

#--- Locale / time / keyboard -------------------------------------------------
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"

#--- Debian sources -----------------------------------------------------------
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"
# non-free is included here (not just non-free-firmware): it is what provides
# intel-media-va-driver-non-free and similar.
COMPONENTS="${COMPONENTS:-main contrib non-free non-free-firmware}"

ENABLE_UPDATES="${ENABLE_UPDATES:-yes}"       # ${SUITE}-updates
ENABLE_SECURITY="${ENABLE_SECURITY:-yes}"     # ${SUITE}-security
ENABLE_BACKPORTS="${ENABLE_BACKPORTS:-no}"    # enable later, by hand
# ${SUITE}-proposed-updates holds packages QUEUED FOR THE NEXT POINT RELEASE.
# Unlike backports it has NORMAL priority, so enabling it means apt WILL pull
# from it on the next upgrade. That is the point of a testing rig, but know
# what you are switching on.
ENABLE_PROPOSED_UPDATES="${ENABLE_PROPOSED_UPDATES:-no}"

INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

#--- Desktop ------------------------------------------------------------------
DESKTOP="${DESKTOP:-kde}"                 # kde | gnome | none
DESKTOP_SIZE="${DESKTOP_SIZE:-minimal}"   # minimal | full
# The "works like a normal desktop" layer: audio, bluetooth, printing, mounting,
# codecs, fonts, archives, firmware updates. Debian does not pull these in with
# a bare DE metapackage the way Ubuntu's desktop task does.
DESKTOP_EXTRAS="${DESKTOP_EXTRAS:-yes}"
INSTALL_MEDIA_ACCEL="${INSTALL_MEDIA_ACCEL:-yes}"   # VA-API / VDPAU / Vulkan
INSTALL_FLATPAK="${INSTALL_FLATPAK:-no}"
INSTALL_OFFICE="${INSTALL_OFFICE:-no}"
INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-no}"

#--- Passwords (prompted if unset) --------------------------------------------
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ZFS_PASSPHRASE="${ZFS_PASSPHRASE:-}"

#--- Misc ---------------------------------------------------------------------
FORCE="${FORCE:-no}"
HOSTID="${HOSTID:-0x00bab10c}"

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
case "$BASELINE_MODE" in clone|send|none)  ;; *) die "BASELINE_MODE must be clone, send or none." ;; esac

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	die "ADMIN_USER '${ADMIN_USER}' is not a valid Unix username."
fi
if [[ "$ADMIN_USER" == "root" ]]; then
	die "ADMIN_USER cannot be root."
fi

#--- Resolve the kernel selection ---------------------------------------------
ZBM_ALL_KERNELS="6.6 6.12 6.18"
if [[ "$ZBM_KERNELS" == "all" ]]; then
	ZBM_KERNEL_LIST="$ZBM_ALL_KERNELS"
else
	ZBM_KERNEL_LIST="$ZBM_KERNELS"
fi

SELECTED_KERNELS=()
for k in $ZBM_KERNEL_LIST; do
	case " $ZBM_ALL_KERNELS " in
		*" $k "*) SELECTED_KERNELS+=("$k") ;;
		*) die "ZBM_KERNELS: '${k}' is not one of: ${ZBM_ALL_KERNELS} (or 'all')." ;;
	esac
done
(( ${#SELECTED_KERNELS[@]} > 0 )) || die "ZBM_KERNELS selected nothing."

if [[ -n "$ZBM_FALLBACK_KERNEL" ]]; then
	_found=no
	for k in "${SELECTED_KERNELS[@]}"; do
		[[ "$k" == "$ZBM_FALLBACK_KERNEL" ]] && _found=yes
	done
	if [[ "$_found" != yes ]]; then
		warn "ZBM_FALLBACK_KERNEL=${ZBM_FALLBACK_KERNEL} was not selected; using ${SELECTED_KERNELS[0]}."
		ZBM_FALLBACK_KERNEL="${SELECTED_KERNELS[0]}"
	fi
fi

#--- ESP capacity sanity check ------------------------------------------------
# Observed v3.1.0 sizes: release images run 60-70 MB, recovery images 77-84 MB.
N_KERNELS=${#SELECTED_KERNELS[@]}
EST_MIB=$(( N_KERNELS * 70 ))
[[ "$ZBM_BACKUP"   == "yes" ]] && EST_MIB=$(( EST_MIB + N_KERNELS * 70 ))
[[ "$ZBM_RECOVERY" == "yes" ]] && EST_MIB=$(( EST_MIB + N_KERNELS * 85 ))
[[ -n "$ZBM_FALLBACK_KERNEL" ]] && EST_MIB=$(( EST_MIB + 70 ))
EST_MIB=$(( EST_MIB + 60 ))   # rEFInd, FAT overhead, slack

if (( ESP_SIZE_MIB < EST_MIB )); then
	die "ESP_SIZE_MIB=${ESP_SIZE_MIB} is too small for this selection (~${EST_MIB} MiB needed). Raise it."
fi

#--- Keyboard / locale / timezone validation ----------------------------------
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

#--- Partition devices --------------------------------------------------------
BOOT_PART=1
SWAP_PART=2
POOL_PART=3
if (( SWAP_SIZE_MIB <= 0 )); then
	POOL_PART=2
fi
BOOT_DEVICE="${DISK}-part${BOOT_PART}"
SWAP_DEVICE="${DISK}-part${SWAP_PART}"
POOL_DEVICE="${DISK}-part${POOL_PART}"

KEYFILE="/etc/zfs/${POOL_NAME}.key"

log "Planned configuration"
cat <<EOF
  Disk             : ${DISK}
                     -> ${DISK_REAL}  ($(lsblk -dno SIZE,MODEL "$DISK_REAL"))
  ESP              : ${BOOT_DEVICE}   ${ESP_SIZE_MIB} MiB  vfat  /boot/efi
                     (~${EST_MIB} MiB will be used by ZBM images)
  Swap             : $( (( SWAP_SIZE_MIB > 0 )) && echo "${SWAP_DEVICE}   ${SWAP_SIZE_MIB} MiB  plain dm-crypt, random key" || echo "disabled" )
  Pool vdev        : ${POOL_DEVICE}
  Pool             : ${POOL_NAME}  ashift=${ASHIFT}  compression=${COMPRESSION}
  Encryption       : ${ENCRYPTION_ALGO}, native, passphrase (mandatory)
  Boot environment : ${POOL_NAME}/ROOT/${BE_NAME}
  Baseline BE      : $( [[ "$BASELINE_MODE" == none ]] && echo "disabled" || echo "${POOL_NAME}/ROOT/${BASELINE_NAME} (${BASELINE_MODE})" )

  ZFSBootMenu      : ${ZBM_VERSION}
    kernels        : ${SELECTED_KERNELS[*]}
    release images : yes  (EFI/ZBM-<ver>/vmlinuz.EFI)
    recovery images: ${ZBM_RECOVERY}  (EFI/ZBM-RECOVERY-<ver>/vmlinuz.EFI)
    backup copies  : ${ZBM_BACKUP}  (EFI/ZBM-BACKUP/vmlinuz-<ver>.EFI)
    BOOTX64 fallback: ${ZBM_FALLBACK_KERNEL:-disabled}
  rEFInd           : timeout ${REFIND_TIMEOUT} $( [[ "$REFIND_TIMEOUT" == 0 ]] && echo "(waits for you; nothing auto-boots)" ), default_selection $( [[ -n "$REFIND_DEFAULT" ]] && echo "'${REFIND_DEFAULT}'" || echo "not set" )
  ZBM cmdline      : ${ZBM_CMDLINE}   (countdown ${ZBM_TIMEOUT}s)
  Debian cmdline   : ${KERNEL_CMDLINE}

  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}
  Desktop          : ${DESKTOP} (${DESKTOP_SIZE})  extras=${DESKTOP_EXTRAS}
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : layout=${KEYMAP} variant=$( [[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none, standard layout)" )
  Components       : ${COMPONENTS}
  Suites           : ${SUITE}$( [[ "$ENABLE_UPDATES" == yes ]] && echo " +updates" )$( [[ "$ENABLE_SECURITY" == yes ]] && echo " +security" )$( [[ "$ENABLE_BACKPORTS" == yes ]] && echo " +backports" )$( [[ "$ENABLE_PROPOSED_UPDATES" == yes ]] && echo " +proposed-updates" )
EOF

if [[ "$ENABLE_PROPOSED_UPDATES" == "yes" ]]; then
	warn "${SUITE}-proposed-updates is enabled. It has NORMAL apt priority, so"
	warn "packages queued for the next point release WILL be installed on upgrade."
fi

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
	echo "  Typed inside ZFSBootMenu at every boot, on a basic keymap."
	echo "  Prefer unshifted ASCII you can find blind."
	prompt_pass ZFS_PASSPHRASE "ZFS pool passphrase" 8
fi

#==============================================================================
# APT source generation (shared by live environment and target)
#==============================================================================

# Emits a classic one-line-per-entry sources.list to stdout.
#   $1 = "live" (no deb-src, keeps the live ISO fast) or "target"
gen_sources() {
	local mode="$1"
	echo "deb ${MIRROR} ${SUITE} ${COMPONENTS}"
	[[ "$mode" == "target" ]] && echo "deb-src ${MIRROR} ${SUITE} ${COMPONENTS}"

	if [[ "$ENABLE_UPDATES" == "yes" ]]; then
		echo
		echo "# Point-release updates"
		echo "deb ${MIRROR} ${SUITE}-updates ${COMPONENTS}"
		[[ "$mode" == "target" ]] && echo "deb-src ${MIRROR} ${SUITE}-updates ${COMPONENTS}"
	fi

	if [[ "$ENABLE_SECURITY" == "yes" ]]; then
		echo
		echo "# Security updates"
		echo "deb ${SECURITY_MIRROR} ${SUITE}-security ${COMPONENTS}"
		[[ "$mode" == "target" ]] && echo "deb-src ${SECURITY_MIRROR} ${SUITE}-security ${COMPONENTS}"
	fi

	if [[ "$ENABLE_PROPOSED_UPDATES" == "yes" ]]; then
		echo
		echo "# Queued for the next point release. NORMAL priority: apt will use it."
		echo "deb ${MIRROR} ${SUITE}-proposed-updates ${COMPONENTS}"
		[[ "$mode" == "target" ]] && echo "deb-src ${MIRROR} ${SUITE}-proposed-updates ${COMPONENTS}"
	fi

	if [[ "$ENABLE_BACKPORTS" == "yes" ]]; then
		echo
		echo "# Backports. LOW priority: nothing installs from here unless you"
		echo "# ask, e.g. apt install -t ${SUITE}-backports zfs-dkms"
		echo "deb ${MIRROR} ${SUITE}-backports ${COMPONENTS}"
		[[ "$mode" == "target" ]] && echo "deb-src ${MIRROR} ${SUITE}-backports ${COMPONENTS}"
	fi
	return 0
}

#==============================================================================
# [GUIDE] Configure Live Environment
#==============================================================================

log "Configuring APT in the live environment"
gen_sources live > /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/debian.sources
export DEBIAN_FRONTEND=noninteractive
apt update

log "Installing ZFS and helpers in the live environment (DKMS build, be patient)"
apt install -y debootstrap gdisk dkms "linux-headers-$(uname -r)" cryptsetup curl ca-certificates
apt install -y zfsutils-linux zfs-dkms
modprobe zfs || die "zfs module failed to load in the live environment."

# [GUIDE] Generate /etc/hostid
log "Generating /etc/hostid"
zgenhostid -f "$HOSTID"

#==============================================================================
# [GUIDE] Disk preparation
#==============================================================================

# A pool of the same name already imported in the live environment would make
# every later "zpool export/import ${POOL_NAME}" ambiguous, and could have the
# script operate on the wrong pool entirely.
log "Checking for an already-imported pool named ${POOL_NAME}"
if zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"; then
	echo >&2
	warn "A pool named '${POOL_NAME}' is ALREADY IMPORTED in this live environment."
	warn "Export it first:   zpool export ${POOL_NAME}"
	warn "or re-run with a different name, e.g.   POOL_NAME=zzroot"
	die "Refusing to continue with an ambiguous pool name."
fi

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
	sgdisk -n "${SWAP_PART}:0:+${SWAP_SIZE_MIB}m" -t "${SWAP_PART}:8309" -c "${SWAP_PART}:swap" "$DISK"
fi
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
# Pool name collision check
#==============================================================================

# Run AFTER the wipe on purpose: any previous pool on the target disk is gone
# by now, so anything still found lives on a DIFFERENT disk and is a genuine
# conflict rather than a leftover of the install we are replacing.
log "Checking other disks for a pool named ${POOL_NAME}"
OTHER_POOL=no
if zpool import 2>/dev/null | awk '$1 == "pool:" { print $2 }' | grep -qx "$POOL_NAME"; then
	OTHER_POOL=yes
	echo >&2
	warn "Another pool named '${POOL_NAME}' exists on this machine, on a different disk."
	warn ""
	warn "The install itself is safe: the new pool is imported by GUID with the"
	warn "search restricted to ${POOL_DEVICE}, so the other pool is never touched."
	warn ""
	warn "The problem is later. ZFS cannot have two pools of the same name imported"
	warn "at once, so at boot ZFSBootMenu will see both and can only use one. Renaming"
	warn "a root pool afterwards is awkward."
	warn ""
	warn "Strongly recommended: abort and re-run with a unique name, e.g."
	warn "    POOL_NAME=zzroot ${0##*/} ..."
	if [[ "$FORCE" != "yes" ]]; then
		echo
		read -rp "Continue anyway with POOL_NAME=${POOL_NAME}? Type YES to proceed: " _pc
		[[ "$_pc" == "YES" ]] || die "Aborted. Re-run with a different POOL_NAME."
	fi
fi

#==============================================================================
# [GUIDE] ZFS pool creation (encrypted variant)
#==============================================================================

# [GUIDE] The guide's encrypted zpool create references this key file as
# "created in a previous step", but never shows that step.
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
zpool create "${zpool_opts[@]}" -m none "$POOL_NAME" "$POOL_DEVICE"

# A pool's GUID is unique and unambiguous where its name is not. Everything
# below re-imports by GUID so the script can never grab a same-named pool that
# happens to live on another disk.
POOL_GUID="$(zpool get -H -o value guid "$POOL_NAME")"
[[ -n "$POOL_GUID" ]] || die "Could not read the GUID of the new pool."
echo "  pool GUID: ${POOL_GUID}"

#------------------------------------------------------------------------------
# [GUIDE] Create initial file systems
# "canmount is not inheritable ... It is necessary to explicitly set
#  canmount=noauto on every boot environment you create."
#------------------------------------------------------------------------------

log "Creating boot environment datasets"
zfs create -o mountpoint=none -o canmount=off    "${POOL_NAME}/ROOT"
zfs create -o mountpoint=/    -o canmount=noauto "${POOL_NAME}/ROOT/${BE_NAME}"
zpool set "bootfs=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

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
	zfs set atime=off                       "${POOL_NAME}/data/var"
	zfs set setuid=off devices=off          "${POOL_NAME}/data/var/tmp"
	zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
	zfs set recordsize=64K                  "${POOL_NAME}/data/var/lib/libvirt"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/containers"
	zfs set recordsize=32K                  "${POOL_NAME}/data/var/lib/docker"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/docker"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/containers"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/lxc"
	zfs set com.sun:auto-snapshot=false     "${POOL_NAME}/data/var/lib/libvirt"
fi

log "Exporting and re-importing at /mnt"
zpool export "$POOL_NAME"

# [DEVIATION] The guide does: zpool import -N -R /mnt zroot
# Importing by NAME picks whichever pool of that name the scan finds first,
# which is a coin toss when a second pool shares the name -- and the failure
# mode is importing, and then installing over, the wrong pool.
#
# Two changes make this deterministic:
#   -d "$POOL_DEVICE"  restricts the device scan to the partition just created
#   "$POOL_GUID"       identifies the pool by its unique GUID, not its name
zpool import -N -R /mnt -d "$POOL_DEVICE" "$POOL_GUID"

# Confirm we imported OUR pool and not something else.
IMPORTED_GUID="$(zpool get -H -o value guid "$POOL_NAME" 2>/dev/null || true)"
if [[ "$IMPORTED_GUID" != "$POOL_GUID" ]]; then
	die "Imported pool GUID '${IMPORTED_GUID}' does not match the pool just created ('${POOL_GUID}')."
fi

zfs load-key "$POOL_NAME"
zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"
zfs mount -a

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

#==============================================================================
# Write configuration + chroot script
#==============================================================================

log "Writing chroot payload"

gen_sources target > /mnt/root/sources.list.new

{
	printf 'POOL_NAME=%q\n'              "$POOL_NAME"
	printf 'BE_NAME=%q\n'                "$BE_NAME"
	printf 'KEYFILE=%q\n'                "$KEYFILE"
	printf 'TARGET_HOSTNAME=%q\n'        "$TARGET_HOSTNAME"
	printf 'ADMIN_USER=%q\n'             "$ADMIN_USER"
	printf 'ADMIN_FULLNAME=%q\n'         "$ADMIN_FULLNAME"
	printf 'ADMIN_GROUPS=%q\n'           "$ADMIN_GROUPS"
	printf 'ROOT_PASSWORD=%q\n'          "$ROOT_PASSWORD"
	printf 'ADMIN_PASSWORD=%q\n'         "$ADMIN_PASSWORD"
	printf 'TIMEZONE=%q\n'               "$TIMEZONE"
	printf 'LOCALE=%q\n'                 "$LOCALE"
	printf 'KEYMAP=%q\n'                 "$KEYMAP"
	printf 'KEYBOARD_VARIANT=%q\n'       "$KEYBOARD_VARIANT"
	printf 'SUITE=%q\n'                  "$SUITE"
	printf 'INSTALL_FIRMWARE=%q\n'       "$INSTALL_FIRMWARE"
	printf 'EXTRA_PACKAGES=%q\n'         "$EXTRA_PACKAGES"
	printf 'DESKTOP=%q\n'                "$DESKTOP"
	printf 'DESKTOP_SIZE=%q\n'           "$DESKTOP_SIZE"
	printf 'DESKTOP_EXTRAS=%q\n'         "$DESKTOP_EXTRAS"
	printf 'INSTALL_MEDIA_ACCEL=%q\n'    "$INSTALL_MEDIA_ACCEL"
	printf 'INSTALL_FLATPAK=%q\n'        "$INSTALL_FLATPAK"
	printf 'INSTALL_OFFICE=%q\n'         "$INSTALL_OFFICE"
	printf 'INSTALL_UNATTENDED_UPGRADES=%q\n' "$INSTALL_UNATTENDED_UPGRADES"
	printf 'BOOT_DEVICE=%q\n'            "$BOOT_DEVICE"
	printf 'SWAP_DEVICE=%q\n'            "$SWAP_DEVICE"
	printf 'SWAP_SIZE_MIB=%q\n'          "$SWAP_SIZE_MIB"
	printf 'SWAP_RANDOM_SOURCE=%q\n'     "$SWAP_RANDOM_SOURCE"
	printf 'SWAP_CIPHER=%q\n'            "$SWAP_CIPHER"
	printf 'SWAP_KEYSIZE=%q\n'           "$SWAP_KEYSIZE"
	printf 'SWAP_MAPPER=%q\n'            "$SWAP_MAPPER"
	printf 'ZBM_VERSION=%q\n'            "$ZBM_VERSION"
	printf 'ZBM_BASE_URL=%q\n'           "$ZBM_BASE_URL"
	printf 'ZBM_KERNEL_LIST=%q\n'        "${SELECTED_KERNELS[*]}"
	printf 'ZBM_RECOVERY=%q\n'           "$ZBM_RECOVERY"
	printf 'ZBM_BACKUP=%q\n'             "$ZBM_BACKUP"
	printf 'ZBM_FALLBACK_KERNEL=%q\n'    "$ZBM_FALLBACK_KERNEL"
	printf 'ZBM_CMDLINE=%q\n'            "$ZBM_CMDLINE"
	printf 'ZBM_TIMEOUT=%q\n'            "$ZBM_TIMEOUT"
	printf 'KERNEL_CMDLINE=%q\n'         "$KERNEL_CMDLINE"
	printf 'REFIND_DEFAULT=%q\n'         "$REFIND_DEFAULT"
	printf 'REFIND_TIMEOUT=%q\n'         "$REFIND_TIMEOUT"
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

# Install only the packages that actually exist in the archive. Debian renames
# and splits packages between releases (firmware and font packages especially),
# and one bad name would otherwise abort the whole apt run.
apt_install_available() {
	local label="$1"; shift
	local avail=() p
	for p in "$@"; do
		if apt-cache show "$p" >/dev/null 2>&1; then
			avail+=("$p")
		else
			echo "    skip (not in archive): ${p}"
		fi
	done
	if (( ${#avail[@]} > 0 )); then
		echo "    installing ${label}: ${avail[*]}"
		apt install -y "${avail[@]}" || warn "Some ${label} packages failed to install."
	fi
	return 0
}

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
mv /root/sources.list.new /etc/apt/sources.list
cat /etc/apt/sources.list
apt update

#--- [GUIDE] Locale, timezone, keyboard ---------------------------------------
log "Configuring locale, timezone and keyboard"
apt install -y locales keyboard-configuration console-setup tzdata

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
dpkg-reconfigure -f noninteractive tzdata
dpkg-reconfigure -f noninteractive keyboard-configuration console-setup

#--- [GUIDE] Kernel and ZFS ---------------------------------------------------
log "Installing kernel and ZFS"
mkdir -p /etc/dkms
apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs dosfstools
apt install -y zfs-zed
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

#--- Microcode and firmware ---------------------------------------------------
if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	log "Installing CPU microcode"
	CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo || true)"
	case "$CPU_VENDOR" in
		GenuineIntel) apt install -y intel-microcode ;;
		AuthenticAMD) apt install -y amd64-microcode ;;
		*) warn "Unrecognised CPU vendor '${CPU_VENDOR}'; installing both."
		   apt install -y intel-microcode amd64-microcode || true ;;
	esac

	log "Installing device firmware"
	# firmware-linux covers graphics/misc only; wireless/sound/NIC firmware are
	# separate packages nothing depends on, so an Intel wifi laptop has no
	# network at all unless firmware-iwlwifi is named explicitly.
	apt_install_available "firmware" \
		firmware-linux firmware-linux-free firmware-linux-nonfree \
		firmware-misc-nonfree \
		firmware-iwlwifi firmware-realtek firmware-atheros \
		firmware-brcm80211 firmware-libertas firmware-ti-connectivity \
		firmware-zd1211 firmware-mediatek firmware-marvell-prestera \
		firmware-sof-signed firmware-intel-sound \
		firmware-amd-graphics firmware-intel-graphics firmware-nvidia-graphics \
		firmware-bnx2 firmware-bnx2x firmware-qlogic firmware-cavium
	apt_install_available "wireless tooling" \
		wireless-regdb iw rfkill wpasupplicant
fi

#--- [GUIDE] ZFS systemd services ---------------------------------------------
log "Enabling ZFS systemd units"
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
systemctl enable zfs-zed

#--- [GUIDE] Rebuild the initramfs --------------------------------------------
# The pool key lives in /etc/zfs and is therefore pulled into the initramfs
# automatically, which is what lets the kernel mount an encrypted root after
# ZFSBootMenu has already loaded the key.
log "Rebuilding initramfs"
update-initramfs -c -k all

#--- Encrypted swap -----------------------------------------------------------
if (( SWAP_SIZE_MIB > 0 )); then
	log "Configuring encrypted swap (random key per boot)"
	apt install -y cryptsetup
	SWAP_PARTUUID="$(blkid -s PARTUUID -o value "$SWAP_DEVICE")"
	cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	/dev/disk/by-partuuid/${SWAP_PARTUUID}	${SWAP_RANDOM_SOURCE}	swap,cipher=${SWAP_CIPHER},size=${SWAP_KEYSIZE},discard
EOF
	echo "/dev/mapper/${SWAP_MAPPER}	none	swap	sw	0	0" >> /etc/fstab
fi
# Nothing on a random-key swap survives a reboot, so resuming is impossible.
# Without this the boot hangs for 30s waiting for a resume device.
mkdir -p /etc/initramfs-tools/conf.d
echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume

#--- [GUIDE] ZFSBootMenu dataset properties -----------------------------------
log "Setting ZFSBootMenu dataset properties"

# Hostid is left entirely to ZFSBootMenu. zbm.set_hostid is enabled by default
# and makes ZBM set spl.spl_hostid for the booted environment to the hostid it
# actually imported the pool with; it also strips any spl_hostid set here. The
# thing that matters on Debian is /etc/hostid inside the initramfs, which
# zgenhostid + the copy into /etc before update-initramfs already provides.
zfs set "org.zfsbootmenu:commandline=${KERNEL_CMDLINE}" "${POOL_NAME}/ROOT"
zfs set "org.zfsbootmenu:keysource=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"
zfs get -o property,value org.zfsbootmenu:commandline "${POOL_NAME}/ROOT"

#--- [GUIDE] ESP filesystem and mount -----------------------------------------
log "Creating vfat filesystem on the ESP and mounting /boot/efi"
mkfs.vfat -F32 -n EFI "$BOOT_DEVICE"
ESP_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE")"
echo "UUID=${ESP_UUID}	/boot/efi	vfat	defaults	0	0" >> /etc/fstab
mkdir -p /boot/efi
mount /boot/efi

#==============================================================================
# ZFSBootMenu images
#==============================================================================

log "Downloading ZFSBootMenu ${ZBM_VERSION} images"
apt install -y curl ca-certificates

# fetch_zbm <build> <kernel> <destination>
#   build = release | recovery
fetch_zbm() {
	local build="$1" kern="$2" dest="$3"
	local fname="zfsbootmenu-${build}-x86_64-${ZBM_VERSION}-linux${kern}.EFI"
	local url="${ZBM_BASE_URL}/${ZBM_VERSION}/${fname}"
	local tmp="/root/${fname}"

	if [[ ! -f "$tmp" ]]; then
		echo "  fetching ${fname}"
		curl -fSL --retry 3 --retry-delay 2 -o "$tmp" "$url" \
			|| { rm -f "$tmp"; echo "download failed: $url" >&2; return 1; }
	fi

	mkdir -p "$(dirname "$dest")"
	cp "$tmp" "$dest"
	return 0
}

# Each image gets its own directory. rEFInd folds kernels only WITHIN a
# directory, so this keeps the vmlinuz name (which is what makes rEFInd
# recognise it as a Linux kernel and apply refind_linux.conf) while still
# giving every image its own top-level menu entry.
#
# write_rlc <directory> <label>
write_rlc() {
	local dir="$1" label="$2"
	cat > "${dir}/refind_linux.conf" <<EOF
"${label} - boot default"      "${ZBM_CMDLINE} zbm.timeout=${ZBM_TIMEOUT}"
"${label} - boot to menu"      "${ZBM_CMDLINE} zbm.show"
"${label} - boot immediately"  "${ZBM_CMDLINE} zbm.skip"
"${label} - verbose debug"     "loglevel=7 zbm.show"
EOF
	return 0
}

INSTALLED_IMAGES=()

for KV in $ZBM_KERNEL_LIST; do
	log "ZFSBootMenu image set for Linux ${KV}"

	# Release image -> EFI/ZBM-<ver>/vmlinuz.EFI
	if fetch_zbm release "$KV" "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI"; then
		write_rlc "/boot/efi/EFI/ZBM-${KV}" "ZBM ${KV}"
		INSTALLED_IMAGES+=("EFI/ZBM-${KV}/vmlinuz.EFI")
	else
		warn "Release image for Linux ${KV} could not be installed."
	fi

	# Recovery image -> EFI/ZBM-RECOVERY-<ver>/vmlinuz.EFI
	if [[ "$ZBM_RECOVERY" == "yes" ]]; then
		if fetch_zbm recovery "$KV" "/boot/efi/EFI/ZBM-RECOVERY-${KV}/vmlinuz.EFI"; then
			write_rlc "/boot/efi/EFI/ZBM-RECOVERY-${KV}" "ZBM RECOVERY ${KV}"
			INSTALLED_IMAGES+=("EFI/ZBM-RECOVERY-${KV}/vmlinuz.EFI")
		else
			warn "Recovery image for Linux ${KV} could not be installed."
		fi
	fi

	# Backup copy of the release image, in a shared directory. These DO fold
	# into one rEFInd tag on purpose; press F2/Insert to reach the others.
	if [[ "$ZBM_BACKUP" == "yes" ]]; then
		if [[ -f "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI" ]]; then
			mkdir -p /boot/efi/EFI/ZBM-BACKUP
			cp "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI" \
			   "/boot/efi/EFI/ZBM-BACKUP/vmlinuz-${KV}.EFI"
			INSTALLED_IMAGES+=("EFI/ZBM-BACKUP/vmlinuz-${KV}.EFI")
		fi
	fi
done

if [[ -d /boot/efi/EFI/ZBM-BACKUP ]]; then
	write_rlc /boot/efi/EFI/ZBM-BACKUP "ZBM BACKUP"
fi

if (( ${#INSTALLED_IMAGES[@]} == 0 )); then
	echo "No ZFSBootMenu images were installed. The system will not boot." >&2
	exit 1
fi

# Removable-media fallback deferred: refind-install may itself claim
# EFI/BOOT/BOOTX64.EFI, and rEFInd there is strictly better than ZBM there
# (you get the whole menu instead of one hard-wired image). Handled after
# rEFInd is installed, further down.

rm -f /root/zfsbootmenu-*.EFI

#==============================================================================
# [GUIDE] rEFInd
#==============================================================================

log "Installing and configuring rEFInd"
mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true

echo 'refind refind/install_to_esp boolean true' | debconf-set-selections
apt install -y refind efibootmgr

# Not fatal: the BOOTX64.EFI fallback may still boot the machine, and aborting
# here would leave the install with no user accounts at all.
if ! refind-install; then
	warn "refind-install FAILED. Rely on the EFI/BOOT/BOOTX64.EFI fallback,"
	warn "or repair from a live ISO."
fi

# [GUIDE] refind-install writes /boot/refind_linux.conf, which would make
# rEFInd generate entries for the Debian kernel directly and bypass
# ZFSBootMenu entirely.
rm -f /boot/refind_linux.conf

REFIND_CONF=/boot/efi/EFI/refind/refind.conf
if [[ -f "$REFIND_CONF" ]]; then
	{
		echo ""
		echo "#--- added by debian13-zbm-install-testing.sh ------------------------------"
		echo "# 0 = wait indefinitely. Nothing auto-boots: every ZFSBootMenu image is"
		echo "# listed and you choose. Set a positive number for a countdown once you"
		echo "# have decided which image to keep."
		echo "timeout ${REFIND_TIMEOUT}"
		echo ""
		echo "# Left at the default (true) deliberately. Every ZBM image lives in its"
		echo "# own directory, so folding has nothing to group -- except the backups,"
		echo "# which share EFI/ZBM-BACKUP and collapse into a single tag on purpose."
		echo "# Press F2 or Insert on that entry to reach the individual backups."
		echo "fold_linux_kernels true"
		echo ""
		echo "# EFI/BOOT is scanned too. Whatever claimed BOOTX64.EFI shows up in the"
		echo "# menu and can be tested like any other entry (rEFInd skips its own)."
		if [[ -n "$REFIND_DEFAULT" ]]; then
			echo ""
			echo "default_selection \"${REFIND_DEFAULT}\""
		else
			echo ""
			echo "# No default_selection: no image is nominated as correct. Add one"
			echo "# yourself once testing tells you which to trust, e.g."
			echo "#   default_selection \"ZBM-6.12\""
		fi
		echo "#--------------------------------------------------------------------------"
	} >> "$REFIND_CONF"
else
	warn "${REFIND_CONF} not found; rEFInd settings were not applied."
fi

#--- Removable-media fallback -------------------------------------------------
# Some firmware silently drops NVRAM boot entries and will only start
# EFI/BOOT/BOOTX64.EFI. refind-install often puts rEFInd there itself, which is
# the better outcome: you reach the full menu rather than one hard-wired image.
# So only fill the slot if it is still empty.
if [[ -e /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
	log "EFI/BOOT/BOOTX64.EFI already present (installed by refind-install); left alone"
elif [[ -n "$ZBM_FALLBACK_KERNEL" && -f "/boot/efi/EFI/ZBM-${ZBM_FALLBACK_KERNEL}/vmlinuz.EFI" ]]; then
	log "Installing EFI/BOOT/BOOTX64.EFI fallback (ZBM, Linux ${ZBM_FALLBACK_KERNEL})"
	mkdir -p /boot/efi/EFI/BOOT
	cp "/boot/efi/EFI/ZBM-${ZBM_FALLBACK_KERNEL}/vmlinuz.EFI" \
	   /boot/efi/EFI/BOOT/BOOTX64.EFI
else
	warn "No EFI/BOOT/BOOTX64.EFI fallback installed. If this machine ignores"
	warn "NVRAM boot entries it may not boot without one."
fi

#==============================================================================
# Accounts
#==============================================================================

log "Creating accounts"
apt install -y sudo
echo "root:${ROOT_PASSWORD}" | chpasswd

# /home/${ADMIN_USER} already exists as a mounted dataset. useradd -m REFUSES
# to populate a directory that already exists -- it prints "Not copying any
# file from skel directory into it" and carries on, silently leaving the
# account with no .bashrc or .profile. So use -M and copy skel by hand.
useradd -M -d "/home/${ADMIN_USER}" -s /bin/bash \
	-c "$ADMIN_FULLNAME" -G "${ADMIN_GROUPS},sudo" "$ADMIN_USER"
cp -a /etc/skel/. "/home/${ADMIN_USER}/"
echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}"
chmod 0750 "/home/${ADMIN_USER}"

if [[ ! -f "/home/${ADMIN_USER}/.bashrc" ]]; then
	warn "/home/${ADMIN_USER}/.bashrc missing -- skel copy did not work."
fi

#==============================================================================
# Base userland
#==============================================================================

log "Installing base userland"
apt install -y \
	network-manager openssh-client ca-certificates \
	bash-completion less nano vim-tiny curl wget rsync \
	man-db pciutils usbutils htop zstd git gdisk cryptsetup \
	systemd-timesyncd
apt_install_available "diagnostics" smartmontools lm-sensors plocate tree
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

if [[ -n "$EXTRA_PACKAGES" ]]; then
	# Deliberately unquoted: EXTRA_PACKAGES is a space-separated list.
	apt install -y $EXTRA_PACKAGES
fi

#==============================================================================
# Desktop
#==============================================================================

case "$DESKTOP" in
	kde)
		log "Installing KDE Plasma (${DESKTOP_SIZE})"
		if [[ "$DESKTOP_SIZE" == "full" ]]; then
			apt install -y kde-standard sddm
		else
			apt install -y kde-plasma-desktop sddm
		fi
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
		systemctl enable gdm3
		systemctl set-default graphical.target
		;;
	none)
		log "Skipping desktop install"
		systemctl set-default multi-user.target
		;;
esac

if [[ "$DESKTOP" != "none" && "$DESKTOP_EXTRAS" == "yes" ]]; then
	log "Installing desktop integration packages"

	# Everything below is something a stock Debian DE metapackage leaves out
	# but that you notice immediately when it is missing: audio routing,
	# bluetooth, printing, automounting removable media, codecs, emoji,
	# archive handling, firmware updates, power profiles.
	apt_install_available "session integration" \
		xdg-user-dirs xdg-utils xdg-desktop-portal \
		gvfs gvfs-backends gvfs-fuse udisks2 upower

	apt_install_available "audio" \
		pipewire-audio wireplumber libspa-0.2-bluetooth

	apt_install_available "bluetooth" bluez

	# Fonts, emoji and printing (cups/avahi) are deliberately NOT installed.
	# The command to add them is printed at the end of this script.

	# The rough equivalent of ubuntu-restricted-extras' codec half.
	apt_install_available "codecs" \
		gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
		gstreamer1.0-plugins-ugly gstreamer1.0-libav \
		gstreamer1.0-pipewire

	apt_install_available "archives and filesystems" \
		p7zip-full unzip zip xz-utils unrar-free \
		ntfs-3g exfatprogs dosfstools

	apt_install_available "hardware services" \
		fwupd power-profiles-daemon

	apt_install_available "browser" firefox-esr

	if [[ "$INSTALL_MEDIA_ACCEL" == "yes" ]]; then
		# Hardware video decode. intel-media-va-driver-non-free is why
		# 'non-free' (not just non-free-firmware) is in the components list.
		apt_install_available "video acceleration" \
			va-driver-all vdpau-driver-all mesa-va-drivers mesa-vdpau-drivers \
			mesa-vulkan-drivers intel-media-va-driver-non-free vainfo
	fi

	case "$DESKTOP" in
		kde)
			apt_install_available "KDE applications" \
				xdg-desktop-portal-kde ark kate okular gwenview spectacle \
				kcalc kio-extras plasma-firewall
			;;
		gnome)
			apt_install_available "GNOME applications" \
				xdg-desktop-portal-gnome gnome-tweaks dconf-editor \
				file-roller gnome-system-monitor
			;;
	esac

	if [[ "$INSTALL_FLATPAK" == "yes" ]]; then
		apt_install_available "flatpak" flatpak
		case "$DESKTOP" in
			kde)   apt_install_available "flatpak backend" plasma-discover-backend-flatpak ;;
			gnome) apt_install_available "flatpak backend" gnome-software-plugin-flatpak ;;
		esac
	fi

	if [[ "$INSTALL_OFFICE" == "yes" ]]; then
		apt_install_available "office" \
			libreoffice-writer libreoffice-calc libreoffice-impress
		case "$DESKTOP" in
			kde)   apt_install_available "office integration" libreoffice-kf6 ;;
			gnome) apt_install_available "office integration" libreoffice-gtk3 ;;
		esac
	fi
fi

if [[ "$INSTALL_UNATTENDED_UPGRADES" == "yes" ]]; then
	apt_install_available "unattended upgrades" unattended-upgrades
fi

#--- Cleanup ------------------------------------------------------------------
log "Cleaning up"
apt --purge autoremove -y
apt clean

log "ESP contents"
find /boot/efi/EFI -maxdepth 2 \( -name '*.EFI' -o -name '*.efi' \) | sort
df -h /boot/efi
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
rm -f /mnt/root/zbm-install.env /mnt/root/zbm-chroot.sh /mnt/root/sources.list.new

if [[ "$BASELINE_MODE" != "none" ]]; then
	log "Creating factory baseline boot environment (${BASELINE_MODE})"
	zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}"
	if [[ "$BASELINE_MODE" == "clone" ]]; then
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

#==============================================================================
# Finish
#==============================================================================

log "Final dataset layout"
zfs list -o name,used,refer,mountpoint,canmount -r "$POOL_NAME"

if [[ -s /mnt/root/INSTALL-WARNINGS.txt ]]; then
	echo
	warn "Warnings were recorded during installation:"
	sed 's/^/    /' /mnt/root/INSTALL-WARNINGS.txt >&2
	warn "Kept at /root/INSTALL-WARNINGS.txt on the new system."
fi

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

$( [[ "$OTHER_POOL" == yes ]] && printf '%s\n' \
"POOL NAME COLLISION -- READ THIS" \
"  Another pool named '${POOL_NAME}' exists on a different disk in this machine." \
"  Only one pool of a given name can be imported at a time, so ZFSBootMenu will" \
"  see both and use only one of them. If the wrong one wins you will not boot." \
"  Either disconnect or rename the other pool, or reinstall with a unique" \
"  POOL_NAME. To rename the OTHER pool from a live ISO:" \
"      zpool export ${POOL_NAME}" \
"      zpool import <guid-of-the-other-pool> othername" \
"" )
WHAT YOU WILL SEE
  firmware -> rEFInd -> (a ZFSBootMenu image you pick) -> ${POOL_NAME}/ROOT/${BE_NAME}

  rEFInd lists one entry per ZFSBootMenu image, plus one folded entry for the
  backups and one for the EFI/BOOT fallback copy. Nothing is marked default and
  the timeout is ${REFIND_TIMEOUT} (0 = wait forever), so the menu sits there until you
  choose. Each entry has four sub-entries (F2 or Insert to open):
      boot default      ${ZBM_TIMEOUT}s countdown, then boots bootfs
      boot to menu      always show the boot-environment selector
      boot immediately  no menu, no countdown
      verbose debug     loglevel=7, ZBM's full internal tracing

NOW GO FIND OUT WHICH IMAGE WORKS
  Kernels installed: ${SELECTED_KERNELS[*]}

  All of these embed the SAME OpenZFS. They differ only in Linux kernel, so
  the question is purely whether the kernel can see your disk controller,
  keyboard and display. Boot each once and note:

    - does it reach the ZFSBootMenu prompt at all?
    - is your keyboard usable at the passphrase prompt?
    - does it find and import ${POOL_NAME}?
    - how long does it take?

  Then pin your winner by adding a default_selection to refind.conf:
    sudo nano /boot/efi/EFI/refind/refind.conf
      default_selection "ZBM-6.12"
      timeout 5
  and, if you want the firmware fallback to match:
    sudo cp /boot/efi/EFI/ZBM-<ver>/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI

  Removing the images you rejected is just deleting their directory under
  /boot/efi/EFI/ -- rEFInd rescans the ESP on every boot, nothing to regenerate.

NOT INSTALLED, ON PURPOSE
  Fonts, emoji and printing were left out. Run these if you want them:

    # Fonts and emoji
    sudo apt install fonts-noto-core fonts-noto-color-emoji fonts-liberation2 \\
        fonts-dejavu-core fonts-hack

    # Printing, with automatic network printer discovery
    sudo apt install cups cups-filters cups-browsed avahi-daemon$( [[ "$DESKTOP" == kde ]] && echo " print-manager" )$( [[ "$DESKTOP" == gnome ]] && echo " system-config-printer" )
    sudo usermod -a -G lpadmin ${ADMIN_USER}

  ('${ADMIN_USER}' is already in lpadmin; the usermod line is for other users.)

RECOVERY IMAGES
  EFI/ZBM-RECOVERY-* include networking, curl, sgdisk and cryptsetup. Keep at
  least one even after you have picked a favourite: it is the difference
  between fixing a broken pool from the boot menu and going to find a USB
  stick.

BOOT VERBOSITY
  'quiet' is set nowhere.
    ZFSBootMenu's own kernel : ${ZBM_CMDLINE}
    Debian's kernel          : ${KERNEL_CMDLINE}

  Change Debian's verbosity without touching the bootloader:
    sudo zfs set org.zfsbootmenu:commandline="loglevel=7 systemd.show_status=yes" ${POOL_NAME}/ROOT
  Change ZFSBootMenu's own: edit the refind_linux.conf inside each
  /boot/efi/EFI/ZBM-*/ directory. No regeneration needed.

APT SUITES ENABLED
  ${SUITE}$( [[ "$ENABLE_UPDATES" == yes ]] && echo ", ${SUITE}-updates" )$( [[ "$ENABLE_SECURITY" == yes ]] && echo ", ${SUITE}-security" )$( [[ "$ENABLE_PROPOSED_UPDATES" == yes ]] && echo ", ${SUITE}-proposed-updates" )$( [[ "$ENABLE_BACKPORTS" == yes ]] && echo ", ${SUITE}-backports" )
  Components: ${COMPONENTS}

  Backports and proposed-updates are NOT enabled. Add them yourself when you
  want them:

    # Backports. LOW priority: nothing installs from it unless you ask.
    echo "deb ${MIRROR} ${SUITE}-backports ${COMPONENTS}" \\
        | sudo tee /etc/apt/sources.list.d/${SUITE}-backports.list
    sudo apt update
    # then, per package:
    sudo apt install -t ${SUITE}-backports zfs-dkms zfsutils-linux zfs-initramfs

    # Proposed-updates: packages queued for the next point release.
    # NORMAL priority -- once added, 'apt upgrade' WILL pull from it.
    echo "deb ${MIRROR} ${SUITE}-proposed-updates ${COMPONENTS}" \\
        | sudo tee /etc/apt/sources.list.d/${SUITE}-proposed-updates.list
    sudo apt update

NEW BOOT ENVIRONMENTS
  canmount is NOT inheritable. Set it explicitly or the system will try to
  mount two filesystems at / and fail to boot:
    sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade
    sudo zfs clone -o canmount=noauto -o mountpoint=/ \\
        ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade ${POOL_NAME}/ROOT/new

NEW USERS
  useradd will NOT copy /etc/skel into a home directory that already exists,
  and a per-user dataset makes it exist:
    sudo zfs create -o mountpoint=/home/NAME ${POOL_NAME}/data/home/NAME
    sudo useradd -M -d /home/NAME -s /bin/bash -G sudo NAME
    sudo cp -a /etc/skel/. /home/NAME/
    sudo chown -R NAME:NAME /home/NAME && sudo chmod 0750 /home/NAME
    sudo passwd NAME

POOL UPGRADES
  ZFSBootMenu ${ZBM_VERSION} images embed OpenZFS 2.4.0, so this pool can be
  upgraded to 2.4 feature flags and every installed image will still import it:
    sudo apt install -t ${SUITE}-backports zfs-dkms zfsutils-linux zfs-initramfs
    sudo update-initramfs -c -k all
    # reboot, confirm 'zfs version', then:
    sudo zpool upgrade ${POOL_NAME}
  If you later replace these images with an OLDER ZBM release, do it before,
  not after, any zpool upgrade.

EOF
