# encoding: UTF-8
require 'mysql2' unless defined? Mysql2

class Mysql2
  class Result
    def each_hash(&block)
      each(&block)
    end

    def free
      # no-op
    end
  end
end