#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql
apt-key add support/B7B3B788A8D3785C.asc # 8.1 and higher
# Verify the repository as add-apt-repository does not.
wget -q --spider http://repo.mysql.com/apt/ubuntu/dists/$(lsb_release -cs)/mysql-8.4-lts
add-apt-repository 'http://repo.mysql.com/apt/ubuntu mysql-8.4-lts'
apt-get update -o Acquire::Check-Valid-Until=false -qq
apt-get install -o Acquire::Check-Valid-Until=false -qq mysql-server libmysqlclient-dev
