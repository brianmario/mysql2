#!/usr/bin/env bash
set -eux

apt purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql

RELEASE=$(lsb_release -cs)
VERSION=11.8

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
# CLIENT_ONLY=1: install just the client library, skipping the local
# server -- used to test this client version against a differently
# versioned server, run separately as a job `services:` container.
if [ "${CLIENT_ONLY-}" = 1 ]; then
  apt install -y -o Dpkg::Options::='--force-confnew' libmariadb-dev
else
  apt install -y -o Dpkg::Options::='--force-confnew' mariadb-server libmariadb-dev
fi
