#!/bin/sh

service mysql stop
apt-get purge '^mysql*' 'libmysql*'
apt-get install python-software-properties
apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db

if [[ x$1 = xmariadb55 ]]; then
  add-apt-repository 'deb http://ftp.osuosl.org/pub/mariadb/repo/5.5/ubuntu precise main'
elif [[ x$1 = xmariadb10 ]]; then
  add-apt-repository 'deb http://ftp.osuosl.org/pub/mariadb/repo/10.0/ubuntu precise main'
fi

apt-get update
apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y install mariadb-server libmariadbd-dev
