#!/usr/bin/env bash

set -eux

# Install MySQL 5.5 if DB=mysql55
if [[ -n ${DB-} && x$DB =~ ^xmysql55 ]]; then
  sudo bash .travis_mysql55.sh
fi

# Install MySQL 5.7 if DB=mysql57
if [[ -n ${DB-} && x$DB =~ ^xmysql57 ]]; then
  sudo bash .travis_mysql57.sh
fi

# Install MySQL 8.0 if DB=mysql80
if [[ -n ${DB-} && x$DB =~ ^xmysql80 ]]; then
  sudo bash .travis_mysql80.sh
fi

# Install MariaDB client headers after Travis CI fix for MariaDB 10.2 broke earlier 10.x
if [[ -n ${DB-} && x$DB =~ ^xmariadb10.0 ]]; then
  sudo apt-get install -y -o Dpkg::Options::='--force-confnew' libmariadbclient-dev
fi

# Install MariaDB client headers after Travis CI fix for MariaDB 10.2 broke earlier 10.x
if [[ -n ${DB-} && x$DB =~ ^xmariadb10.1 ]]; then
  sudo apt-get install -y -o Dpkg::Options::='--force-confnew' libmariadbclient-dev
fi

# Install MariaDB 10.2 if DB=mariadb10.2
# NOTE this is a workaround until Travis CI merges a fix to its mariadb addon.
if [[ -n ${DB-} && x$DB =~ ^xmariadb10.2 ]]; then
  sudo apt-get install -y -o Dpkg::Options::='--force-confnew' mariadb-server mariadb-server-10.2 libmariadbclient18
fi

# Install MySQL if OS=darwin
if [[ x$OSTYPE =~ ^xdarwin ]]; then
  brew update
  brew install "$DB" mariadb-connector-c
  $(brew --prefix "$DB")/bin/mysql.server start
fi

# TODO: get SSL working on OS X in Travis
if ! [[ x$OSTYPE =~ ^xdarwin ]]; then
  sudo bash .travis_ssl.sh
  sudo service mysql restart
fi

# Print the MySQL version and create the test DB
if [[ x$OSTYPE =~ ^xdarwin ]]; then
  $(brew --prefix "$DB")/bin/mysqld --version
  $(brew --prefix "$DB")/bin/mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
else
  mysqld --version
  # IF NOT EXISTS is mariadb-10+ only - https://mariadb.com/kb/en/mariadb/comment-syntax/
  mysql -u root -e 'CREATE DATABASE /*M!50701 IF NOT EXISTS */ test'
fi
