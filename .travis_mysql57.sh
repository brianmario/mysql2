#!/usr/bin/env bash

set -eu

service mysql stop
apt-get purge '^mysql*' 'libmysql*'
apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0x8C718D3B5072E1F5

add-apt-repository 'deb http://repo.mysql.com/apt/ubuntu/ precise mysql-5.7-dmr'

apt-get update
apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew -y install mysql-server libmysqlclient-dev

mysql_upgrade -u root --force --upgrade-system-tables
