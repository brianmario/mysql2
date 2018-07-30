#!/usr/bin/env bash

set -eux

MYSQL_TEST_LOG="$(pwd)/mysql.log"

mysql_install_db \
  --log-error="${MYSQL_TEST_LOG}"
/usr/libexec/mysqld \
  --user=root \
  --log-error="${MYSQL_TEST_LOG}" \
  --ssl &
sleep 3
cat ${MYSQL_TEST_LOG}

mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
