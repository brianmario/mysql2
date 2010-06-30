module Mysql2
  class Error < StandardError
    attr_accessor :error_number, :sql_state

    def initialize msg
      super
      @error_number = nil
      @sql_state    = nil
    end
  end
end
