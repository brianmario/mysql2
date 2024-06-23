#!/usr/bin/env bash

set -eux

MYSQL_TEST_LOG="/var/log/mysqld_error.log"

bash ci/ssl.sh

/usr/sbin/mysqld --user=mysql --initialize
INITIAL_PASSWD=$(tail -n 1 /var/log/mysqld.log | awk '{print $13}')
/usr/sbin/mysqld --user=mysql --log-error="/var/log/mysqld.log" --ssl &
sleep 3
cat <<SQL | mysql -uroot -p"$INITIAL_PASSWD" --connect-expired-password
ALTER USER 'root'@'localhost' IDENTIFIED BY 'auth_string';

DROP USER 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;

CREATE DATABASE IF NOT EXISTS test;
SQL

cat ${MYSQL_TEST_LOG}

/usr/libexec/mysqld --version
