#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL https://git.io/vNxbN | bash
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

REPO_URL='https://templar-von-midgard.github.io/arch-packages/repo'

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
boot_size=550
boot_end=$(( $boot_size + 1 ))MiB
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + $boot_size + 1 ))MiB

parted --script "${device}" --                      \
  mklabel gpt                                       \
  mkpart ESP fat32 1Mib ${boot_end}                 \
  set 1 boot on                                     \
  mkpart primary linux-swap ${boot_end} ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

wipefs "${part_boot}"
wipefs "${part_swap}"
wipefs "${part_root}"

mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.ext4 "${part_root}"

swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

### Install and configure the basic system
cat >>/etc/pacman.conf <<EOF
[tvm]
SigLevel = Optional TrustAll
Server = $REPO_URL
EOF

pacstrap /mnt tvm-desktop
genfstab -t PARTUUID /mnt >> /mnt/etc/fstab
echo "${hostname}" > /mnt/etc/hostname

cat >>/mnt/etc/pacman.conf <<EOF
[tvm]
SigLevel = Optional TrustAll
Server = $REPO_URL
EOF

arch-chroot /mnt bootctl install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

partuuid_of() {
  echo "PARTUUID=$(blkid -s PARTUUID -o value "$1")"
}

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /initramfs-linux.img
options  resume=$(partuuid_of "$part_swap") root=$(partuuid_of "$part_root") rw
EOF

sed -e 's/#(COMPRESSION="lz4")/\1/' \
    -e 's/^(HOOKS=.*?)udev(.*?)\)$/\1systemd\2 sd-vconsole)/' \
    -i /mnt/etc/mkinitcpio.conf
hibernation_img_size=$(( ($swap_size - 2048) * 1024 * 1024 ))
echo <<EOF > /mnt/etc/tmpfiles.d/sys-power-image_size.conf
# Set the hibernation image_size to swap_size - 2GiB
#       Path                    Mode    User    Group   Age     Argument
w       /sys/power/image_size   -       -       -       -       ${hibernation_img_size}
EOF

arch-chroot /mnt useradd -mU -s /usr/bin/zsh -G wheel,uucp,video,audio,storage,games,input "$user"
arch-chroot /mnt mkinitcpio -p linux

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt
