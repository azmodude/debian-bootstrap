#!/bin/bash

export DEBIAN_TREE="buster"
export HOSTNAME_FQDN="test"
export SWAP_SIZE="1"
export ENCRYPTION_PASSPHRASE="testtest"
export GRUB_PASSWORD=""
export ROOT_PASSWORD="testtest"

apt-get update && apt-get install --yes zfsutils-linux
swapoff -a
zpool destroy bpool || true
zpool destroy rpool || true
./debian_zfs.sh
