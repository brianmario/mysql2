#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql
apt-key add support/5072E1F5.asc
# Verify the repository as add-apt-repository does not.
wget -q --spider http://repo.mysql.com/apt/ubuntu/dists/$(lsb_release -cs)/mysql-8.0
add-apt-repository 'http://repo.mysql.com/apt/ubuntu mysql-8.0'
apt-get update -qq
apt-get install -qq mysql-server libmysqlclient-dev
