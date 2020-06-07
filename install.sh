#!/bin/bash

export UBUNTU_TREE="focal"
export HOSTNAME_FQDN="test"
export SWAP_SIZE="1"
export ENCRYPTION_PASSPHRASE="testtest"
export ROOT_PASSWORD="testtest"

apt-get update && apt-get install --yes zfsutils-linux
swapoff -a
zpool destroy bpool || true
zpool destroy rpool || true
./ubuntu_zfs.sh
