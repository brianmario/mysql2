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

if defined?(ActiveRecord::VERSION::STRING) && ActiveRecord::VERSION::STRING < "3.1"
  begin
    require 'active_record/connection_adapters/mysql2_adapter'
  rescue LoadError
    warn "============= WARNING FROM mysql2 ============="
    warn "This version of mysql2 (#{Mysql2::VERSION}) doesn't ship with the ActiveRecord adapter."
    warn "In Rails version 3.1.0 and up, the mysql2 ActiveRecord adapter is included with rails."
    warn "If you want to use the mysql2 gem with Rails <= 3.0.x, please use the latest mysql2 in the 0.2.x series."
    warn "============= END WARNING FROM mysql2 ============="
  end
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
