#!/usr/bin/env bash
set -eux

apt purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql

apt-key add support/C74CD1D8.asc
add-apt-repository "deb https://deb.mariadb.org/10.11/ubuntu $(lsb_release -cs) main"
apt install -y -o Dpkg::Options::='--force-confnew' mariadb-server libmariadb-dev
