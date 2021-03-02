#!/usr/bin/env bash

set -eux

# Make sure there is an /etc/mysql
mkdir -p /etc/mysql

# Copy the local certs to /etc/mysql
cp spec/ssl/*pem /etc/mysql/

# Wherever MySQL configs live, go there (this is for cross-platform)
cd $(my_print_defaults --help | grep my.cnf | xargs find 2>/dev/null | xargs dirname)

# Put the configs into the server
echo "
[mysqld]
ssl-ca=/etc/mysql/ca-cert.pem
ssl-cert=/etc/mysql/server-cert.pem
ssl-key=/etc/mysql/server-key.pem
" >> my.cnf
