#!/bin/bash

curdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1090
source "${curdir}/../common/setup.sh"

preinstall() {
    pacman -S --needed --noconfirm parted dialog dosfstools \
        arch-install-scripts
    loadkeys de
    ! ping -c 1 -q 8.8.8.8 >/dev/null && wifi-menu
    timedatectl set-ntp true
    # Set up reflector
    pacman -Sy &&
        pacman -S --needed --noconfirm reflector
    reflector --verbose --latest 15 --sort rate --protocol https \
        --country DE --country NL --save /etc/pacman.d/mirrorlist \
        --save /etc/pacman.d/mirrorlist
}

if [ "$(id -u)" != 0 ]; then
    echo "Please execute with root rights."
    exit 1
fi

if [ "$(systemd-detect-virt)" != 'none' ]; then # vagrant box, install stuff
    VIRT=true
    echo "Virtualization detected."
fi

preinstall
setup

echo $INSTALL_DISK
