#!/bin/bash

user="azmo"
uid="1337"

apt-get install --yes sudo

# create home dataset and user
zfs create -o canmount=on -o mountpoint=/home/"${user}" \
    rpool/USERDATA/home/"${user}"
adduser --uid "${uid}" "${user}"
cp -a /etc/skel/. /home/"${user}"
chown -R "${user}":"${user}" /home/"${user}"
usermod -a -G users,adm,lp,lpadmin,plugdev,netdev,audio,video,cdrom,sudo "${user}"

# don't compress logfiles, zfs does that for us
for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
done

# disable root password
usermod -p '*' root

apt-get install --yes network-manager
