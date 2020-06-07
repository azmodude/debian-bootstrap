#!/bin/bash

# create home dataset and user
UUID="$(dd if=/dev/urandom of=/dev/stdout bs=1 count=100 2>/dev/null |
    tr -dc 'a-z0-9' | cut -c-6)"
ROOT_DS="$(zfs list -o name | awk '/ROOT\/ubuntu_/{print $1;exit}')"
zfs create -o com.ubuntu.zsys:bootfs-datasets="${ROOT_DS}" \
    -o canmount=on -o mountpoint=/home/azmo \
    rpool/USERDATA/username_"${UUID}"
adduser --uid 1337 azmo
cp -a /etc/skel/. /home/azmo
chown -R azmo:azmo /home/azmo
usermod -a -G adm,cdrom,dip,lpadmin,lxd,plugdev,sambashare,sudo azmo

# install standard cli environment
apt-get install --yes ubuntu-standard

# don't compress logfiles, zfs does that for us
for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
done

# disable root password
usermod -p '*' root

