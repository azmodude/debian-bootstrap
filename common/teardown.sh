#!/bin/bash
function teardown() {
    swapoff -a
    umount -lR /mnt
    sleep 5
    zpool export -a
}
