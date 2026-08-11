#!/usr/bin/env bash

set -eux

apt-get purge -qq '^mysql*' '^libmysql*'
rm -fr /etc/mysql
rm -fr /var/lib/mysql

RELEASE=$(lsb_release -cs)
COMPONENT=mysql-8.4-lts

# Verify the component exists, as apt-get update only warns when it is missing.
wget -q --spider "https://repo.mysql.com/apt/ubuntu/dists/$RELEASE/$COMPONENT"

install -d -m 0755 /etc/apt/keyrings
install -m 0644 support/B7B3B788A8D3785C.asc /etc/apt/keyrings/mysql-keyring.asc

tee /etc/apt/sources.list.d/mysql.sources <<- EOF
	X-Repolib-Name: MySQL
	Types: deb
	URIs: https://repo.mysql.com/apt/ubuntu
	Suites: $RELEASE
	Components: $COMPONENT
	Signed-By: /etc/apt/keyrings/mysql-keyring.asc
EOF

apt-get update -qq
# CLIENT_ONLY=1: install just the client library, skipping the local
# server -- used to test this client version against a differently
# versioned server, run separately as a job `services:` container.
if [ "${CLIENT_ONLY-}" = 1 ]; then
  apt-get install -qq libmysqlclient-dev
else
  apt-get install -qq mysql-server libmysqlclient-dev
fi
