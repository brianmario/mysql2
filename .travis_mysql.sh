#!/bin/sh
set -e

service mysql status && service mysql stop

apt-get purge '^mysql*' 'libmysql*'
apt-get autoclean

rm -rf /etc/mysql /var/lib/mysql /var/log/mysql

apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0x8C718D3B5072E1F5

. /etc/lsb-release

if [[ x$1 = xmysql56 ]]; then
  echo "deb http://repo.mysql.com/apt/ubuntu $DISTRIB_CODENAME mysql-5.6" >> /etc/apt/sources.list
elif [[ x$1 = xmysql57 ]]; then
  echo "deb http://repo.mysql.com/apt/ubuntu $DISTRIB_CODENAME mysql-5.7" >> /etc/apt/sources.list
elif [[ x$1 = xmysql8 ]]; then
  echo "deb http://repo.mysql.com/apt/ubuntu $DISTRIB_CODENAME mysql-8.0" >> /etc/apt/sources.list
fi

apt-get update
apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y install mysql-server libmysqlclient-dev

# disable socket auth on mysql-community-server
mysql -u root -e "USE mysql; UPDATE user SET plugin='mysql_native_password' WHERE User='root'; FLUSH PRIVILEGES;"
