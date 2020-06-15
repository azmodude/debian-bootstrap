#!/bin/bash
pacman -Syyu --noconfirm
# add archzfs repository
cat << EOF >> /etc/pacman.conf
	[archzfs]
	Server = http://archzfs.com/\$repo/x86_64
	Server = http://mirror.sum7.eu/archlinux/archzfs/\$repo/x86_64
	Server = https://mirror.biocrafting.net/archlinux/archzfs/\$repo/x86_64
EOF
pacman-key -r F75D9D76
pacman-key --lsign-key F75D9D76
# add archzfs-kernels repository
cat << EOF >> /etc/pacman.conf
	[archzfs-kernels]
	Server = http://end.re/\$repo/
EOF
pacman -Syy --noconfirm dialog zfs-linux
