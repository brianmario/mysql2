#!/usr/bin/env bash

set -eu

# Install MySQL 5.7 if DB=mysql57
if [[ -n ${DB-} && x$DB =~ mysql57 ]]; then
  sudo bash .travis_mysql57.sh
fi

# Install MariaDB if DB=mariadb
if [[ -n ${DB-} && x$DB =~ xmariadb ]]; then
  sudo bash .travis_mariadb.sh "$DB"
fi

# Install MySQL if OS=darwin
if [[ x$OSTYPE =~ ^xdarwin ]]; then
  brew update
  brew install "$DB"
  $(brew --prefix "$DB")/bin/mysql.server start
fi

# TODO: get SSL working on OS X in Travis
if ! [[ x$OSTYPE =~ ^xdarwin ]]; then
  sudo bash .travis_ssl.sh
  sudo service mysql restart
fi

sudo mysql -e "CREATE USER '$USER'@'localhost'" || true

# Print the MySQL version and create the test DB
if [[ x$OSTYPE =~ ^xdarwin ]]; then
  $(brew --prefix "$DB")/bin/mysqld --version
  $(brew --prefix "$DB")/bin/mysql -u $USER -e "CREATE DATABASE IF NOT EXISTS test"
else
  mysqld --version
  mysql -u $USER -e "CREATE DATABASE IF NOT EXISTS test"
fi
