#!/bin/bash

export HOSTNAME_FQDN="test"
export SWAP_SIZE="1"
export ENCRYPTION_PASSPHRASE="testtest"
#export GRUB_PASSWORD=""
export ROOT_PASSWORD="testtest"

swapoff -a
zpool destroy bpool || true
zpool destroy rpool || true
./arch_zfs.sh
