#!/usr/bin/env bash

set -eux

CHANGED_PWD=false
# Change the password recreating the root user on mariadb < 10.2
# where ALTER USER is not available.
# https://stackoverflow.com/questions/56052177/
CHANGED_PWD_BY_RECREATE=false

# Install the default used DB if DB is not set.
if [[ -n ${GITHUB_ACTIONS-} && -z ${DB-} ]]; then
  if command -v lsb_release > /dev/null; then
    case "$(lsb_release -cs)" in
    xenial | bionic)
      sudo apt-get install -qq mysql-server-5.7 mysql-client-core-5.7 mysql-client-5.7
      CHANGED_PWD=true
      ;;
    focal)
      sudo apt-get install -qq mysql-server-8.0 mysql-client-core-8.0 mysql-client-8.0
      CHANGED_PWD=true
      ;;
    *)
      ;;
    esac
  fi
fi

# Install MySQL 5.5 if DB=mysql55
if [[ -n ${DB-} && x$DB =~ ^xmysql55 ]]; then
  sudo bash .travis_mysql55.sh
fi

# Install MySQL 5.7 if DB=mysql57
if [[ -n ${DB-} && x$DB =~ ^xmysql57 ]]; then
  sudo bash .travis_mysql57.sh
  CHANGED_PWD=true
fi

# Install MySQL 8.0 if DB=mysql80
if [[ -n ${DB-} && x$DB =~ ^xmysql80 ]]; then
  sudo bash .travis_mysql80.sh
  CHANGED_PWD=true
fi

# Install MariaDB client headers after Travis CI fix for MariaDB 10.2 broke earlier 10.x
if [[ -n ${DB-} && x$DB =~ ^xmariadb10.0 ]]; then
  if [[ -n ${GITHUB_ACTIONS-} ]]; then
    sudo apt-get install -y -o Dpkg::Options::='--force-confnew' mariadb-server mariadb-server-10.0 libmariadb2
    CHANGED_PWD_BY_RECREATE=true
  else
    sudo apt-get install -y -o Dpkg::Options::='--force-confnew' libmariadbclient-dev
  fi
fi

# Install MariaDB client headers after Travis CI fix for MariaDB 10.2 broke earlier 10.x
if [[ -n ${DB-} && x$DB =~ ^xmariadb10.1 ]]; then
  if [[ -n ${GITHUB_ACTIONS-} ]]; then
    sudo apt-get install -y -o Dpkg::Options::='--force-confnew' mariadb-server mariadb-server-10.1 libmariadb-dev
    CHANGED_PWD_BY_RECREATE=true
  else
    sudo apt-get install -y -o Dpkg::Options::='--force-confnew' libmariadbclient-dev
  fi
fi

# Install MariaDB 10.2 if DB=mariadb10.2
# NOTE this is a workaround until Travis CI merges a fix to its mariadb addon.
if [[ -n ${DB-} && x$DB =~ ^xmariadb10.2 ]]; then
  sudo apt-get install -y -o Dpkg::Options::='--force-confnew' mariadb-server mariadb-server-10.2 libmariadbclient18
fi

# Install MariaDB 10.3 if DB=mariadb10.3
if [[ -n ${GITHUB_ACTIONS-} && -n ${DB-} && x$DB =~ ^xmariadb10.3 ]]; then
  sudo apt-get install -y -o Dpkg::Options::='--force-confnew' mariadb-server mariadb-server-10.3 libmariadb-dev
  CHANGED_PWD=true
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
  else
    # Install from official mysql packages.
    MYSQL_OPTS=''
    DB_SYS_USER=root
  fi

  if [ "${CHANGED_PWD}" = true ]; then
    # https://www.percona.com/blog/2016/03/16/change-user-password-in-mysql-5-7-with-plugin-auth_socket/
    sudo mysql ${MYSQL_OPTS} -u "${DB_SYS_USER}" \
      -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY ''"
  elif [ "${CHANGED_PWD_BY_RECREATE}" = true ]; then
    sudo mysql ${MYSQL_OPTS} -u "${DB_SYS_USER}" <<SQL
DROP USER 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  fi

  # IF NOT EXISTS is mariadb-10+ only - https://mariadb.com/kb/en/mariadb/comment-syntax/
  mysql -u root -e 'CREATE DATABASE /*M!50701 IF NOT EXISTS */ test'
fi
