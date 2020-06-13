#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

ln -s /proc/self/mounts /etc/mtab

apt-get update
apt-get install --yes locales sed popularity-contest \
      dpkg-dev console-setup linux-headers-amd64 \
      linux-image-amd64 zfs-initramfs zfs-dkms \
      curl patch git keyboard-configuration console-setup

echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime && \
    dpkg-reconfigure tzdata
cat > /etc/default/locale <<-EOF
	LANG="en_US.UTF-8"
	LANGUAGE="en_US:en"
EOF
cat > /etc/locale.gen <<-EOF
	en_US.UTF-8 UTF-8
	de_DE.UTF-8 UTF-8
EOF
dpkg-reconfigure locales

cat > /etc/default/keyboard <<-EOF
	XKBMODEL="pc105"
	XKBLAYOUT="de"
	XKBVARIANT="nodeadkeys"
	XKBOPTIONS="caps:escape"

	BACKSPACE="guess"
EOF
dpkg-reconfigure keyboard-configuration

sed -r -i 's/^PARTICIPATE=.*/PARTICIPATE="yes"/' > /etc/popularity-contest.conf
dpkg-reconfigure popularity-contest

sed -r -i 's/^FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup

echo "Setting root passwd"
echo "root:${ROOT_PASSWORD}" | chpasswd

cp /usr/share/systemd/tmp.mount /etc/systemd/system/
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
systemctl enable tmp.mount
systemctl enable zfs-import-bpool.service

# fix some debian issues with systemd-tmpfiles races
mkdir -p /etc/systemd/system/console-setup.service.d
cat > /etc/systemd/system/console-setup.service.d/override.conf <<-EOF
	[Unit]
	After=systemd-tmpfiles-setup.service
EOF
mkdir -p /etc/systemd/system/keyboard-setup.service.d
cat > /etc/systemd/system/keyboard-setup.service.d/override.conf <<-EOF
	[Unit]
	After=systemd-tmpfiles-setup.service
EOF

# grub
if [[ "${IS_EFI}" -eq 1 ]]; then
  apt-get install --yes dosfstools
  mkdosfs -F 32 -n EFI "${INSTALL_DISK}"-part2
  mkdir /boot/efi
echo PARTUUID="$(blkid -s PARTUUID -o value "${INSTALL_DISK}"-part2)" \
      /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 >> /etc/fstab
  mount /boot/efi
  apt-get install --yes grub-efi-amd64 shim-signed
fi
if [[ ! "${IS_EFI}" -eq 1 ]]; then
   apt-get install --yes grub-pc
fi
# only needed in dualboot scenarios
dpkg --purge os-prober

if [[ -n "${GRUB_PASSWORD}" ]]; then
    # grub password protection
    GRUB_PASSWORD_HASH=$(echo -e "${GRUB_PASSWORD}\n${GRUB_PASSWORD}" | \
        grub-mkpasswd-pbkdf2 | awk '/grub.pbkdf/{print$NF}')
    cat > /etc/grub.d/40_password <<-EOF
		#!/bin/sh
		set -e

		cat << END
		set superusers="admin"
		password_pbkdf2 admin ${GRUB_PASSWORD_HASH}
		END
	EOF
    chown root:root /etc/grub.d/40_password
    chmod 700 /etc/grub.d/40_password
fi

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
  grub-install --target=i386-pc "${INSTALL_DISK}"

mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
touch /etc/zfs/zfs-list.cache/{b,r}pool
zed && sleep 5 && pkill zed
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
