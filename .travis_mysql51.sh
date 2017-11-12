#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-key 9334A25F8507EFA5
add-apt-repository 'deb http://repo.percona.com/apt precise main'
apt-get update -qq
apt-get install -qq percona-server-server-5.1 percona-server-client-5.1 libmysqlclient16-dev
