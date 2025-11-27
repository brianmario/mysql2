module Mysql2
  class Result
    include Enumerable

    SERVER_FLAGS = {
      no_good_index_used: SERVER_QUERY_NO_GOOD_INDEX_USED,
      no_index_used: SERVER_QUERY_NO_INDEX_USED,
      query_was_slow: SERVER_QUERY_WAS_SLOW,
    }

    def server_flags
      @server_flags ||= SERVER_FLAGS.transform_values { |flag| server_status?(flag) }
    end

    private

    def server_status?(flag)
      flag && (server_status & flag) != 0
    end
  end
end
