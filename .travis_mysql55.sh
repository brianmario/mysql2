#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql
apt-get update -qq
apt-get install -qq mysql-server-5.5 mysql-client-core-5.5 mysql-client-5.5 libmysqlclient-dev
