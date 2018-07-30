#!/usr/bin/env bash

set -eux

# Start mysqld service.
sh .travis_setup_centos.sh

bundle install --path vendor/bundle --without benchmarks development

# USER environment value is not set as a default in the container environment.
export USER=root

bundle exec rake
