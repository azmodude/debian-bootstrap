#!/bin/bash
set -e
set -vx

export DEBIAN_FRONTEND=noninteractive

bootstrap_dialog() {
    dialog_result=$(dialog --clear --stdout --backtitle "Arch bootstrapper" --no-shadow "$@" 2>/dev/null)
}

setup() {
    apt-get update && \
	      apt-get -y install dialog

    if [ -z "${DEBIAN_TREE}" ]; then
        bootstrap_dialog --title "Debian Tree" \
                         --menu "Install which Debian tree?" 0 0 0 \
                         "buster" "stable" \
                         "sid" "unstable"
        DEBIAN_TREE="${dialog_result}"
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

    grep vendor_id /proc/cpuinfo | grep -q Intel && IS_INTEL_CPU=1 ||
        IS_INTEL_CPU=0
    grep vendor_id /proc/cpuinfo | grep -q AMD && IS_AMD_CPU=1 ||
        IS_AMD_CPU=0
    [ -d /sys/firmware/efi ] && IS_EFI=1 || IS_EFI=0
}

preinstall() {
    echo "deb https://deb.debian.org/debian buster main contrib non-free" > /etc/apt/sources.list
    echo "deb https://deb.debian.org/debian buster-backports main contrib non-free" >> /etc/apt/sources.list
    apt-get update
    apt-get install --yes debootstrap gdisk dkms dpkg-dev \
            linux-headers-"$(uname -r)"
    apt-get install --yes -t buster-backports --no-install-recommends zfs-dkms
    modprobe zfs
    apt-get install --yes -t buster-backports zfsutils-linux
}

partition_zfs() {
    sgdisk --zap-all "${INSTALL_DISK}"
    [[ ${IS_EFI} -eq 1 ]] && sgdisk -n1:1M:+512M -t1:EF00 "${INSTALL_DISK}"
    [[ ! ${IS_EFI} -eq 1 ]] && sgdisk -n1:1M:+1M -t1:EF02 "${INSTALL_DISK}"
    sgdisk -n2:0:+1G -t2:BF01 "${INSTALL_DISK}"
    sgdisk -n3:0:0 -t3:BF00 "${INSTALL_DISK}"

    # wait for for udev to create paths
    sleep 3

    zpool labelclear -f "${INSTALL_DISK}-part2" || true
    zpool labelclear -f "${INSTALL_DISK}-part3" || true

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

    zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/debian
    zfs mount bpool/BOOT/debian

    zfs create                                          rpool/home
    zfs create -o mountpoint=/root                      rpool/home/root
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
    debootstrap ${DEBIAN_TREE} /mnt
	  echo "Configuring hostname"
	  echo "${HOSTNAME_FQDN}" > /mnt/etc/hostname
	  cat > /mnt/etc/hosts <<- END
127.0.0.1   localhost.localdomain localhost
127.0.1.1   ${HOSTNAME_FQDN} ${HOSTNAME%%.*}
END
    cat > /mnt/etc/apt/sources.list <<- END
deb http://deb.debian.org/debian "${DEBIAN_TREE}" main contrib non-free
deb-src http://deb.debian.org/debian "${DEBIAN_TREE}" main contrib non-free
END
    if [[ "${DEBIAN_TREE}" != "sid" ]]; then
        cat > /mnt/etc/apt/sources.list.d/"${DEBIAN_TREE}"-backports.list <<- END
deb http://deb.debian.org/debian "${DEBIAN_TREE}"-backports main contrib non-free
deb-src http://deb.debian.org/debian "{DEBIAN_TREE}"-buster-backports main contrib non-free
END
        cat > /mnt/etc/apt/preferences.d/90_zfs <<-END
Package: libnvpair1linux libuutil1linux libzfs2linux libzfslinux-dev libzpool2linux python3-pyzfs pyzfs-doc spl spl-dkms zfs-dkms zfs-dracut zfs-initramfs zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=buster-backports
Pin-Priority: 990
END
    fi
    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys

    echo /dev/zvol/rpool/swap none swap discard 0 0 > /mnt/etc/fstab

    chroot /mnt /usr/bin/env \
           INSTALL_DISK="${INSTALL_DISK}" \
           ROOT_PASSWORD="${ROOT_PASSWORD}" \
           IS_EFI="${IS_EFI}"
           bash <<- EOF
    ln -s /proc/self/mounts /etc/mtab

    apt-get update
    apt-get install --yes locales sed popularity-contest \
          dpkg-dev console-setup linux-headers-amd64 \
          linux-image-amd64 zfs-initramfs zfs-dkms
    echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

    dpkg-reconfigure locales
    dpkg-reconfigure tzdata

    echo "Setting root passwd"
    echo "root:${ROOT_PASSWORD}" | chpasswd

    cat > /etc/systemd/system/zfs-import-bpool.service <<- END
	[Unit]
	DefaultDependencies=no
	Before=zfs-import-scan.service
	Before=zfs-import-cache.service

	[Service]
	Type=oneshot
	RemainAfterExit=yes
	ExecStart=/sbin/zpool import -N -o cachefile=none bpool

	[Install]
	WantedBy=zfs-import.target
	END
    systemctl daemon-reload
    systemctl enable zfs-import-bpool.service

    cp /usr/share/systemd/tmp.mount /etc/systemd/system/
    systemctl enable tmp.mount

    # grub
    if [[ ${IS_EFI} -eq 1 ]]; then
      apt-get install --yes dosfstools
      mkdosfs -F 32 -n EFI ${INSTALL_DISK}-part2
      mkdir /boot/efi
      echo PARTUUID=$(blkid -s PARTUUID -o value ${INSTALL_DISK}-part2) \
          /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 >> /etc/fstab
      mount /boot/efi
      apt-get install --yes grub-efi-amd64 shim-signed
    fi
    if [[ ! ${IS_EFI} -eq 1 ]]; then
       apt-get install --yes grub-pc
    fi

    dpkg --purge os-prober

    grub-probe /boot
    update-initramfs -c -k all
    sed -i -r 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="root=ZFS=rpool\/ROOT\/debian"/' /etc/default/grub
    sed -i -r 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)/#\1/' /etc/default/grub
    sed -i -r 's/#(GRUB_TERMINAL=console)/\1/' /etc/default/grub
    update-grub

    [[ ${IS_EFI} -eq 1 ]] && \
      grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                   --bootloader-id=debian --recheck --no-floppy
    [[ ! ${IS_EFI} -eq 1 ]] && \
      grub-install --target=i386-pc ${INSTALL_DISK}

    mkdir /etc/zfs/zfs-list.cache
    touch /etc/zfs/zfs-list.cache/bpool
    touch /etc/zfs/zfs-list.cache/rpool
    ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
    touch /etc/zfs/zfs-list.cache/{b,r}pool
    zed && sleep 5 && pkill zed
    sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
EOF
}

function teardown() {
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
        xargs -i{} umount -lf {}
    swapoff -a
    zpool export -a
}


setup
preinstall
partition_zfs
install
teardown

