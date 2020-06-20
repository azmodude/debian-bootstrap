#!/bin/bash

set -e

user="azmo"
uid="1337"

# create home dataset and user
UUID="$(dd if=/dev/urandom of=/dev/stdout bs=1 count=100 2>/dev/null |
    tr -dc 'a-z0-9' | cut -c-6)"
ROOT_DS="$(zfs list -o name | awk '/ROOT\/ubuntu_/{print $1;exit}')"
zfs create -o com.ubuntu.zsys:bootfs-datasets="${ROOT_DS}" \
    -o canmount=on -o mountpoint=/home/"${user}" \
    rpool/USERDATA/"${user}"_"${UUID}"
adduser --uid "${uid}" "${user}"
cp -a /etc/skel/. /home/"${user}"
chown -R "${user}":"${user}" /home/"${user}"
usermod -a -G users,adm,cdrom,dip,lpadmin,lxd,plugdev,sambashare,sudo "${user}"

# install standard cli environment
apt-get install --yes ubuntu-standard

# don't compress logfiles, zfs does that for us
for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
done

read -p "Disable root password? (y/n)? " -r choice
case "$choice" in
  y|Y ) usermod -p '*' root;;
  n|N ) echo "Leaving root password untouched";;
  * ) echo "Invalid. Leaving root password untouched";;
esac

# install NetworkManager and let netplan know about it
apt-get install --yes network-manager
cat > /etc/netplan/01-network-manager-all.yaml <<- EOF
	network:
	  version: 2
	  renderer: NetworkManager
EOF
