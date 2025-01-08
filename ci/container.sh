#!/usr/bin/env bash

set -eux

ruby -v
bundle install --path vendor/bundle --without development

# Regenerate the SSL certification files from the specified host.
if [ -n "${TEST_RUBY_MYSQL2_SSL_CERT_HOST}" ]; then
  pushd spec/ssl
  bash gen_certs.sh
  popd
fi

# Start mysqld service.
bash ci/setup_container.sh

bundle exec rake spec
