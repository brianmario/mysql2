#!/bin/sh
set -e

service mysql status && service mysql stop

apt-get purge '^mysql*' 'libmysql*'
apt-get autoclean

rm -rf /etc/mysql /var/lib/mysql /var/log/mysql

apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db

. /etc/lsb-release

if [[ x$1 = xmariadb55 ]]; then
  echo "deb http://ftp.osuosl.org/pub/mariadb/repo/5.5/ubuntu $DISTRIB_CODENAME main" >> /etc/apt/sources.list
elif [[ x$1 = xmariadb10 ]]; then
  echo "deb http://ftp.osuosl.org/pub/mariadb/repo/10.3/ubuntu $DISTRIB_CODENAME main" >> /etc/apt/sources.list
fi

apt-get update
apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y install mariadb-server libmariadbd-dev
