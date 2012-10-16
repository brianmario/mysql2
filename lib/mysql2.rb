# encoding: UTF-8
require 'date'
require 'bigdecimal'
require 'rational' unless RUBY_VERSION >= '1.9.2'

require 'mysql2/version' unless defined? Mysql2::VERSION
require 'mysql2/error'
require 'mysql2/mysql2'
require 'mysql2/result'
require 'mysql2/client'

# = Mysql2
#
# A modern, simple and very fast Mysql library for Ruby - binding to libmysql
module Mysql2
end

if defined?(ActiveRecord::VERSION::STRING) && ActiveRecord::VERSION::STRING >= "3.1"
  warn "============= WARNING FROM mysql2 ============="
  warn "This version of mysql2 (#{Mysql2::VERSION}) isn't compatible with Rails 3.1 as the ActiveRecord adapter was pulled into Rails itself."
  warn "Please use the 0.3.x (or greater) releases if you plan on using it in Rails >= 3.1.x"
  warn "============= END WARNING FROM mysql2 ============="
end

# For holding utility methods
module Mysql2::Util

  #
  # Rekey a string-keyed hash with equivalent symbols.
  #
  def self.key_hash_as_symbols(hash)
    return nil unless hash
    Hash[hash.map { |k,v| [k.to_sym, v] }]
  end

end
