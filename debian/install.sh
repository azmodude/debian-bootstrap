#!/bin/bash

export DEBIAN_TREE="sid"
export HOSTNAME_FQDN="test"
export SWAP_SIZE="1"
export ENCRYPTION_PASSPHRASE="testtest"
export GRUB_PASSWORD="test"
export ROOT_PASSWORD="testtest"

./debian_zfs.sh
