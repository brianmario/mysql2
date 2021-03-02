#!/usr/bin/env bash

set -eux

MYSQL_TEST_LOG="$(pwd)/mysql.log"

mysql_install_db \
  --log-error="${MYSQL_TEST_LOG}"
/usr/libexec/mysqld \
  --user="$(id -un)" \
  --log-error="${MYSQL_TEST_LOG}" \
  --ssl &
sleep 3
cat ${MYSQL_TEST_LOG}

/usr/libexec/mysqld --version
mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
