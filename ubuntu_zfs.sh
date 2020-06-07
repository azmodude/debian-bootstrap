#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

bootstrap_dialog() {
    dialog_result=$(dialog --clear --stdout --backtitle "Debian/Ubuntu ZFS bootstrapper" --no-shadow "$@" 2>/dev/null)
}

setup() {
    apt-get update && \
	      apt-get -y install dialog

    if [ -z "${UBUNTU_TREE}" ]; then
        bootstrap_dialog --title "Ubuntu Tree" \
                         --menu "Install which Ubuntu tree?" 0 0 0 \
                         "focal" "lts" \
                         "focal" "latest"
        UBUNTU_TREE="${dialog_result}"
    fi

    if [ -z "${HOSTNAME_FQDN}" ]; then
        bootstrap_dialog --title "Hostname" --inputbox "Please enter a fqdn for this host.\n" 8 60
        HOSTNAME_FQDN="$dialog_result"
    fi

    if [ -z "${INSTALL_DISK}" ]; then
        declare -a disks
        for disk in /dev/disk/by-id/*; do
            disks+=("${disk}" "$(basename "$(readlink "$disk")")")
        done
        bootstrap_dialog --title "Choose installation disk" \
                        --menu "Which disk to install on?" 0 0 0 \
                        "${disks[@]}"
        INSTALL_DISK="${dialog_result}"
    fi

    if [ -z "${SWAP_SIZE}" ]; then
        bootstrap_dialog --title "SWAP SIZE" --inputbox "Please enter a swap size in GB.\n" 8 60
        SWAP_SIZE="$dialog_result"
    fi

    if [ -z "${ENCRYPTION_PASSPHRASE}" ]; then
        bootstrap_dialog --title "Disk encryption" --passwordbox "Please enter a strong passphrase for the full disk encryption.\n" 8 60
        ENCRYPTION_PASSPHRASE="$dialog_result"
        bootstrap_dialog --title "Disk encryption" --passwordbox "Please re-enter passphrase to verify.\n" 8 60
        ENCRYPTION_PASSPHRASE_VERIFY="$dialog_result"
        if [[ "${ENCRYPTION_PASSPHRASE}" != "${ENCRYPTION_PASSPHRASE_VERIFY}" ]]; then
            echo "Passwords did not match."
            exit 3
        fi
    fi
    if [ -z "${GRUB_PASSWORD}" ]; then
        bootstrap_dialog --title "Grub Password" --passwordbox "Please enter a strong password for protecting the bootloader.\n" 8 60
        GRUB_PASSWORD="$dialog_result"
        bootstrap_dialog --title "Grub Password" --passwordbox "Please re-enter password to verify.\n" 8 60
        GRUB_PASSWORD_VERIFY="$dialog_result"
        if [[ "${GRUB_PASSWORD}" != "${GRUB_PASSWORD_VERIFY}" ]]; then
            echo "Passwords did not match."
            exit 3
        fi
    fi

    if [ -z "${ROOT_PASSWORD}" ]; then
        bootstrap_dialog --title "Root password" --passwordbox "Please enter a strong password for the root user.\n" 8 60
        ROOT_PASSWORD="$dialog_result"
        bootstrap_dialog --title "Root password" --passwordbox "Please re-enter passphrase to verify.\n" 8 60
        ROOT_PASSWORD_VERIFY="$dialog_result"
        if [[ "${ROOT_PASSWORD}" != "${ROOT_PASSWORD_VERIFY}" ]]; then
            echo "Passwords did not match."
            exit 3
        fi
    fi

    bootstrap_dialog --title "WARNING" --msgbox "This script will NUKE ${INSTALL_DISK}.\nPress <Enter> to continue or <Esc> to cancel.\n" 6 60

    if [ -z "${INSTALL_DISK}" ] || [ ! -L "${INSTALL_DISK}" ]; then
        echo "${INSTALL_DISK} does not exist!"
        exit 1
    fi

    [ -d /sys/firmware/efi ] && IS_EFI=1 || IS_EFI=0
    echo -n "Using ${INSTALL_DISK} and performing "
    [[ ${IS_EFI} -eq 1 ]] && echo "UEFI install."
    [[ ! ${IS_EFI} -eq 1 ]] && echo "legacy BIOS install."
}

preinstall() {
    apt-add-repository universe && apt-get update
    apt install --yes debootstrap gdisk zfs-initramfs zfsutils-linux cryptsetup
    systemctl stop zed
    modprobe zfs
}

partition_zfs() {
    sgdisk --zap-all "${INSTALL_DISK}"
    sgdisk -n1:1M:+512M -t1:EF00 "${INSTALL_DISK}"
    [[ ! ${IS_EFI} -eq 1 ]] && sgdisk -a1 -n5:24k:+1000K -t5:EF02 "${INSTALL_DISK}"
    sgdisk -n2:0:+"${SWAP_SIZE}G" -t2:8200 "${INSTALL_DISK}"
    sgdisk -n3:0:+2G -t3:BE00 "${INSTALL_DISK}"
    sgdisk -n4:0:0 -t4:BF00 "${INSTALL_DISK}"

    # wait for for udev to create paths
    sleep 3

    zpool labelclear -f "${INSTALL_DISK}-part3" || true
    zpool labelclear -f "${INSTALL_DISK}-part4" || true

    zpool create \
        -o ashift=12 -d \
        -o feature@async_destroy=enabled \
        -o feature@bookmarks=enabled \
        -o feature@embedded_data=enabled \
        -o feature@empty_bpobj=enabled \
        -o feature@enabled_txg=enabled \
        -o feature@extensible_dataset=enabled \
        -o feature@filesystem_limits=enabled \
        -o feature@hole_birth=enabled \
        -o feature@large_blocks=enabled \
        -o feature@lz4_compress=enabled \
        -o feature@spacemap_histogram=enabled \
        -o feature@zpool_checkpoint=enabled \
        -O acltype=posixacl -O canmount=off -O compression=lz4 \
        -O devices=off -O normalization=formD -O relatime=on -O xattr=sa \
        -O mountpoint=/boot -R /mnt \
        bpool "${INSTALL_DISK}-part3"

    echo "$ENCRYPTION_PASSPHRASE" | \
        zpool create \
            -o ashift=12 \
            -o autotrim=on \
            -O encryption=aes-256-gcm \
            -O keylocation=prompt -O keyformat=passphrase \
            -O acltype=posixacl -O canmount=off -O compression=lz4 \
            -O dnodesize=auto -O normalization=formD -O relatime=on \
            -O xattr=sa -O mountpoint=/ -R /mnt \
            rpool "${INSTALL_DISK}-part4"

    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT

    UUID=$(dd if=/dev/urandom of=/dev/stdout bs=1 count=100 2>/dev/null |
    tr -dc 'a-z0-9' | cut -c-6)

    zfs create -o canmount=noauto -o mountpoint=/ \
        -o com.ubuntu.zsys:bootfs=yes \
        -o com.ubuntu.zsys:last-used="$(date +%s)" rpool/ROOT/ubuntu_"${UUID}"
    zfs mount rpool/ROOT/ubuntu_"${UUID}"

    zfs create -o canmount=noauto -o mountpoint=/boot \
        bpool/BOOT/ubuntu_"${UUID}"
    zfs mount bpool/BOOT/ubuntu_"${UUID}"

    zfs create -o com.ubuntu.zsys:bootfs=no \
        rpool/ROOT/ubuntu_"${UUID}"/srv
    zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \
        rpool/ROOT/ubuntu_"${UUID}"/usr
    zfs create rpool/ROOT/ubuntu_"${UUID}"/usr/local
    zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off \
        rpool/ROOT/ubuntu_"${UUID}"/var
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/games
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/lib
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/lib/AccountsService
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/lib/apt
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/lib/dpkg
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/lib/NetworkManager
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/log
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/mail
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/snap
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/spool
    zfs create rpool/ROOT/ubuntu_"${UUID}"/var/www

    zfs create -o canmount=off -o mountpoint=/ \
        rpool/USERDATA
    zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/ubuntu_"${UUID}" \
        -o canmount=on -o mountpoint=/root \
        rpool/USERDATA/root_"${UUID}"

    zpool export bpool
    zpool export rpool
    zpool import -d /dev/disk/by-id -R /mnt rpool -N
    zpool import -d /dev/disk/by-id -R /mnt bpool -N
    echo "${ENCRYPTION_PASSPHRASE}" | zfs load-key rpool
    zfs mount rpool/ROOT/"ubuntu_${UUID}"
    zfs mount bpool/BOOT/"ubuntu_${UUID}"
    zfs mount -a
}

install() {
    debootstrap "${UBUNTU_TREE}" /mnt
    echo "Configuring hostname"
    echo "${HOSTNAME_FQDN}" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<- END
		127.0.0.1   localhost.localdomain localhost
		127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME%%.*}
END
    cat > /mnt/etc/apt/sources.list <<- END
		deb http://archive.ubuntu.com/ubuntu ${UBUNTU_TREE} main restricted universe multiverse
		deb http://archive.ubuntu.com/ubuntu ${UBUNTU_TREE}-updates main restricted universe multiverse
		deb http://archive.ubuntu.com/ubuntu ${UBUNTU_TREE}-backports main restricted universe multiverse
		deb http://security.ubuntu.com/ubuntu ${UBUNTU_TREE}-security main restricted universe multiverse
END

    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys

    set -vx
    cp "$(pwd)/ubuntu_zfs_chroot.sh" /mnt/tmp
    chroot /mnt /usr/bin/env \
        INSTALL_DISK="${INSTALL_DISK}" \
        UUID="${UUID}" \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
        GRUB_PASSWORD="${GRUB_PASSWORD}" \
        IS_EFI="${IS_EFI}" \
        /bin/bash --login -c /tmp/ubuntu_zfs_chroot.sh
    set +vx

    cp "$(pwd)/ubuntu_zfs_firstboot.sh" /mnt/root
}

function teardown() {
    swapoff -a
    umount -lR /mnt
    sleep 5
    zpool export -a
}

if [ "$(id -u)" != 0 ]; then
    echo "Please execute with root rights."
    exit 1
fi

setup
preinstall
partition_zfs
install
teardown

