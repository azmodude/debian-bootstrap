#!/bin/bash
# This quite closely follows the official guide at
# https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2020.04%20Root%20on%20ZFS.html

export DEBIAN_FRONTEND=noninteractive

cd "${BASH_SOURCE%/*}/" || exit # cd into the bundle and use relative paths
source "../common/variables.sh"
source "../common/setup.sh"

setup_specific() {
    if [ -z "${UBUNTU_TREE}" ]; then
        dialog_result=""
        bootstrap_dialog --title "Ubuntu Tree" \
                         --menu "Install which Ubuntu tree?" 0 0 0 \
                         "focal" "lts" \
                         "focal" "latest"
        UBUNTU_TREE="${dialog_result}"
    fi
}

preinstall() {
    apt-add-repository universe && apt-get update
    apt-get install --yes debootstrap gdisk zfs-initramfs zfsutils-linux \
        cryptsetup dialog
    systemctl stop zed
    modprobe zfs
}

partition_zfs() {
    sgdisk --zap-all "${INSTALL_DISK}"
    sgdisk -n1:1M:+512M -t1:EF00 "${INSTALL_DISK}"
    [ "${IS_EFI}" = false ] && sgdisk -a1 -n5:24k:+1000K -t5:EF02 \
        "${INSTALL_DISK}"
    sgdisk -n2:0:+"${SWAP_SIZE}G" -t2:8200 "${INSTALL_DISK}"
    sgdisk -n3:0:+2G -t3:BE00 "${INSTALL_DISK}"
    sgdisk -n4:0:0 -t4:BF00 "${INSTALL_DISK}"

    # wait for for udev to create paths
    sleep 3

    zpool labelclear -f "${INSTALL_DISK}-part3" || true
    zpool labelclear -f "${INSTALL_DISK}-part4" || true

    zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -d \
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
    # not following guide here for docker/libvirt datasets
    # see https://didrocks.fr/2020/06/16/zfs-focus-on-ubuntu-20.04-lts-zsys-dataset-layout/
    # and persistent datasets there
    zfs create -o canmount=off rpool/var
    zfs create -o canmount=off rpool/var/lib
    zfs create rpool/var/lib/docker
    zfs create rpool/var/lib/libvirt
    zfs create rpool/var/lib/machines

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
    echo "${HOSTNAME_FQDN}" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<- END
		127.0.0.1   localhost.localdomain localhost
		127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME_FQDN%%.*}
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

    cp "$(pwd)/ubuntu_zfs_chroot.sh" /mnt/tmp
    chroot /mnt /usr/bin/env \
        INSTALL_DISK="${INSTALL_DISK}" \
        UUID="${UUID}" \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
        GRUB_PASSWORD="${GRUB_PASSWORD}" \
        IS_EFI="${IS_EFI}" \
        /bin/bash --login -c /tmp/ubuntu_zfs_chroot.sh

    cp "$(pwd)/ubuntu_zfs_firstboot.sh" \
        "$(pwd)/ubuntu_zfs_bootstrap.sh" /mnt/root
}

if [ "$(id -u)" != 0 ]; then
    echo "Please execute with root rights."
    exit 1
fi

preinstall
setup_specific
setup
partition_zfs
install
teardown

