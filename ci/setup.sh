#!/usr/bin/env bash

set -eux

# Change the password to be empty.
CHANGED_PASSWORD_SHA2=false
# Change the password to be empty, recreating the root user on mariadb < 10.2
# where ALTER USER is not available.
# https://stackoverflow.com/questions/56052177/
CHANGED_PASSWORD_BY_RECREATE=false

# Install MySQL 8.0 if DB=mysql80
if [[ -n ${DB-} && x$DB =~ ^xmysql80 ]]; then
  sudo bash ci/mysql80.sh
  CHANGED_PASSWORD_SHA2=true
fi

# Install MySQL 8.4 if DB=mysql84
if [[ -n ${DB-} && x$DB =~ ^xmysql84 ]]; then
  sudo bash ci/mysql84.sh
  CHANGED_PASSWORD_SHA2=true
fi

# Install MySQL 9.7 if DB=mysql97
if [[ -n ${DB-} && x$DB =~ ^xmysql97 ]]; then
  sudo bash ci/mysql97.sh
  CHANGED_PASSWORD_SHA2=true
fi

# Install MariaDB 10.6 if DB=mariadb10.6
if [[ -n ${GITHUB_ACTIONS-} && -n ${DB-} && x$DB =~ ^xmariadb10.6 ]]; then
  sudo bash ci/mariadb106.sh
  CHANGED_PASSWORD_BY_RECREATE=true
fi

# Install MariaDB 10.11 if DB=mariadb10.11
if [[ -n ${GITHUB_ACTIONS-} && -n ${DB-} && x$DB =~ ^xmariadb10.11 ]]; then
  sudo bash ci/mariadb1011.sh
  CHANGED_PASSWORD_BY_RECREATE=true
fi

# Install MariaDB 11.4 if DB=mariadb11.4
if [[ -n ${GITHUB_ACTIONS-} && -n ${DB-} && x$DB =~ ^xmariadb11.4 ]]; then
  sudo bash ci/mariadb114.sh
  CHANGED_PASSWORD_BY_RECREATE=true
fi

# Install MariaDB 11.8 if DB=mariadb11.8
if [[ -n ${GITHUB_ACTIONS-} && -n ${DB-} && x$DB =~ ^xmariadb11.8 ]]; then
  sudo bash ci/mariadb11.8.sh
  CHANGED_PASSWORD_BY_RECREATE=true
fi

# Install MariaDB 12.3 if DB=mariadb12.3
if [[ -n ${GITHUB_ACTIONS-} && -n ${DB-} && x$DB =~ ^xmariadb12.3 ]]; then
  sudo bash ci/mariadb12.3.sh
  CHANGED_PASSWORD_BY_RECREATE=true
fi

# Install MySQL/MariaDB if OS=darwin
if [[ x$OSTYPE =~ ^xdarwin ]]; then
  brew update > /dev/null

  # Log which version we actually resolved to.
  brew info "$DB"
  brew install "$DB" zstd
  brew link "$DB" # explicitly activate in case of kegged LTS versions
  DB_PREFIX="$(brew --prefix "${DB}")"
  export PATH="${DB_PREFIX}/bin:${PATH}"
  export LDFLAGS="-L${DB_PREFIX}/lib"
  export CPPFLAGS="-I${DB_PREFIX}/include"

  mysql.server start
  CHANGED_PASSWORD_BY_RECREATE=true
fi

# TODO: get SSL working on OS X in Travis
if ! [[ x$OSTYPE =~ ^xdarwin ]]; then
  sudo bash ci/ssl.sh
  sudo service mysql restart
fi

mysqld --version

MYSQL_OPTS=''
DB_SYS_USER=root
if ! [[ x$OSTYPE =~ ^xdarwin ]]; then
  if [[ -n ${GITHUB_ACTIONS-} && -f /etc/mysql/debian.cnf ]]; then
    MYSQL_OPTS='--defaults-extra-file=/etc/mysql/debian.cnf'
    # Install from packages in OS official packages.
    if sudo grep -q debian-sys-maint /etc/mysql/debian.cnf; then
      # bionic, focal
      DB_SYS_USER=debian-sys-maint
    else
      # xenial
      DB_SYS_USER=root
    fi
  fi
fi

if [ "${CHANGED_PASSWORD_SHA2}" = true ]; then
  # In MySQL 5.7, the default authentication plugin is mysql_native_password.
  # As of MySQL 8.0, the default authentication plugin is changed to caching_sha2_password.
  sudo mysql ${MYSQL_OPTS} -u "${DB_SYS_USER}" \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY ''"
elif [ "${CHANGED_PASSWORD_BY_RECREATE}" = true ]; then
  sudo mysql ${MYSQL_OPTS} -u "${DB_SYS_USER}" <<SQL
DROP USER 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
fi

mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
