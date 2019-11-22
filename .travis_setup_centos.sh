#!/usr/bin/env bash

set -eux

MYSQL_TEST_LOG="$(pwd)/mysql.log"

# mysql_install_db uses wrong path for resolveip
# https://jira.mariadb.org/browse/MDEV-18563
# https://travis-ci.org/brianmario/mysql2/jobs/615263124#L2840
ln -s "$(command -v resolveip)" /usr/libexec/resolveip

mysql_install_db \
  --log-error="${MYSQL_TEST_LOG}"
/usr/libexec/mysqld \
  --user=root \
  --log-error="${MYSQL_TEST_LOG}" \
  --ssl &
sleep 3
cat ${MYSQL_TEST_LOG}

mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
