#!/usr/bin/env bash

set -eux

# Change the password to be empty.
CHANGED_PASSWORD=false
# Change the password to be empty, recreating the root user on mariadb < 10.2
# where ALTER USER is not available.
# https://stackoverflow.com/questions/56052177/
CHANGED_PASSWORD_BY_RECREATE=false

# Install the default used DB if DB is not set.
if [[ -n ${GITHUB_ACTIONS-} && -z ${DB-} ]]; then
  if command -v lsb_release > /dev/null; then
    case "$(lsb_release -cs)" in
    xenial | bionic)
      sudo apt-get install -qq mysql-server-5.7 mysql-client-core-5.7 mysql-client-5.7
      CHANGED_PASSWORD=true
      ;;
    focal)
      sudo apt-get install -qq mysql-server-8.0 mysql-client-core-8.0 mysql-client-8.0
      CHANGED_PASSWORD=true
      ;;
    jammy)
      sudo apt-get install -qq mysql-server-8.0 mysql-client-core-8.0 mysql-client-8.0
      CHANGED_PASSWORD=true
      ;;
    *)
      ;;
    esac
  fi
fi

# Install MySQL 5.5 if DB=mysql55
if [[ -n ${DB-} && x$DB =~ ^xmysql55 ]]; then
  sudo bash ci/mysql55.sh
fi

# Install MySQL 5.7 if DB=mysql57
if [[ -n ${DB-} && x$DB =~ ^xmysql57 ]]; then
  sudo bash ci/mysql57.sh
  CHANGED_PASSWORD=true
fi

# Install MySQL 8.0 if DB=mysql80
if [[ -n ${DB-} && x$DB =~ ^xmysql80 ]]; then
  sudo bash ci/mysql80.sh
  CHANGED_PASSWORD=true
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

# Install MySQL/MariaDB if OS=darwin
if [[ x$OSTYPE =~ ^xdarwin ]]; then
  brew update > /dev/null

  # Check available packages.
  for KEYWORD in mysql mariadb; do
    brew search "${KEYWORD}"
  done

  brew info "$DB"
  brew install "$DB"
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

if [ "${CHANGED_PASSWORD}" = true ]; then
  # https://www.percona.com/blog/2016/03/16/change-user-password-in-mysql-5-7-with-plugin-auth_socket/
  sudo mysql ${MYSQL_OPTS} -u "${DB_SYS_USER}" \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY ''"
elif [ "${CHANGED_PASSWORD_BY_RECREATE}" = true ]; then
  sudo mysql ${MYSQL_OPTS} -u "${DB_SYS_USER}" <<SQL
DROP USER 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
fi

mysql -u root -e 'CREATE DATABASE IF NOT EXISTS test'
