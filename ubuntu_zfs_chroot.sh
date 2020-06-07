#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt install --yes cryptsetup curl patch git keyboard-configuration console-setup

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
	XKBOPTIONS=""

	BACKSPACE="guess"
EOF
dpkg-reconfigure keyboard-configuration

sed -r -i 's/^FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup

echo "Setting root passwd"
echo "root:${ROOT_PASSWORD}" | chpasswd

# grub
apt install --yes dosfstools

mkdosfs -F 32 -s 1 -n EFI "${INSTALL_DISK}"-part1
mkdir /boot/efi
echo UUID="$(blkid -s UUID -o value "${INSTALL_DISK}"-part1)" \
    /boot/efi vfat umask=0022,fmask=0022,dmask=0022 0 1 >> /etc/fstab
mount /boot/efi
mkdir /boot/efi/grub /boot/grub
echo /boot/efi/grub /boot/grub none defaults,bind 0 0 >> /etc/fstab
mount /boot/grub

if [[ ${IS_EFI} -eq 1 ]]; then
    apt-get --yes install grub-efi-amd64 grub-efi-amd64-signed \
    linux-image-generic shim-signed
else
    apt-get install --yes grub-pc linux-image-generic
fi
apt-get --yes install zfs-initramfs zsys

dpkg --purge os-prober

echo swap "${INSTALL_DISK}"-part2 /dev/urandom \
  swap,cipher=aes-xts-plain64:sha256,size=512 >> /etc/crypttab
echo /dev/mapper/swap none swap defaults 0 0 >> /etc/fstab

cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

addgroup --system lpadmin
addgroup --system lxd
addgroup --system sambashare

curl https://launchpadlibrarian.net/478315221/2150-fix-systemd-dependency-loops.patch | \
sed "s|/etc|/lib|;s|\.in$||" | (cd / ; patch -p1)

grub-probe /boot
update-initramfs -c -k all

sed -i -r 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/GRUB_CMDLINE_LINUX_DEFAULT="init_on_alloc=0 \1"/' /etc/default/grub
sed -i -r 's/\bquiet\b//' /etc/default/grub
sed -i -r 's/\bsplash\b//' /etc/default/grub
sed -i -r 's/^(GRUB_TIMEOUT_STYLE=hidden)/#\1/' /etc/default/grub
sed -i -r 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5\nGRUB_RECORDFAIL_TIMEOUT=5/' \
    /etc/default/grub
sed -i -r 's/#(GRUB_TERMINAL=console)/\1/' /etc/default/grub
update-grub

[[ ${IS_EFI} -eq 1 ]] && \
    grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=ubuntu --recheck --no-floppy
[[ ! ${IS_EFI} -eq 1 ]] && \
  grub-install --target=i386-pc "${INSTALL_DISK}"

mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
touch /etc/zfs/zfs-list.cache/{b,r}pool
zed && sleep 5 && pkill zed
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
