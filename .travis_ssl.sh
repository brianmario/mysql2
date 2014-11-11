#!/bin/sh

# Halt the tests on error
set -e

# Whever MySQL configs live, go there (this is for cross-platform)
cd $(my_print_defaults --help | grep my.cnf | xargs find 2>/dev/null | xargs dirname)

# Create config files to run openssl in batch mode
# Set the CA startdate to yesterday to avoid "ASN: before date in the future"
# (there can be 90k seconds in a daylight saving change day)

echo "
[ ca ]
default_startdate = $(ruby -e 'print (Time.now - 90000).strftime("%y%m%d000000Z")')

[ req ]
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
# If this isn't set, the error is "error, no objects specified in config file"
commonName = Common Name (hostname, IP, or your name)

countryName_default            = US
stateOrProvinceName_default    = CA
localityName_default           = San Francisco
0.organizationName_default     = test_example
organizationalUnitName_default = Testing
emailAddress_default           = admin@example.com
" | tee ca.cnf cert.cnf

# The client and server certs must have a diferent common name than the CA
# to avoid "SSL connection error: error:00000001:lib(0):func(0):reason(1)"

echo "
commonName_default             = ca_name
" >> ca.cnf

echo "
commonName_default             = cert_name
" >> cert.cnf

# Generate a set of certificates
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -nodes -days 1000 -key ca-key.pem -out ca-cert.pem -batch -config ca.cnf
openssl req -newkey rsa:2048 -days 1000 -nodes -keyout pkcs8-server-key.pem -out server-req.pem -batch -config cert.cnf
openssl x509 -req -in server-req.pem -days 1000 -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 -out server-cert.pem
openssl req -newkey rsa:2048 -days 1000 -nodes -keyout pkcs8-client-key.pem -out client-req.pem -batch -config cert.cnf
openssl x509 -req -in client-req.pem -days 1000 -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 -out client-cert.pem

# Convert format from PKCS#8 to PKCS#1
openssl rsa -in pkcs8-server-key.pem -out server-key.pem
openssl rsa -in pkcs8-client-key.pem -out client-key.pem

# Put the configs into the server
echo "
[mysqld]
ssl-ca=/etc/mysql/ca-cert.pem
ssl-cert=/etc/mysql/server-cert.pem
ssl-key=/etc/mysql/server-key.pem
" >> my.cnf

# FIXME The startdate code above isn't doing the trick, we must wait until the minute moves
ruby -e 'start = Time.now.min; while Time.now.min == start; sleep 2; end'

# Ok, let's see what we got!
service mysql restart || brew services restart mysql
