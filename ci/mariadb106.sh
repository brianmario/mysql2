#!/usr/bin/env bash
set -eux

apt purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql

RELEASE=$(lsb_release -cs)
VERSION=10.6

tee <<- EOF > /etc/apt/sources.list.d/mariadb.sources
	X-Repolib-Name: MariaDB
	Types: deb
	# URIs: https://deb.mariadb.org/$VERSION/ubuntu
	URIs: https://mirror.rackspace.com/mariadb/repo/$VERSION/ubuntu
	Suites: $RELEASE
	Components: main main/debug
	Signed-By: /etc/apt/keyrings/mariadb-keyring.asc
EOF

cp support/C74CD1D8.asc /etc/apt/keyrings/mariadb-keyring.asc
apt update
apt install -y -o Dpkg::Options::='--force-confnew' mariadb-server-$VERSION libmariadb-dev
