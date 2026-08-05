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
# Notes:
#   - No bpool: /boot is plain ext4, so rpool keeps all feature flags
#   - deb822 sources (Trixie default), trixie-security suite
#   - atime=off + relatime=off, logbias=throughput on the pool root
#   - NVMe/mmcblk partition naming handled (pN suffix)
#   - pool vdevs referenced by /dev/disk/by-id where resolvable
#   - zfs-list.cache actually populated via a transient zed
#
set -o pipefail

########################################################################
# Tunables
########################################################################
TARGET_SUITE="trixie"
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
EXTRA_PACKAGES="aptitude vim zsh screen tmux openssh-server sudo"

# Post-reboot desktop package sets (see the Xfce4 prompt below)
XFCE_PKGS_MINIMAL="xorg xfce4 lightdm lightdm-gtk-greeter network-manager \
pipewire pipewire-pulse wireplumber pavucontrol \
fonts-dejavu fonts-liberation2 xdg-utils desktop-base policykit-1"
XFCE_PKGS_FULL="task-xfce-desktop network-manager"

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

read -rp "Hostname for the new system [${DEFAULT_HOSTNAME}]: " NEW_HOSTNAME
NEW_HOSTNAME="${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
echo "---"

echo "A graphical login manager will not accept root, so a normal user is needed for a desktop."
read -rp "Create a regular (non-root) user? Enter a username, or leave empty to skip: " NEW_USER
NEW_USER="${NEW_USER// /}"
if [ -n "$NEW_USER" ] && ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Warning: '${NEW_USER}' is not a valid Debian username. Skipping user creation." >&2
    NEW_USER=""
fi
echo "---"

echo "Xfce4 desktop (installed AFTER the first reboot, not now):"
echo "1) Do not set anything up"
echo "2) Install the 'install-xfce4' helper only — you run it manually after rebooting"
echo "3) Install the helper and run it automatically on first boot"
read -rp "Enter your choice (1-3) [1]: " XFCE_CHOICE
XFCE_CHOICE="${XFCE_CHOICE:-1}"
case "$XFCE_CHOICE" in
    2|3) ;;
    *)   XFCE_CHOICE=1 ;;
esac

XFCE_PKGS=""
if [[ "$XFCE_CHOICE" != "1" ]]; then
    echo ""
    echo "Which package set?"
    echo "1) Minimal  — xorg + xfce4 + lightdm + pipewire (lean)"
    echo "2) Full     — task-xfce-desktop (Debian's standard Xfce task: apps, printing, etc.)"
    read -rp "Enter your choice (1-2) [1]: " XFCE_SET
    if [[ "$XFCE_SET" == "2" ]]; then
        XFCE_PKGS="$XFCE_PKGS_FULL"
    else
        XFCE_PKGS="$XFCE_PKGS_MINIMAL"
    fi
    if [ -z "$NEW_USER" ]; then
        echo "Note: no regular user was requested — you will need to create one before you can log in graphically." >&2
    fi
fi
echo "---"

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

########################################################################
# Partitioning
########################################################################
EFI_PART=1
BOOT_PART=2
SWAP_PART=3
RPOOL_PART=4

for disk_path in "${SELECTED_DISKS[@]}"; do
    echo "Processing disk: $disk_path"

    swapoff --all 2>/dev/null || true
    wipefs -a "$disk_path" || true
    blkdiscard -f "$disk_path" 2>/dev/null || true
    sgdisk --zap-all "$disk_path" || true
    dd if=/dev/zero of="$disk_path" count=2048 bs=512 status=none || true
    sgdisk -Z "$disk_path"

    # p1: EFI System Partition — 600 MiB
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
EOF_SOURCES

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

echo "Updating package lists..."
apt update

echo "Installing base packages..."
DEBIAN_FRONTEND=noninteractive apt install --yes console-setup locales keyboard-configuration tzdata

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
DEBIAN_FRONTEND=noninteractive apt install --yes \
    dpkg-dev linux-headers-amd64 linux-image-amd64 firmware-linux-free

echo "Configuring DKMS to rebuild the initrd..."
mkdir -p /etc/dkms
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

echo "Installing OpenZFS (dkms) + initramfs support..."
DEBIAN_FRONTEND=noninteractive apt install --yes \
    zfs-dkms zfsutils-linux zfs-zed zfs-initramfs

echo "Installing cryptsetup (random-key swap) and mdadm if needed..."
DEBIAN_FRONTEND=noninteractive apt install --yes cryptsetup cryptsetup-initramfs
if [ -e /dev/md0 ]; then
    DEBIAN_FRONTEND=noninteractive apt install --yes mdadm
    mkdir -p /etc/mdadm
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
fi

echo "Installing bootloader packages..."
DEBIAN_FRONTEND=noninteractive apt install --yes \
    dosfstools efibootmgr grub-efi-amd64 grub-efi-amd64-signed shim-signed

echo "Installing additional packages: ${EXTRA_PACKAGES}"
DEBIAN_FRONTEND=noninteractive apt install --yes ${EXTRA_PACKAGES}

echo "Enabling SSH login for root..."
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config

echo "Setting zsh as default shell for root..."
chsh -s /bin/zsh root

echo "Setting root password. You will be prompted twice."
passwd

########################################################################
# Regular user
########################################################################
if [ -n "$NEW_USER" ]; then
    echo "Creating user '${NEW_USER}'..."
    adduser --disabled-password --gecos "" "$NEW_USER"
    for GRP in sudo audio video netdev plugdev input render cdrom dialout; do
        getent group "$GRP" >/dev/null && usermod -aG "$GRP" "$NEW_USER"
    done
    echo "Set the password for '${NEW_USER}'. You will be prompted twice."
    passwd "$NEW_USER"
fi

########################################################################
# Xfce4 post-reboot helper
########################################################################
if [[ "$XFCE_CHOICE" != "1" ]]; then
    echo "Installing the /usr/local/sbin/install-xfce4 helper..."

    cat > /usr/local/sbin/install-xfce4 <<EOF_XFCE_HEAD
#!/bin/bash
# Generated by the Trixie ZFS installer. Installs the Xfce4 desktop.
XFCE_PKGS="${XFCE_PKGS}"
EOF_XFCE_HEAD

    cat >> /usr/local/sbin/install-xfce4 <<'EOF_XFCE_BODY'
set -o pipefail

[ "$(id -u)" -eq 0 ] || { echo "This must be run as root." >&2; exit 1; }

LOG=/var/log/install-xfce4.log
exec > >(tee -a "$LOG") 2>&1
echo "=== install-xfce4 started $(date -Is) ==="

if command -v getent >/dev/null && ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "ERROR: cannot resolve deb.debian.org — bring networking up first, then re-run." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt update || { echo "ERROR: apt update failed." >&2; exit 1; }
# shellcheck disable=SC2086
apt install --yes $XFCE_PKGS || { echo "ERROR: package installation failed." >&2; exit 1; }

systemctl enable lightdm.service 2>/dev/null || true
systemctl set-default graphical.target

# NetworkManager ignores interfaces declared in /etc/network/interfaces.
if [ -f /etc/network/interfaces ] && \
   awk '/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+/ && $2 != "lo" {found=1} END{exit !found}' \
       /etc/network/interfaces; then
    echo ""
    echo "NOTE: /etc/network/interfaces declares interfaces other than 'lo'."
    echo "      NetworkManager will not manage those. To hand them over, comment"
    echo "      them out and run: systemctl restart NetworkManager"
fi

echo ""
echo "=== Xfce4 installation complete $(date -Is) ==="
echo "Start it now with:  systemctl isolate graphical.target"
echo "Or just reboot. Log: $LOG"
EOF_XFCE_BODY

    chmod 0755 /usr/local/sbin/install-xfce4

    if [[ "$XFCE_CHOICE" == "3" ]]; then
        echo "Enabling xfce4-firstboot.service (runs once, then disables itself)..."
        cat > /etc/systemd/system/xfce4-firstboot.service <<'EOF_XFCE_UNIT'
[Unit]
Description=Install the Xfce4 desktop on first boot
Wants=network-online.target
After=network-online.target apt-daily.service
ConditionPathExists=/usr/local/sbin/install-xfce4
ConditionPathExists=!/var/lib/xfce4-firstboot.done

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
ExecStart=/usr/local/sbin/install-xfce4
ExecStartPost=/usr/bin/touch /var/lib/xfce4-firstboot.done
ExecStartPost=-/bin/systemctl disable xfce4-firstboot.service

[Install]
WantedBy=multi-user.target
EOF_XFCE_UNIT
        systemctl enable xfce4-firstboot.service
    else
        cat > /etc/motd <<'EOF_MOTD'

Xfce4 is not installed yet. To install it, run as root:

    install-xfce4

EOF_MOTD
    fi
fi

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
    XFCE_CHOICE="$XFCE_CHOICE" \
    XFCE_PKGS="$XFCE_PKGS" \
    bash "${CHROOT_SCRIPT}"

rm -f "/mnt${CHROOT_SCRIPT}"
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
[ -n "$NEW_USER" ] && echo "  user       : ${NEW_USER} (sudo, audio, video, netdev, ...)"
case "$XFCE_CHOICE" in
    2) echo "  desktop    : run 'install-xfce4' as root after rebooting" ;;
    3) echo "  desktop    : xfce4-firstboot.service will install Xfce4 on first boot" ;;
esac
echo ""
echo "Remove the live installation medium before rebooting."
echo "---"
