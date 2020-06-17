#!/bin/bash

# This quite closely follows the official guide at
# https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Buster%20Root%20on%20ZFS.html

export DEBIAN_FRONTEND=noninteractive

curdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1090
source "${curdir}/../common/setup.sh"

setup_specific() {
    if [ -z "${DEBIAN_TREE}" ]; then
        dialog_result=""
        bootstrap_dialog --title "Debian Tree" \
                         --menu "Install which Debian tree?" 0 0 0 \
                         "buster" "stable" \
                         "sid" "unstable"
        DEBIAN_TREE="${dialog_result}"
    fi
}

preinstall() {
    # if we are running in a Debian live CD, reenable the real
    # update-initramfs
    if [[ "$(readlink /sbin/update-initramfs)" == "/bin/live-update-initramfs" ]]; then
        rm -f /sbin/update-initramfs
        mv /sbin/update-initramfs.orig.initramfs-tools /sbin/update-initramfs
    fi
    echo "deb https://deb.debian.org/debian buster main contrib non-free" > /etc/apt/sources.list
    echo "deb https://deb.debian.org/debian buster-backports main contrib non-free" >> /etc/apt/sources.list
    apt-get update
    apt-get install --yes dialog debootstrap gdisk dkms dpkg-dev \
            linux-headers-"$(uname -r)"
    apt-get install --yes -t buster-backports --no-install-recommends zfs-dkms
    modprobe zfs
    apt-get install --yes -t buster-backports zfsutils-linux
}

partition_zfs() {
    sgdisk --zap-all "${INSTALL_DISK}"
    [ "${IS_EFI}" = true ] && sgdisk -n1:1M:+512M -t1:EF00 "${INSTALL_DISK}"
    [ "${IS_EFI}" = false ] && sgdisk -n1:1M:+1M -t1:EF02 "${INSTALL_DISK}"
    sgdisk -n2:0:+1G -t2:BF01 "${INSTALL_DISK}"
    sgdisk -n3:0:0 -t3:BF00 "${INSTALL_DISK}"

    # wait for for udev to create paths
    sleep 3

    zpool labelclear -f "${INSTALL_DISK}-part2" || true
    zpool labelclear -f "${INSTALL_DISK}-part3" || true

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
        bpool "${INSTALL_DISK}-part2"

    echo "$ENCRYPTION_PASSPHRASE" | \
        zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -O encryption=aes-256-gcm \
        -O keylocation=prompt -O keyformat=passphrase \
        -O acltype=posixacl -O canmount=off -O compression=lz4 \
        -O dnodesize=auto -O normalization=formD -O relatime=on \
        -O xattr=sa -O mountpoint=/ -R /mnt \
        rpool "${INSTALL_DISK}-part3"

    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT

    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
    zfs mount rpool/ROOT/debian

    zfs create -o canmount=on -o mountpoint=/boot bpool/BOOT/debian

    zfs create                                          rpool/home
    zfs create -o mountpoint=/root                      rpool/home/root
    zfs create                                          rpool/srv
    zfs create -o canmount=off -o mountpoint=/var       rpool/var
    zfs create                                          rpool/var/log
    zfs create -o canmount=off -o mountpoint=/var/lib   rpool/var/lib
    zfs create -o com.sun:auto-snapshot=false           rpool/var/lib/docker
    zfs create -o com.sun:auto-snapshot=false           rpool/var/lib/libvirt
    zfs create                                          rpool/var/spool
    zfs create -o com.sun:auto-snapshot=false           rpool/var/cache
    zfs create -o com.sun:auto-snapshot=false           rpool/var/tmp

    zfs create -V "${SWAP_SIZE}G" -b "$(getconf PAGESIZE)" \
        -o compression=zle \
        -o logbias=throughput -o sync=always \
        -o primarycache=metadata -o secondarycache=none \
        -o com.sun:auto-snapshot=false rpool/swap
    # wait for zvol to appear
    sleep 2
    mkswap -f /dev/zvol/rpool/swap

    zpool export bpool
    zpool export rpool
    zpool import -d /dev/disk/by-id -R /mnt rpool -N
    zpool import -d /dev/disk/by-id -R /mnt bpool -N
    echo "${ENCRYPTION_PASSPHRASE}" | zfs load-key rpool
    zfs mount rpool/ROOT/debian
    zfs mount bpool/BOOT/debian
    zfs mount -a

    swapon /dev/zvol/rpool/swap
}

install() {
    debootstrap "${DEBIAN_TREE}" /mnt
	  echo "Configuring hostname"
	  echo "${HOSTNAME_FQDN}" > /mnt/etc/hostname
	  cat > /mnt/etc/hosts <<- END
127.0.0.1   localhost.localdomain localhost
127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME%%.*}
END
    cat > /mnt/etc/apt/sources.list <<- END
deb http://deb.debian.org/debian ${DEBIAN_TREE} main contrib non-free
deb-src http://deb.debian.org/debian ${DEBIAN_TREE} main contrib non-free
END
    if [[ "${DEBIAN_TREE}" != "sid" ]]; then
        cat > /mnt/etc/apt/sources.list.d/"${DEBIAN_TREE}"-backports.list <<- END
deb http://deb.debian.org/debian ${DEBIAN_TREE}-backports main contrib non-free
deb-src http://deb.debian.org/debian ${DEBIAN_TREE}-backports main contrib non-free
END
        cat > /mnt/etc/apt/preferences.d/90_zfs <<-END
Package: libnvpair1linux libuutil1linux libzfs2linux libzfslinux-dev libzpool2linux python3-pyzfs pyzfs-doc spl spl-dkms zfs-dkms zfs-dracut zfs-initramfs zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=buster-backports
Pin-Priority: 990
END
    fi

    echo /dev/zvol/rpool/swap none swap discard 0 0 > /mnt/etc/fstab

    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys

    cp "$(pwd)/debian_zfs_chroot.sh" /mnt/tmp
    chroot /mnt /usr/bin/env \
           INSTALL_DISK="${INSTALL_DISK}" \
           ROOT_PASSWORD="${ROOT_PASSWORD}" \
           GRUB_PASSWORD="${GRUB_PASSWORD}" \
           IS_EFI="${IS_EFI}" \
           /bin/bash --login -c /tmp/debian_zfs_chroot.sh

    cp "$(pwd)/debian_zfs_firstboot.sh" \
        "$(pwd)/debian_zfs_bootstrap.sh" /mnt/root
}

function teardown() {
    swapoff -a
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
        xargs -i{} umount -lf {}
    zpool export -a
}

preinstall
setup_specific
setup
partition_zfs
install
teardown

