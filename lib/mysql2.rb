# encoding: UTF-8
require 'date'
require 'bigdecimal'
require 'rational' unless RUBY_VERSION >= '1.9.2'

require 'mysql2/version' unless defined? Mysql2::VERSION
require 'mysql2/error'
require 'mysql2/result'
require 'mysql2/mysql2'
require 'mysql2/client'

# = Mysql2
#
# A modern, simple and very fast Mysql library for Ruby - binding to libmysql
module Mysql2
end

if defined?(ActiveRecord::VERSION::STRING) && ActiveRecord::VERSION::STRING < "3.1"
  puts "WARNING: This version of mysql2 (#{Mysql2::VERSION}) doesn't ship with the ActiveRecord adapter bundled anymore as it's now part of Rails 3.1"
  puts "WARNING: Please use the 0.2.x releases if you plan on using it in Rails <= 3.0.x"
end
