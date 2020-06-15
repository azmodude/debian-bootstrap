#!/bin/bash
bootstrap_dialog() {
    dialog_result=$(dialog --clear --stdout --backtitle "ZFS bootstrapper" --no-shadow "$@" 2>/dev/null)
    [ -z "${dialog_result}" ] && clear && exit 1
}
bootstrap_dialog_non_mandatory() {
    dialog_result=$(dialog --clear --stdout --backtitle "ZFS bootstrapper" --no-shadow "$@" 2>/dev/null)
}

setup() {
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
        bootstrap_dialog_non_mandatory --title "Grub Password" --passwordbox "Please enter a strong password for protecting the bootloader.\n(Leave empty to disable)" 8 60
        GRUB_PASSWORD="$dialog_result"
        if [[ -n "${GRUB_PASSWORD}" ]]; then
            bootstrap_dialog --title "Grub Password" --passwordbox "Please re-enter password to verify.\n" 8 60
            GRUB_PASSWORD_VERIFY="$dialog_result"
            if [[ "${GRUB_PASSWORD}" != "${GRUB_PASSWORD_VERIFY}" ]]; then
                echo "Passwords did not match."
                exit 3
            fi
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

    bootstrap_dialog_non_mandatory --title "WARNING" --msgbox "This script will NUKE ${INSTALL_DISK}.\nPress <Enter> to continue or <Esc> to cancel.\n" 6 60

    if [ -z "${INSTALL_DISK}" ] || [ ! -L "${INSTALL_DISK}" ]; then
        echo "${INSTALL_DISK} does not exist!"
        exit 1
    fi

    [ -d /sys/firmware/efi ] && IS_EFI=true || IS_EFI=false
    echo -n "Using ${INSTALL_DISK} and performing "
    [ ${IS_EFI} = true ] && echo "UEFI install."
    [ ${IS_EFI} = false ] && echo "legacy BIOS install."
}
