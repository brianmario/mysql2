#!/usr/bin/env bash
set -eux

apt purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql

apt-key add support/C74CD1D8.asc
add-apt-repository "deb https://downloads.mariadb.com/MariaDB/mariadb-10.11/repo/ubuntu $(lsb_release -cs) main"
apt install -y -o Dpkg::Options::='--force-confnew' mariadb-server-10.11 libmariadb-dev
