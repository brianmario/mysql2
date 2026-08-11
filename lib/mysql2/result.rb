module Mysql2
  class Result
    attr_reader :server_flags

    def empty?
      count.zero?
    end

    include Enumerable
  end
end
