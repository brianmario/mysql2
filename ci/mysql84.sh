#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql
apt-key add support/B7B3B788A8D3785C.asc # 8.1 and higher
# Verify the repository as add-apt-repository does not.
wget -q --spider http://repo.mysql.com/apt/ubuntu/dists/$(lsb_release -cs)/mysql-8.4-lts
add-apt-repository 'http://repo.mysql.com/apt/ubuntu mysql-8.4-lts'
apt-get update -qq
# CLIENT_ONLY=1: install just the client library, skipping the local
# server -- used to test this client version against a differently
# versioned server, run separately as a job `services:` container.
if [ "${CLIENT_ONLY-}" = 1 ]; then
  apt-get install -qq libmysqlclient-dev
else
  apt-get install -qq mysql-server libmysqlclient-dev
fi
