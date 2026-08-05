#!/bin/bash
#
# Debian 13 (Trixie) — ZFS-on-root installer (UEFI only)
#
# Layout per selected disk:
#   p1 600 MiB   EF00  EFI System Partition        -> /boot/efi (vfat)
#   p2   3 GiB   8300  /boot                       -> ext4 (mdraid1 if >1 disk)
#   p3   2 GiB   8200  swap                        -> random-key dm-crypt when encrypting
#   p4   rest    BF00  rpool                       -> ZFS, native encryption
#
# Features:
#   - No bpool: /boot is plain ext4, so rpool keeps all feature flags
#   - atime=off + relatime=off, logbias=throughput on the pool root
#   - Optional Xfce4 or KDE Plasma desktop, installed in-chroot so the machine
#     boots straight to a graphical login, or deferred to first boot
#   - Wi-Fi / audio / GPU firmware and drivers auto-detected from the live system
#   - Root and user passwords collected up front and applied via chpasswd
#
set -o pipefail

########################################################################
# Tunables
########################################################################
TARGET_SUITE="trixie"
BACKPORTS_SUITE="trixie-backports"
DEB_MIRROR="http://deb.debian.org/debian"
DEB_SECURITY_MIRROR="http://deb.debian.org/debian-security"
DEB_COMPONENTS="main contrib non-free non-free-firmware"

ROOT_DATASET_NAME="trixie"          # rpool/ROOT/${ROOT_DATASET_NAME}
DEFAULT_HOSTNAME="srv-deb13"
LOCALE_GEN="it_IT.UTF-8 UTF-8"
LOCALE_LANG="it_IT.UTF-8"
TIMEZONE="Europe/Rome"
KEYMAP="it"

ESP_SIZE="+600M"
BOOT_SIZE="+3G"
SWAP_SIZE="+2G"

ZFS_COMPRESSION="lz4"               # zstd is also fine on Trixie's OpenZFS 2.3.x
EXTRA_PACKAGES="aptitude vim zsh screen tmux openssh-server sudo pciutils usbutils \
debconf-utils ca-certificates curl rsync"

# ---- Desktop package sets (Debian's full tasks) ----------------------
XFCE_PKGS="task-xfce-desktop network-manager network-manager-gnome bluez blueman \
pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol"
KDE_PKGS="task-kde-desktop network-manager bluez bluedevil \
pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol"

# ---- Wi-Fi / network firmware ---------------------------------------
# No GPU or video drivers: X/Wayland uses the in-kernel KMS drivers, and audio
# is handled entirely by PipeWire from the desktop package set above.
FW_BASE="firmware-misc-nonfree wpasupplicant iw rfkill wireless-regdb"
# Used for the "install everything" option.
FW_ALL="firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 \
firmware-libertas firmware-mediatek firmware-ti-connectivity firmware-zd1211 \
firmware-marvell-prestera firmware-qcom-soc"

########################################################################
# Helpers
########################################################################
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Missing command '$c' in the live environment."
    done
}

# Append a partition number to a whole-disk path, handling nvme0n1 -> nvme0n1p1
part_dev() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s' "$disk" "$num"
    else
        printf '%s%s' "$disk" "$num"
    fi
}

# Prefer a stable /dev/disk/by-id path for ZFS vdevs; fall back to the raw node.
by_id_path() {
    local dev="$1" real link best=""
    real=$(readlink -f "$dev") || { printf '%s' "$dev"; return; }
    [ -d /dev/disk/by-id ] || { printf '%s' "$dev"; return; }
    for link in /dev/disk/by-id/*; do
        [ -e "$link" ] || continue
        [ "$(readlink -f "$link")" = "$real" ] || continue
        case "${link##*/}" in
            nvme-eui.*|wwn-*)   [ -n "$best" ] || best="$link" ;;   # last resort
            nvme-*|ata-*|scsi-*|mmc-*|usb-*) best="$link"; break ;;
        esac
    done
    printf '%s' "${best:-$dev}"
}

# Prompt twice for a password; echoes the result, empty on skip.
read_password() {
    local label="$1" p1 p2
    while :; do
        read -rsp "${label}: " p1; echo >&2
        [ -z "$p1" ] && { printf ''; return; }
        read -rsp "${label} (confirm): " p2; echo >&2
        if [ "$p1" = "$p2" ]; then printf '%s' "$p1"; return; fi
        echo "Passwords do not match, try again." >&2
    done
}

[ "$(id -u)" -eq 0 ] || die "This script must be run as root."
[ -d /sys/firmware/efi ] || die "This installer is UEFI-only, but the live system booted in legacy BIOS mode."
require_cmd lsblk sgdisk wipefs blkid partprobe udevadm mkfs.ext4 mkfs.vfat \
            debootstrap zpool zfs chroot awk sed

########################################################################
# Disk selection
########################################################################
mapfile -t DISKS < <(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}' | grep -Ev '^(loop|sr|zram|ram)')

[ ${#DISKS[@]} -gt 0 ] || die "No physical disks found on the system."

echo "---"
echo "Available disks:"

COUNTER=1
declare -A DISK_MAP
for DISK in "${DISKS[@]}"; do
    if [ -b "/dev/$DISK" ]; then
        echo "$COUNTER) $(lsblk -dno NAME,SIZE,MODEL "/dev/$DISK")"
        DISK_MAP[$COUNTER]="/dev/$DISK"
        ((COUNTER++))
    fi
done

[ ${#DISK_MAP[@]} -gt 0 ] || die "No valid disks found for selection."

echo "---"
echo "Enter the numbers of the disks you want to select, separated by spaces (e.g., 1 3):"
read -r USER_SELECTION

SELECTED_DISKS=()
for NUM in $USER_SELECTION; do
    if [[ -v DISK_MAP[$NUM] ]]; then
        SELECTED_DISKS+=("${DISK_MAP[$NUM]}")
    else
        echo "Warning: Number '$NUM' is not valid and will be ignored." >&2
    fi
done

echo "---"
[ ${#SELECTED_DISKS[@]} -gt 0 ] || die "No disks selected."
echo "You have selected the following disks:"
printf -- '- %s\n' "${SELECTED_DISKS[@]}"
echo "---"

echo "**WARNING**: Subsequent operations on the selected disks are **destructive** and will erase all data."
read -rp "Are you sure you want to proceed? (y/N): " CONFIRMATION
CONFIRMATION=${CONFIRMATION,,}
[[ "$CONFIRMATION" == "y" ]] || { echo "Operation canceled by the user. No disks have been modified."; exit 0; }
echo "---"

echo "Do you want to use ZFS native encryption for the main pool (rpool)?"
echo "(Swap will then also be encrypted with a random key on every boot.)"
read -rp "Enter 'y' for yes, 'n' for no (y/N): " ENCRYPT_CHOICE
ENCRYPT_CHOICE=${ENCRYPT_CHOICE,,}
echo "---"

echo "rpool is created now by the live environment's OpenZFS:"
echo "  $(zfs version 2>/dev/null | head -1)"
echo "The installed system will use OpenZFS from ${BACKPORTS_SUITE}, which is usually newer."
echo "Any feature flags only the newer release supports can be enabled on first boot."
echo "This is safe here — GRUB reads the ext4 /boot and never touches rpool — but"
echo "afterwards the pool can no longer be imported by an older OpenZFS."
read -rp "Run 'zpool upgrade rpool' on first boot? (y/N): " ZPOOL_UPGRADE
ZPOOL_UPGRADE=${ZPOOL_UPGRADE,,}
[[ "$ZPOOL_UPGRADE" == "y" ]] || ZPOOL_UPGRADE="n"
echo "---"

read -rp "Hostname for the new system [${DEFAULT_HOSTNAME}]: " NEW_HOSTNAME
NEW_HOSTNAME="${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
echo "---"

########################################################################
# Accounts
########################################################################
echo "Root password (leave empty to be prompted interactively later):"
ROOT_PASSWORD="$(read_password "  root password")"
echo "---"

echo "A graphical login manager will not accept root, so a normal user is needed for a desktop."
read -rp "Username for the regular account (leave empty to skip): " NEW_USER
NEW_USER="${NEW_USER// /}"
if [ -n "$NEW_USER" ] && ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Warning: '${NEW_USER}' is not a valid Debian username. Skipping user creation." >&2
    NEW_USER=""
fi

USER_PASSWORD=""
USER_GECOS=""
if [ -n "$NEW_USER" ]; then
    read -rp "Full name for ${NEW_USER} (optional): " USER_GECOS
    USER_PASSWORD="$(read_password "  password for ${NEW_USER}")"
    [ -n "$USER_PASSWORD" ] || echo "No password given — the account will be locked until you set one." >&2
fi
echo "---"

########################################################################
# Desktop
########################################################################
echo "Desktop environment:"
echo "1) None (headless server)"
echo "2) Xfce4      (LightDM)"
echo "3) KDE Plasma (SDDM)"
read -rp "Enter your choice (1-3) [1]: " DE_CHOICE
DE_CHOICE="${DE_CHOICE:-1}"

DESKTOP="none"; DESKTOP_PKGS=""; DM_NAME=""; DESKTOP_WHEN="now"
case "$DE_CHOICE" in
    2) DESKTOP="xfce"; DM_NAME="lightdm"; DESKTOP_PKGS="$XFCE_PKGS" ;;
    3) DESKTOP="kde";  DM_NAME="sddm";    DESKTOP_PKGS="$KDE_PKGS" ;;
    *) DESKTOP="none" ;;
esac

if [ "$DESKTOP" != "none" ]; then
    echo ""
    echo "When should the desktop be installed?"
    echo "1) Now, during installation — the system boots straight to a graphical login"
    echo "2) Automatically on first boot (systemd oneshot, needs working networking)"
    echo "3) Manually after reboot (installs the 'install-desktop' helper only)"
    read -rp "Enter your choice (1-3) [1]: " DE_WHEN
    case "$DE_WHEN" in
        2) DESKTOP_WHEN="firstboot" ;;
        3) DESKTOP_WHEN="manual" ;;
        *) DESKTOP_WHEN="now" ;;
    esac

    [ -n "$NEW_USER" ] || echo "Note: no regular user created — create one before you can log in graphically." >&2
fi
echo "---"

########################################################################
# Wi-Fi / network firmware
########################################################################
echo "Wi-Fi and network firmware:"
echo "1) Auto-detect from this machine's hardware [recommended]"
echo "2) Install a broad set covering most wireless chipsets"
echo "3) None"
echo "(No GPU/video drivers are installed — the kernel's in-tree KMS drivers"
echo " handle graphics, and audio comes from PipeWire in the desktop set.)"
read -rp "Enter your choice (1-3) [1]: " DRV_CHOICE
DRV_CHOICE="${DRV_CHOICE:-1}"

DRIVER_PKGS=""

# Scan once, in the parent shell — detect_driver_pkgs runs inside $( ), so any
# variable it sets would be lost in the subshell.
HW_INFO=""
VIRT_TYPE=""
if [ "$DRV_CHOICE" != "3" ]; then
    command -v lspci >/dev/null 2>&1 && HW_INFO+=$'\n'"$(lspci -nn 2>/dev/null)"
    command -v lsusb >/dev/null 2>&1 && HW_INFO+=$'\n'"$(lsusb 2>/dev/null)"
    command -v systemd-detect-virt >/dev/null 2>&1 && VIRT_TYPE="$(systemd-detect-virt 2>/dev/null)"
fi

detect_driver_pkgs() {
    local hw="$HW_INFO" virt="$VIRT_TYPE" pkgs=()

    # --- Wi-Fi / Bluetooth ---
    grep -Eqi 'intel.*(wireless|wi-?fi|centrino)|wireless.*intel' <<<"$hw" && pkgs+=(firmware-iwlwifi)
    grep -Eqi 'realtek'   <<<"$hw" && pkgs+=(firmware-realtek)
    grep -Eqi 'atheros|qualcomm' <<<"$hw" && pkgs+=(firmware-atheros)
    grep -Eqi 'broadcom'  <<<"$hw" && pkgs+=(firmware-brcm80211)
    grep -Eqi 'mediatek'  <<<"$hw" && pkgs+=(firmware-mediatek)
    grep -Eqi 'marvell'   <<<"$hw" && pkgs+=(firmware-libertas)
    grep -Eqi 'ralink'    <<<"$hw" && pkgs+=(firmware-misc-nonfree)

    # --- Virtual machine guest agents (no video drivers) ---
    case "$virt" in
        kvm|qemu)    pkgs+=(spice-vdagent qemu-guest-agent) ;;
        vmware)      pkgs+=(open-vm-tools open-vm-tools-desktop) ;;
        microsoft)   pkgs+=(hyperv-daemons) ;;
        xen)         pkgs+=(xe-guest-utilities) ;;
    esac

    [ ${#pkgs[@]} -gt 0 ] || return 0
    printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' '
}

case "$DRV_CHOICE" in
    1)
        echo "Scanning hardware..."
        DRIVER_PKGS="${FW_BASE} $(detect_driver_pkgs)"
        echo "Detected firmware packages:"
        printf '  %s\n' $DRIVER_PKGS
        ;;
    2)
        DRIVER_PKGS="${FW_BASE} ${FW_ALL}"
        echo "Using the broad wireless firmware set."
        ;;
    *)
        DRIVER_PKGS=""
        echo "Skipping firmware installation."
        ;;
esac
echo "---"

########################################################################
# Partitioning
########################################################################
EFI_PART=1
BOOT_PART=2
SWAP_PART=3
RPOOL_PART=4

RAID_TYPE=""
if [ ${#SELECTED_DISKS[@]} -gt 1 ]; then
    echo "You have selected multiple disks. How do you want to configure rpool?"
    echo "1) Simple Mirror (raid1)"
    echo "2) RAID10 (striped mirrors)"
    echo "3) RAIDZ1"
    echo "4) RAIDZ2"
    echo "5) RAIDZ3"
    read -rp "Enter your choice (1-5): " RAID_CHOICE
    case "$RAID_CHOICE" in
        1) RAID_TYPE="mirror" ;;
        2) RAID_TYPE="raid10" ;;
        3) RAID_TYPE="raidz1" ;;
        4) RAID_TYPE="raidz2" ;;
        5) RAID_TYPE="raidz3" ;;
        *) echo "Invalid RAID choice. Defaulting to simple mirror." >&2; RAID_TYPE="mirror" ;;
    esac
    echo "---"
fi

for disk_path in "${SELECTED_DISKS[@]}"; do
    echo "Processing disk: $disk_path"

    swapoff --all 2>/dev/null || true
    wipefs -a "$disk_path" || true
    blkdiscard -f "$disk_path" 2>/dev/null || true
    sgdisk --zap-all "$disk_path" || true
    dd if=/dev/zero of="$disk_path" count=2048 bs=512 status=none || true
    sgdisk -Z "$disk_path"

    # p1: EFI System Partition — 600 MiB, starting at the 1 MiB alignment boundary
    sgdisk -n${EFI_PART}:1M:${ESP_SIZE} -t${EFI_PART}:EF00 -c${EFI_PART}:"EFI" "$disk_path"

    # p2: /boot — 3 GiB ext4
    sgdisk -n${BOOT_PART}:0:${BOOT_SIZE} -t${BOOT_PART}:8300 -c${BOOT_PART}:"boot" "$disk_path"

    # p3: swap — 2 GiB
    sgdisk -n${SWAP_PART}:0:${SWAP_SIZE} -t${SWAP_PART}:8200 -c${SWAP_PART}:"swap" "$disk_path"

    # p4: rpool — remainder
    sgdisk -n${RPOOL_PART}:0:0 -t${RPOOL_PART}:BF00 -c${RPOOL_PART}:"rpool" "$disk_path"

    partprobe "$disk_path" || true
    echo "Partitioning on $disk_path completed."
done

udevadm settle
sleep 2

########################################################################
# rpool vdev specification
########################################################################
RPOOL_DEVICES=""
if [ ${#SELECTED_DISKS[@]} -eq 1 ]; then
    RPOOL_DEVICES="$(by_id_path "$(part_dev "${SELECTED_DISKS[0]}" $RPOOL_PART)")"
else
    case "$RAID_TYPE" in
        mirror)
            RPOOL_DEVICES="mirror"
            for d in "${SELECTED_DISKS[@]}"; do
                RPOOL_DEVICES+=" $(by_id_path "$(part_dev "$d" $RPOOL_PART)")"
            done
            ;;
        raid10)
            if [ $(( ${#SELECTED_DISKS[@]} % 2 )) -ne 0 ]; then
                echo "Warning: RAID10 with an odd disk count; the last disk will be a bare vdev." >&2
            fi
            acc=""
            for (( i=0; i<${#SELECTED_DISKS[@]}; i+=2 )); do
                D1="$(by_id_path "$(part_dev "${SELECTED_DISKS[$i]}" $RPOOL_PART)")"
                if [ $(( i+1 )) -lt ${#SELECTED_DISKS[@]} ]; then
                    D2="$(by_id_path "$(part_dev "${SELECTED_DISKS[$((i+1))]}" $RPOOL_PART)")"
                    acc+=" mirror ${D1} ${D2}"
                else
                    acc+=" ${D1}"
                fi
            done
            RPOOL_DEVICES=$(echo "$acc" | xargs)
            ;;
        raidz1|raidz2|raidz3)
            RPOOL_DEVICES="$RAID_TYPE"
            for d in "${SELECTED_DISKS[@]}"; do
                RPOOL_DEVICES+=" $(by_id_path "$(part_dev "$d" $RPOOL_PART)")"
            done
            ;;
    esac
fi

########################################################################
# rpool creation
########################################################################
ZPOOL_COMMON_OPTS=(
    -f
    -o ashift=12
    -o autotrim=on
    -o cachefile=/etc/zfs/zpool.cache
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto
    -O compression="${ZFS_COMPRESSION}"
    -O normalization=formD
    -O atime=off -O relatime=off
    -O logbias=throughput
    -O canmount=off -O mountpoint=/ -R /mnt
)

mkdir -p /etc/zfs

if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
    echo "Creating rpool (ZFS native encryption)..."
    echo "You will be asked for the pool passphrase now; the same one is requested at every boot."
    zpool create "${ZPOOL_COMMON_OPTS[@]}" \
        -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
        rpool ${RPOOL_DEVICES} || die "zpool create failed."
else
    echo "Creating rpool (unencrypted)..."
    zpool create "${ZPOOL_COMMON_OPTS[@]}" \
        rpool ${RPOOL_DEVICES} || die "zpool create failed."
fi

echo "---"
echo "Creating datasets..."
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/ "rpool/ROOT/${ROOT_DATASET_NAME}"
zfs mount "rpool/ROOT/${ROOT_DATASET_NAME}"

########################################################################
# /boot (ext4), ESP (vfat), swap
########################################################################
PRIMARY_DISK="${SELECTED_DISKS[0]}"
PRIMARY_ESP="$(part_dev "$PRIMARY_DISK" $EFI_PART)"

BOOT_FS_DEV=""
MD_BOOT=""
if [ ${#SELECTED_DISKS[@]} -gt 1 ] && command -v mdadm >/dev/null 2>&1; then
    echo "Creating mdadm RAID1 (metadata 1.0) for /boot across all selected disks..."
    MD_MEMBERS=()
    for d in "${SELECTED_DISKS[@]}"; do MD_MEMBERS+=("$(part_dev "$d" $BOOT_PART)"); done
    mdadm --zero-superblock --force "${MD_MEMBERS[@]}" 2>/dev/null || true
    if mdadm --create --run --verbose /dev/md0 \
            --metadata=1.0 --level=1 --raid-devices=${#MD_MEMBERS[@]} \
            "${MD_MEMBERS[@]}"; then
        MD_BOOT="/dev/md0"
        BOOT_FS_DEV="/dev/md0"
    else
        echo "Warning: mdadm array creation failed; falling back to /boot on ${PRIMARY_DISK} only." >&2
    fi
fi

if [ -z "$BOOT_FS_DEV" ]; then
    BOOT_FS_DEV="$(part_dev "$PRIMARY_DISK" $BOOT_PART)"
    if [ ${#SELECTED_DISKS[@]} -gt 1 ]; then
        echo "Note: /boot is NOT redundant — it lives only on ${PRIMARY_DISK}."
    fi
fi

echo "Formatting /boot as ext4 on ${BOOT_FS_DEV}..."
mkfs.ext4 -F -L boot "$BOOT_FS_DEV" || die "mkfs.ext4 on /boot failed."
mkdir -p /mnt/boot
mount -o noatime "$BOOT_FS_DEV" /mnt/boot || die "Could not mount /boot."

echo "Formatting ESP(s)..."
for d in "${SELECTED_DISKS[@]}"; do
    ESP="$(part_dev "$d" $EFI_PART)"
    mkfs.vfat -F 32 -s 1 -n EFI "$ESP" || die "mkfs.vfat on $ESP failed."
done
mkdir -p /mnt/boot/efi
mount -o umask=0077 "$PRIMARY_ESP" /mnt/boot/efi || die "Could not mount ESP."

udevadm settle

########################################################################
# debootstrap
########################################################################
echo "Preparing chroot environment in /mnt..."
mkdir -p /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock

echo "Starting debootstrap to install Debian ${TARGET_SUITE}..."
debootstrap --arch=amd64 "${TARGET_SUITE}" /mnt "${DEB_MIRROR}" || die "debootstrap failed."

mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/ 2>/dev/null || true

########################################################################
# Credentials handed to the chroot out of band (never on the command line)
########################################################################
CRED_FILE="/mnt/root/.install-credentials"
install -m 0600 /dev/null "$CRED_FILE"
[ -n "$ROOT_PASSWORD" ] && printf 'root:%s\n' "$ROOT_PASSWORD" >> "$CRED_FILE"
[ -n "$NEW_USER" ] && [ -n "$USER_PASSWORD" ] && printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" >> "$CRED_FILE"
unset ROOT_PASSWORD USER_PASSWORD

########################################################################
# fstab / crypttab
########################################################################
echo "Writing /etc/fstab..."
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_FS_DEV")
ESP_UUID=$(blkid -s UUID -o value "$PRIMARY_ESP")

{
    echo "# <file system> <mount point> <type> <options> <dump> <pass>"
    echo "# / is ZFS (rpool/ROOT/${ROOT_DATASET_NAME}) — managed by zfs-mount / zfs-list.cache"
    echo "UUID=${BOOT_UUID} /boot ext4 defaults,noatime,nodev,nosuid 0 2"
    echo "UUID=${ESP_UUID} /boot/efi vfat defaults,noatime,umask=0077,nofail 0 1"
} > /mnt/etc/fstab

echo "Configuring 2 GiB swap..."
: > /mnt/etc/crypttab
SWAP_INDEX=0
for d in "${SELECTED_DISKS[@]}"; do
    SWAP_DEV="$(part_dev "$d" $SWAP_PART)"
    if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
        SWAP_PARTUUID=$(blkid -s PARTUUID -o value "$SWAP_DEV")
        [ -n "$SWAP_PARTUUID" ] || die "Could not read PARTUUID for $SWAP_DEV."
        MAPPER="swap${SWAP_INDEX}"
        # Random key every boot: no hibernation, no plaintext swap on an encrypted host.
        echo "${MAPPER} PARTUUID=${SWAP_PARTUUID} /dev/urandom swap,cipher=aes-xts-plain64,size=512,sector-size=4096,discard" \
            >> /mnt/etc/crypttab
        echo "/dev/mapper/${MAPPER} none swap sw,pri=10 0 0" >> /mnt/etc/fstab
    else
        mkswap -f -L "swap${SWAP_INDEX}" "$SWAP_DEV" >/dev/null
        SWAP_UUID=$(blkid -s UUID -o value "$SWAP_DEV")
        echo "UUID=${SWAP_UUID} none swap sw,pri=10 0 0" >> /mnt/etc/fstab
    fi
    ((SWAP_INDEX++))
done

# Random-key swap is incompatible with resume-from-disk; silence initramfs warnings.
mkdir -p /mnt/etc/initramfs-tools/conf.d
echo "RESUME=none" > /mnt/etc/initramfs-tools/conf.d/resume

########################################################################
# Basic system configuration
########################################################################
echo "Configuring hostname..."
echo "${NEW_HOSTNAME}" > /mnt/etc/hostname
{
    printf '127.0.0.1\tlocalhost\n'
    printf '127.0.1.1\t%s\n' "${NEW_HOSTNAME}"
    printf '\n'
    printf '::1\t\tlocalhost ip6-localhost ip6-loopback\n'
    printf 'ff02::1\t\tip6-allnodes\n'
    printf 'ff02::2\t\tip6-allrouters\n'
} > /mnt/etc/hosts

cp /etc/network/interfaces /mnt/etc/network/interfaces 2>/dev/null || \
    echo "Warning: /etc/network/interfaces not found on the live system; configure networking manually."

echo "Configuring APT sources (deb822, Trixie default)..."
mkdir -p /mnt/etc/apt/sources.list.d
: > /mnt/etc/apt/sources.list
cat <<EOF_SOURCES > /mnt/etc/apt/sources.list.d/debian.sources
Types: deb deb-src
URIs: ${DEB_MIRROR}
Suites: ${TARGET_SUITE} ${TARGET_SUITE}-updates
Components: ${DEB_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: ${DEB_SECURITY_MIRROR}
Suites: ${TARGET_SUITE}-security
Components: ${DEB_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: ${DEB_MIRROR}
Suites: ${BACKPORTS_SUITE}
Components: ${DEB_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF_SOURCES

# Track the backports OpenZFS for future upgrades, without pulling in the rest
# of backports. Everything else stays on stable.
mkdir -p /mnt/etc/apt/preferences.d
cat <<EOF_PREF > /mnt/etc/apt/preferences.d/90-zfs-backports
Package: src:zfs-linux
Pin: release n=${BACKPORTS_SUITE}
Pin-Priority: 990
EOF_PREF

echo "Mounting virtual filesystems for chroot..."
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

########################################################################
# chroot stage
########################################################################
CHROOT_SCRIPT="/tmp/chroot_install_script.sh"
cat << 'CHROOT_EOF' > "/mnt${CHROOT_SCRIPT}"
#!/bin/bash
set -o pipefail

IFS=' ' read -r -a ESP_ARRAY <<< "$ESP_LIST_STR"
export DEBIAN_FRONTEND=noninteractive

# Install packages, silently skipping any that do not exist in the archive.
apt_install_optional() {
    local avail=() missing=() p
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else missing+=("$p"); fi
    done
    [ ${#missing[@]} -eq 0 ] || echo "  (not in archive, skipped: ${missing[*]})"
    [ ${#avail[@]} -gt 0 ] || return 0
    apt install --yes "${avail[@]}"
}

echo "Updating package lists..."
apt update

echo "Installing base packages..."
apt install --yes console-setup locales keyboard-configuration tzdata

echo "Configuring locale / timezone / keyboard..."
echo "${LOCALE_GEN}" > /etc/locale.gen
locale-gen
update-locale LANG="${LOCALE_LANG}"
printf 'LANG=%s\n' "${LOCALE_LANG}" > /etc/default/locale

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
dpkg-reconfigure --frontend noninteractive tzdata

cat > /etc/default/keyboard <<EOF_KBD
XKBMODEL="pc105"
XKBLAYOUT="${KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF_KBD
printf 'KEYMAP=%s\n' "${KEYMAP}" > /etc/vconsole.conf
dpkg-reconfigure --frontend noninteractive keyboard-configuration
dpkg-reconfigure --frontend noninteractive console-setup

echo "Installing kernel and build dependencies..."
apt install --yes dpkg-dev linux-headers-amd64 linux-image-amd64

echo "Configuring DKMS to rebuild the initrd..."
mkdir -p /etc/dkms
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

echo "Installing OpenZFS (dkms) + initramfs support..."
ZFS_APT_TARGET=""
if apt-cache madison zfs-dkms 2>/dev/null | grep -q "${BACKPORTS_SUITE}"; then
    ZFS_APT_TARGET="-t ${BACKPORTS_SUITE}"
    echo "  using ${BACKPORTS_SUITE}: $(apt-cache madison zfs-dkms | grep "${BACKPORTS_SUITE}" | head -1 | awk '{print $3}')"
else
    echo "  WARNING: zfs-dkms is not in ${BACKPORTS_SUITE}; falling back to the main archive." >&2
    rm -f /etc/apt/preferences.d/90-zfs-backports
fi
# shellcheck disable=SC2086
apt install --yes $ZFS_APT_TARGET zfs-dkms zfsutils-linux zfs-zed zfs-initramfs

echo "  installed OpenZFS userland: $(zfs version 2>/dev/null | head -1)"

########################################################################
# Verify the ZFS module really built for the INSTALLED kernel(s)
#
# NOTE: /proc is bind-mounted from the live system, so `uname -r` inside this
# chroot reports the live ISO's kernel. Package postinsts run `modprobe zfs`
# and print:
#     modprobe: FATAL: Module zfs not found in directory /lib/modules/<live>
# That message is EXPECTED and harmless — nothing here needs the module loaded.
# What matters is that DKMS produced zfs.ko for the Debian kernel, which is
# what the loop below checks. Do not ignore a failure here: it means the
# initramfs would ship without ZFS and the system would not boot.
########################################################################
KVERS=$(ls -1 /lib/modules 2>/dev/null | sort -V)
[ -n "$KVERS" ] && echo "Installed kernels: $(echo $KVERS | tr '\n' ' ')"

ZFS_BUILD_OK=1
for KV in $KVERS; do
    if compgen -G "/lib/modules/${KV}/updates/dkms/zfs.ko*" >/dev/null || \
       compgen -G "/lib/modules/${KV}/extra/zfs.ko*" >/dev/null; then
        echo "  OK  zfs.ko present for ${KV}"
        continue
    fi
    echo "  zfs.ko missing for ${KV} — forcing a DKMS build..."
    dkms autoinstall -k "$KV" || true
    if compgen -G "/lib/modules/${KV}/updates/dkms/zfs.ko*" >/dev/null; then
        echo "  OK  zfs.ko built for ${KV}"
    else
        echo "  FAIL  DKMS could not build ZFS for ${KV}" >&2
        echo "        See /var/lib/dkms/zfs/*/build/make.log" >&2
        ZFS_BUILD_OK=0
    fi
done

if [ "$ZFS_BUILD_OK" -ne 1 ]; then
    echo "" >&2
    echo "FATAL: the ZFS kernel module did not build. Continuing would produce an" >&2
    echo "       unbootable system, so the installation is stopping here." >&2
    exit 1
fi

echo "  DKMS status: $(dkms status zfs 2>/dev/null | tr '\n' ' ')"

echo "Installing cryptsetup (random-key swap) and mdadm if needed..."
apt install --yes cryptsetup cryptsetup-initramfs
if [ -e /dev/md0 ]; then
    apt install --yes mdadm
    mkdir -p /etc/mdadm
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
fi

echo "Installing bootloader packages..."
apt install --yes dosfstools efibootmgr grub-efi-amd64 grub-efi-amd64-signed shim-signed

echo "Installing additional packages..."
apt install --yes ${EXTRA_PACKAGES}

########################################################################
# Accounts
########################################################################
if [ -n "$NEW_USER" ]; then
    echo "Creating user '${NEW_USER}'..."
    adduser --disabled-password --gecos "${USER_GECOS}" "$NEW_USER"
    for GRP in sudo audio video netdev plugdev input render cdrom dialout bluetooth lpadmin scanner; do
        getent group "$GRP" >/dev/null && usermod -aG "$GRP" "$NEW_USER"
    done
fi

if [ -s /root/.install-credentials ]; then
    echo "Applying passwords..."
    chpasswd < /root/.install-credentials || echo "Warning: chpasswd failed." >&2
fi
shred -u /root/.install-credentials 2>/dev/null || rm -f /root/.install-credentials

if ! passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^P$'; then
    echo "No root password was set. Set it now; you will be prompted twice."
    passwd
fi
if [ -n "$NEW_USER" ] && ! passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}' | grep -q '^P$'; then
    echo "No password was set for ${NEW_USER}. Set it now; you will be prompted twice."
    passwd "$NEW_USER"
fi

########################################################################
# Wi-Fi / network firmware
########################################################################
if [ -n "${DRIVER_PKGS// /}" ]; then
    echo "Installing firmware..."
    apt_install_optional ${DRIVER_PKGS}
fi

########################################################################
# Desktop
########################################################################
write_desktop_installer() {
    cat > /usr/local/sbin/install-desktop <<EOF_DESK_HEAD
#!/bin/bash
# Generated by the Trixie ZFS installer.
DESKTOP="${DESKTOP}"
DM_NAME="${DM_NAME}"
DESKTOP_PKGS="${DESKTOP_PKGS}"
EOF_DESK_HEAD

    cat >> /usr/local/sbin/install-desktop <<'EOF_DESK_BODY'
set -o pipefail
[ "$(id -u)" -eq 0 ] || { echo "This must be run as root." >&2; exit 1; }

LOG=/var/log/install-desktop.log
exec > >(tee -a "$LOG") 2>&1
echo "=== install-desktop (${DESKTOP}) started $(date -Is) ==="

if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "ERROR: cannot resolve deb.debian.org — bring networking up first, then re-run." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
for DM in lightdm sddm gdm3; do
    echo "${DM} shared/default-x-display-manager select ${DM_NAME}" | debconf-set-selections
done

apt update || { echo "ERROR: apt update failed." >&2; exit 1; }
# shellcheck disable=SC2086
apt install --yes $DESKTOP_PKGS || { echo "ERROR: desktop installation failed." >&2; exit 1; }

command -v "/usr/bin/${DM_NAME}" >/dev/null && echo "/usr/bin/${DM_NAME}" > /etc/X11/default-display-manager
systemctl enable "${DM_NAME}.service" 2>/dev/null || true
systemctl set-default graphical.target

if [ -f /etc/network/interfaces ] && \
   awk '/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+/ && $2 != "lo" {found=1} END{exit !found}' \
       /etc/network/interfaces; then
    echo ""
    echo "NOTE: /etc/network/interfaces declares interfaces other than 'lo'."
    echo "      NetworkManager will not manage those. To hand them over, comment"
    echo "      them out and run: systemctl restart NetworkManager"
fi

echo ""
echo "=== Desktop installation complete $(date -Is) ==="
echo "Start it now with:  systemctl isolate graphical.target"
echo "Or just reboot. Log: $LOG"
EOF_DESK_BODY

    chmod 0755 /usr/local/sbin/install-desktop
}

if [ "$DESKTOP" != "none" ]; then
    write_desktop_installer

    case "$DESKTOP_WHEN" in
        now)
            echo "Installing the ${DESKTOP} desktop now..."
            for DM in lightdm sddm gdm3; do
                echo "${DM} shared/default-x-display-manager select ${DM_NAME}" | debconf-set-selections
            done
            apt_install_optional ${DESKTOP_PKGS}

            if [ -x "/usr/bin/${DM_NAME}" ]; then
                echo "/usr/bin/${DM_NAME}" > /etc/X11/default-display-manager
                systemctl enable "${DM_NAME}.service" 2>/dev/null || true
                systemctl set-default graphical.target
                echo "Graphical target enabled — the system will boot to ${DM_NAME}."
            else
                echo "Warning: ${DM_NAME} was not installed; leaving the default target as multi-user." >&2
            fi
            ;;
        firstboot)
            echo "Enabling desktop-firstboot.service (runs once, then disables itself)..."
            cat > /etc/systemd/system/desktop-firstboot.service <<'EOF_DESK_UNIT'
[Unit]
Description=Install the graphical desktop on first boot
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/local/sbin/install-desktop
ConditionPathExists=!/var/lib/desktop-firstboot.done

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
ExecStart=/usr/local/sbin/install-desktop
ExecStartPost=/usr/bin/touch /var/lib/desktop-firstboot.done
ExecStartPost=-/bin/systemctl disable desktop-firstboot.service

[Install]
WantedBy=multi-user.target
EOF_DESK_UNIT
            systemctl enable desktop-firstboot.service
            ;;
        manual)
            cat > /etc/motd <<EOF_MOTD

The ${DESKTOP} desktop is not installed yet. To install it, run as root:

    install-desktop

EOF_MOTD
            ;;
    esac
fi

echo "Enabling SSH login for root..."
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config

echo "Setting zsh as default shell for root..."
chsh -s /bin/zsh root

########################################################################
# GRUB (UEFI)
########################################################################
echo "Configuring /etc/default/grub..."
if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=ZFS=rpool/ROOT/${ROOT_DATASET_NAME}\"|" /etc/default/grub
else
    echo "GRUB_CMDLINE_LINUX=\"root=ZFS=rpool/ROOT/${ROOT_DATASET_NAME}\"" >> /etc/default/grub
fi
# /boot is ext4; GRUB never needs to touch the encrypted pool.
sed -i 's|^#\?GRUB_ENABLE_CRYPTODISK=.*|GRUB_ENABLE_CRYPTODISK=n|' /etc/default/grub
grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub

echo "Refreshing initramfs..."
update-initramfs -c -k all

# The initramfs must contain zfs.ko and the zfs-initramfs boot script, or the
# kernel will panic at boot with "unable to mount root fs".
INITRD_OK=1
for KV in $KVERS; do
    IMG="/boot/initrd.img-${KV}"
    [ -f "$IMG" ] || { echo "  FAIL  ${IMG} was not generated" >&2; INITRD_OK=0; continue; }
    if lsinitramfs "$IMG" 2>/dev/null | grep -q 'zfs\.ko'; then
        echo "  OK  ${IMG} contains the ZFS module"
    else
        echo "  FAIL  ${IMG} does NOT contain zfs.ko" >&2
        INITRD_OK=0
    fi
done

if [ "$INITRD_OK" -ne 1 ]; then
    echo "" >&2
    echo "FATAL: the initramfs is missing ZFS support; the system would not boot." >&2
    exit 1
fi

echo "Updating GRUB configuration..."
update-grub

echo "Installing the bootloader..."
# Primary ESP is already mounted at /boot/efi via fstab.
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --bootloader-id=debian --recheck
# Fallback path so the disk boots without a working NVRAM entry.
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --removable --no-nvram --recheck

# Mirror the ESP onto any additional disks.
if [ "${#ESP_ARRAY[@]}" -gt 1 ]; then
    mkdir -p /tmp/esp
    for (( i=1; i<${#ESP_ARRAY[@]}; i++ )); do
        EXTRA_ESP="${ESP_ARRAY[$i]}"
        [ -b "$EXTRA_ESP" ] || { echo "Skipping missing $EXTRA_ESP"; continue; }
        echo "Cloning bootloader onto ${EXTRA_ESP}..."
        mount "$EXTRA_ESP" /tmp/esp || continue
        grub-install --target=x86_64-efi --efi-directory=/tmp/esp \
                     --removable --no-nvram --recheck || true
        umount /tmp/esp || true
    done
    rmdir /tmp/esp 2>/dev/null || true
fi

########################################################################
# zfs-list.cache (required for correct mounting at boot)
########################################################################
echo "Generating /etc/zfs/zfs-list.cache/rpool..."
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/rpool

zed -F &
ZED_PID=$!
sleep 3
# Any property change on the pool makes zed rewrite the cache file.
zfs set canmount=on  "rpool/ROOT/${ROOT_DATASET_NAME}"
sleep 2
zfs set canmount=noauto "rpool/ROOT/${ROOT_DATASET_NAME}"
sleep 2
kill "$ZED_PID" 2>/dev/null || true
wait "$ZED_PID" 2>/dev/null || true

if [ -s /etc/zfs/zfs-list.cache/rpool ]; then
    sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/rpool
    echo "zfs-list.cache populated."
else
    echo "Warning: zfs-list.cache/rpool is empty. Run 'zfs set canmount=noauto rpool/ROOT/${ROOT_DATASET_NAME}' after first boot with zed running." >&2
fi

zpool set cachefile=/etc/zfs/zpool.cache rpool

if [ "$ZPOOL_UPGRADE" = "y" ]; then
    echo "Enabling zpool-upgrade-firstboot.service..."
    cat > /etc/systemd/system/zpool-upgrade-firstboot.service <<'EOF_ZPOOL_UNIT'
[Unit]
Description=Enable new ZFS feature flags on rpool after switching to the backports OpenZFS
Documentation=man:zpool-upgrade(8)
After=zfs.target zfs-mount.service
Requires=zfs.target
ConditionPathExists=!/var/lib/zpool-upgrade.done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zpool upgrade rpool
ExecStartPost=/usr/bin/touch /var/lib/zpool-upgrade.done
ExecStartPost=-/bin/systemctl disable zpool-upgrade-firstboot.service

[Install]
WantedBy=multi-user.target
EOF_ZPOOL_UNIT
    systemctl enable zpool-upgrade-firstboot.service
fi

apt clean
echo "Chroot stage complete."
CHROOT_EOF

chmod +x "/mnt${CHROOT_SCRIPT}"

ESP_LIST=()
for d in "${SELECTED_DISKS[@]}"; do ESP_LIST+=("$(part_dev "$d" $EFI_PART)"); done

echo "Entering chroot for final configuration..."
chroot /mnt /usr/bin/env \
    ESP_LIST_STR="${ESP_LIST[*]}" \
    ROOT_DATASET_NAME="$ROOT_DATASET_NAME" \
    LOCALE_GEN="$LOCALE_GEN" \
    LOCALE_LANG="$LOCALE_LANG" \
    TIMEZONE="$TIMEZONE" \
    KEYMAP="$KEYMAP" \
    EXTRA_PACKAGES="$EXTRA_PACKAGES" \
    NEW_USER="$NEW_USER" \
    USER_GECOS="$USER_GECOS" \
    DESKTOP="$DESKTOP" \
    DESKTOP_PKGS="$DESKTOP_PKGS" \
    DESKTOP_WHEN="$DESKTOP_WHEN" \
    DM_NAME="$DM_NAME" \
    DRIVER_PKGS="$DRIVER_PKGS" \
    BACKPORTS_SUITE="$BACKPORTS_SUITE" \
    ZPOOL_UPGRADE="$ZPOOL_UPGRADE" \
    bash "${CHROOT_SCRIPT}"
CHROOT_RC=$?

rm -f "/mnt${CHROOT_SCRIPT}"
rm -f "$CRED_FILE" 2>/dev/null || true

if [ "$CHROOT_RC" -ne 0 ]; then
    echo "" >&2
    echo "The chroot stage failed (exit ${CHROOT_RC}). The target is still mounted at /mnt" >&2
    echo "so you can investigate; nothing has been unmounted or exported." >&2
    exit "$CHROOT_RC"
fi
echo "Exiting chroot environment."
echo "---"

########################################################################
# Teardown
########################################################################
echo "Starting cleanup and finalization phase..."

grep -E ' /mnt(/|$)' /proc/mounts | awk '{print $2}' | sort -r | xargs -r -n1 umount -l || true
zfs umount -a || true

echo "Exporting ZFS pool..."
zpool export rpool || echo "Warning: 'zpool export rpool' failed. Run it manually before rebooting."

if [ -n "$MD_BOOT" ]; then
    mdadm --stop "$MD_BOOT" 2>/dev/null || true
fi

echo "---"
echo "Installation complete (UEFI)."
echo "  p1 /boot/efi : 600 MiB vfat"
echo "  p2 /boot     : 3 GiB ext4 (${BOOT_FS_DEV})"
echo "  p3 swap      : 2 GiB$( [[ "$ENCRYPT_CHOICE" == "y" ]] && echo ' (dm-crypt, random key per boot)' )"
echo "  p4 /         : rpool/ROOT/${ROOT_DATASET_NAME}$( [[ "$ENCRYPT_CHOICE" == "y" ]] && echo ' (ZFS native encryption)' )"
echo "  atime=off relatime=off logbias=throughput"
echo "  zfs        : installed from ${BACKPORTS_SUITE} (pinned for future upgrades)"
[ "$ZPOOL_UPGRADE" = "y" ] && echo "               'zpool upgrade rpool' runs on first boot"
[ -n "$NEW_USER" ] && echo "  user       : ${NEW_USER} (sudo, audio, video, netdev, ...)"
case "$DESKTOP" in
    none) echo "  desktop    : none (headless)" ;;
    *)
        case "$DESKTOP_WHEN" in
            now)       echo "  desktop    : ${DESKTOP} installed, boots to ${DM_NAME} (graphical.target)" ;;
            firstboot) echo "  desktop    : ${DESKTOP} installs automatically on first boot" ;;
            manual)    echo "  desktop    : run 'install-desktop' as root after rebooting" ;;
        esac
        ;;
esac
[ -n "${DRIVER_PKGS// /}" ] && echo "  firmware   : Wi-Fi / network firmware installed (no GPU drivers)"
echo ""
echo "Remove the live installation medium before rebooting."
echo "---"
