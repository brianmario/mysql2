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
  brew install mysql
  mysql.server start
fi

# TODO: get SSL working on OS X in Travis
if ! [[ x$OSTYPE =~ ^xdarwin ]]; then
  sudo bash .travis_ssl.sh
  sudo service mysql restart
fi

sudo mysql -e "CREATE USER '$USER'@'localhost'" || true
