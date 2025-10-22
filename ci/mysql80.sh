#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql
apt-key add support/5072E1F5.asc # old signing key
apt-key add support/3A79BD29.asc # 8.0.28 and higher
apt-key add support/B7B3B788A8D3785C.asc # 8.1 and higher
# Verify the repository as add-apt-repository does not.
wget -q --spider http://repo.mysql.com/apt/ubuntu/dists/$(lsb_release -cs)/mysql-8.0
add-apt-repository 'http://repo.mysql.com/apt/ubuntu mysql-8.0'
apt-get update --allow-unauthenticated -qq
apt-get install --allow-unauthenticated -qq mysql-server libmysqlclient-dev
