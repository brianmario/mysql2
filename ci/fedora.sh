#!/usr/bin/env bash

set -eux

# Install build deps + a local MariaDB server. Skip `dnf update` -- we don't
# need every preinstalled package current, just these; skipping it avoids
# refreshing potentially hundreds of unrelated packages on every CI run.
dnf -yq install \
  --setopt=install_weak_deps=false \
  --setopt=tsflags=nodocs \
  --setopt=max_parallel_downloads=10 \
  gcc \
  gcc-c++ \
  git \
  libyaml-devel \
  make \
  mariadb-connector-c-devel \
  mariadb-server \
  openssl \
  redhat-rpm-config

bash ci/ssl.sh

MYSQL_TEST_LOG="$(pwd)/mysql.log"
mysql_install_db \
  --log-error="${MYSQL_TEST_LOG}"
/usr/libexec/mysqld \
  --user="$(id -un)" \
  --log-error="${MYSQL_TEST_LOG}" \
  --ssl &
sleep 3
cat "${MYSQL_TEST_LOG}"

/usr/libexec/mysqld --version

mysql -u root <<SQL
DROP USER 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
