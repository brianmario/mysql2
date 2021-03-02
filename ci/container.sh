#!/usr/bin/env bash

set -eux

ruby -v
bundle install --path vendor/bundle --without benchmarks development

# Start mysqld service.
bash ci/setup_container.sh

bundle exec rake
